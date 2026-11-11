#!/bin/sh
# Release storage scaling comparison, including exact bytes and restart checks.
set -eu
cd "$(dirname "$0")/.."
scratch=$PWD/.build/benchmark-release
swift build -c release --package-path Packages/ButterTorrent --scratch-path "$scratch"
bin=$(swift build -c release --package-path Packages/ButterTorrent --scratch-path "$scratch" --show-bin-path)
work=$(mktemp -d /tmp/butter-storage-benchmark.XXXXXX)
trap 'rm -rf "$work"' EXIT HUP INT TERM
swiftc -O -swift-version 6 -parse-as-library -module-cache-path "$work/modules" -I "$bin" -L "$bin" \
	-lButterTorrentStorage -lButterTorrentMetadata Tests/StorageBenchmark.swift -o "$work/StorageBenchmark"
for files in 32 128; do
	"$work/StorageBenchmark" fixture "$work/$files" "$files"
	for format in v1 hybrid; do
		for trial in 1 2 3; do
			/usr/bin/time -l "$work/StorageBenchmark" write "$work/$files" "$format" 2> "$work/time" || { cat "$work/time" >&2; exit 1; }
			awk -v trial="$trial" '/ real .* user .* sys/ { wall=$1; cpu=$3+$5 } /maximum resident set size/ { rss=$1 } END { printf "trial=%d total-wall=%.2f cpu=%.2f peak-RSS-MiB=%.2f\n",trial,wall,cpu,rss/1048576 }' "$work/time"
		done
	done
done
