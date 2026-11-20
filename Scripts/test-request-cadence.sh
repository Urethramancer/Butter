#!/bin/sh
# Compare identical payload bytes at one, two and four concurrent v1 torrents.
set -eu
cd "$(dirname "$0")/.."
out=${1:-.build/request-cadence.json}
[ ! -e "$out" ] || { echo 'Choose a fresh output file.' >&2; exit 2; }
mkdir -p .build
work=$(mktemp -d "$PWD/.build/request-cadence.XXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
unset BUTTER_BENCHMARK_BASELINE BUTTER_BENCHMARK_APPLICATION_INSPECTOR BUTTER_BENCHMARK_FIXTURE_CASE BUTTER_RECEIVE_ORDER_TRACE
export BUTTER_BENCHMARK_PIECE_LENGTH=262144 BUTTER_STORAGE_DIAGNOSTICS=0 BUTTER_RECEIVE_PIPELINE_TIMINGS=0 BUTTER_STORAGE_WRITE_TIMINGS=0 BUTTER_BENCHMARK_PROFILER=sample
Scripts/build-bridge.sh
cmake -S Tests/Reference -B .dependencies/reference-build -DBUTTER_ENGINE_TESTS=ON
cmake --build .dependencies/reference-build --target TCPPeerReference --parallel 4
for variant in base diagnostic; do
	scratch=$PWD/.build/benchmark-release
	set --
	if [ "$variant" = diagnostic ]; then scratch=$work/diagnostic-build; set -- -Xswiftc -DBUTTER_REQUEST_CADENCE; fi
	swift build -c release --package-path Packages/ButterTorrent --scratch-path "$scratch" "$@"
	bin=$(swift build -c release --package-path Packages/ButterTorrent --scratch-path "$scratch" --show-bin-path)
	swiftc -O -swift-version 6 -parse-as-library -DBUTTER_VERIFICATION_POLICY_AVAILABLE -DBUTTER_RECEIVE_PIPELINE_DIAGNOSTICS_AVAILABLE \
		-module-cache-path "$work/modules" -I "$bin" -L "$bin" -lButterTorrentEngine -lButterTorrentStorage -lButterTorrentNetworking -lButterTorrentMetadata \
		Tests/TransferBenchmark.swift -o "$work/$variant"
done
"$work/base" fixture "$work/fixtures" --split-v1
ruby Tests/RequestCadenceBenchmark.rb "$work/base" "$work/diagnostic" "$PWD/.dependencies/reference-build/TCPPeerReference" "$work" "$out"
