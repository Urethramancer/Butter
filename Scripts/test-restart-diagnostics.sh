#!/bin/sh
# Aggregate counters and controlled startup phases, separate from acceptance timing.
set -eu
cd "$(dirname "$0")/.."
out=${1:-$PWD/.build/restart-diagnostics}
mkdir -p "$out"
[ ! -e "$out/environment.json" ] || { echo 'Use a fresh output directory.' >&2; exit 2; }
work=$(mktemp -d /tmp/butter-restart-diagnostics.XXXXXX)
trap 'rm -rf "$work"' EXIT HUP INT TERM
scratch=$PWD/.build/benchmark-release
swift build -c release --package-path Packages/ButterTorrent --scratch-path "$scratch" > "$out/build.log" 2>&1
bin=$(swift build -c release --package-path Packages/ButterTorrent --scratch-path "$scratch" --show-bin-path)
swiftc -O -swift-version 6 -parse-as-library -module-cache-path "$work/modules" -I "$bin" -L "$bin" \
	-lButterTorrentStorage -lButterTorrentMetadata Tests/RestartDiagnostics.swift -o "$work/RestartDiagnostics" >> "$out/build.log" 2>&1
ruby -rjson -rdigest -e 'puts JSON.pretty_generate({revision: `git rev-parse HEAD`.strip, source_sha256: Digest::SHA256.file("Tests/RestartDiagnostics.swift").hexdigest, swift: `swift --version`.strip, piece_bytes: 1048576, piece_count: 128, demand: "(index * 17) % 64 for index 0..<64", sampling: "one diagnostic per combination, counters enabled; no throughput/CPU acceptance claim", policy: "controlled direct storage eager/deferred; setup excluded, all deferred work through durable included", partial: "first 64 pieces present, remainder missing; historical complete checkpoint", cache: "warm filesystem, sequential runs"})' > "$out/environment.json"
for layout in single many; do
	for format in v1 v2 hybrid; do
		for population in complete partial; do
			for policy in eager deferred; do
				name=$layout-$format-$population-$policy
				BUTTER_STORAGE_DIAGNOSTICS=1 "$work/RestartDiagnostics" "$work/$name" "$layout" "$format" "$population" "$policy" > "$out/$name.jsonl" 2> "$out/$name.errors"
				rm -rf "$work/$name"
				printf 'Validated %s\n' "$name"
			 done
		done
	done
done
