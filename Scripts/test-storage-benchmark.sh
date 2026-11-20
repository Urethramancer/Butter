#!/bin/sh
# Release storage scaling comparison, including exact bytes and restart checks.
set -eu
cd "$(dirname "$0")/.."
case "${1:-}" in ''|--replay) ;; *) echo 'Usage: Scripts/test-storage-benchmark.sh [--replay]' >&2; exit 2 ;; esac
scratch=$PWD/.build/benchmark-release
swift build -c release --package-path Packages/ButterTorrent --scratch-path "$scratch"
bin=$(swift build -c release --package-path Packages/ButterTorrent --scratch-path "$scratch" --show-bin-path)
work=$(mktemp -d "$PWD/.build/storage-benchmark.XXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
swiftc -O -swift-version 6 -parse-as-library -module-cache-path "$work/modules" -I "$bin" -L "$bin" \
	-lButterTorrentStorage -lButterTorrentMetadata Tests/StorageBenchmark.swift Tests/StorageReplay.swift -o "$work/StorageBenchmark"
if [ "${1:-}" = --replay ]; then
	unset BUTTER_BENCHMARK_FIXTURE_CASE BUTTER_BENCHMARK_PIECE_LENGTH BUTTER_RECEIVE_ORDER_TRACE BUTTER_BENCHMARK_APPLICATION_INSPECTOR BUTTER_BENCHMARK_BASELINE
	export BUTTER_STORAGE_DIAGNOSTICS=0 BUTTER_STORAGE_WRITE_TIMINGS=0 BUTTER_RECEIVE_PIPELINE_TIMINGS=0 BUTTER_BENCHMARK_PROFILER=sample
	capture=$PWD/.build/storage-capture
	swift build -c release --package-path Packages/ButterTorrent --scratch-path "$capture" -Xswiftc -DBUTTER_STORAGE_REPLAY_CAPTURE
	capture_bin=$(swift build -c release --package-path Packages/ButterTorrent --scratch-path "$capture" --show-bin-path)
	swiftc -O -swift-version 6 -parse-as-library -DBUTTER_STORAGE_REPLAY_CAPTURE -DBUTTER_VERIFICATION_POLICY_AVAILABLE \
		-module-cache-path "$work/modules" -I "$capture_bin" -L "$capture_bin" \
		-lButterTorrentEngine -lButterTorrentNetworking -lButterTorrentStorage -lButterTorrentMetadata Tests/TransferBenchmark.swift -o "$work/TransferBenchmark"
	Scripts/build-bridge.sh
	cmake -S Tests/Reference -B .dependencies/reference-build -DBUTTER_ENGINE_TESTS=ON
	cmake --build .dependencies/reference-build --target TCPPeerReference --parallel 4
	"$work/TransferBenchmark" fixture "$work/fixtures"
	ruby -I Tests -rTransferBenchmarkHarness -e '
		work, reference = ARGV
		runner = TransferBenchmarkHarness::Runner.new(File.join(work, "TransferBenchmark"), reference, File.join(work, "capture"), work)
		JSON.parse(File.read(File.join(work, "fixtures/manifest.json"))).each do |fixture|
			runner.trial(fixture, fixture["case"] == "many" ? "hybrid" : "v1", "download", "Swift", 0, false)
			raise "Live capture failed" unless JSON.parse(File.readlines(File.join(work, "capture/trials.jsonl")).last).fetch("accepted")
		end
	' "$work" "$PWD/.dependencies/reference-build/TCPPeerReference"
	for workload in single concurrent many; do
		for pair in 1 2 3 4 5 6 diagnostic; do
			case "$pair" in 2|4|6) order='piece current' ;; *) order='current piece' ;; esac
			for mode in $order; do
				counts=0; [ "$pair" != diagnostic ] || counts=1
				BUTTER_STORAGE_DIAGNOSTICS=$counts "$work/StorageBenchmark" replay "$work/fixtures" "$workload" "$mode"
			done
		done
	done
	exit 0
fi
for files in 32 128; do
	"$work/StorageBenchmark" fixture "$work/$files" "$files"
	for format in v1 hybrid; do
		for trial in 1 2 3; do
			/usr/bin/time -l "$work/StorageBenchmark" write "$work/$files" "$format" 2> "$work/time" || { cat "$work/time" >&2; exit 1; }
			awk -v trial="$trial" '/ real .* user .* sys/ { wall=$1; cpu=$3+$5 } /maximum resident set size/ { rss=$1 } END { printf "trial=%d total-wall=%.2f cpu=%.2f peak-RSS-MiB=%.2f\n",trial,wall,cpu,rss/1048576 }' "$work/time"
		done
	done
done
