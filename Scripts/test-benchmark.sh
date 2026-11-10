#!/bin/sh
# Optional Release comparison. Both downloaders use the same local reference seed.
set -eu
cd "$(dirname "$0")/.."
Scripts/build-bridge.sh
cmake -S Tests/Reference -B .dependencies/reference-build -DBUTTER_ENGINE_TESTS=ON
cmake --build .dependencies/reference-build --target TCPPeerReference --parallel 4
reference=$PWD/.dependencies/reference-build/TCPPeerReference
scratch=$PWD/.build/benchmark-release
swift build -c release --package-path Packages/ButterTorrent --scratch-path "$scratch"
bin=$(swift build -c release --package-path Packages/ButterTorrent --scratch-path "$scratch" --show-bin-path)
work=$(mktemp -d /tmp/butter-benchmark.XXXXXX)
seed=
cleanup() {
	if [ -n "$seed" ]; then kill "$seed" 2>/dev/null || :; wait "$seed" || :; fi
	rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
swiftc -O -swift-version 6 -parse-as-library -module-cache-path "$work/modules" -I "$bin" -L "$bin" \
	-lButterTorrentEngine -lButterTorrentStorage -lButterTorrentNetworking -lButterTorrentMetadata \
	Tests/TransferBenchmark.swift -o "$work/TransferBenchmark"
"$work/TransferBenchmark" fixture "$work"
job() {
	ruby -rjson -e 'print JSON.generate(torrent: ARGV[0], destination: ARGV[1], status: ARGV[2], listen: "127.0.0.1:0", transport: "tcp", encryption: "disabled", pex: false, remoteHost: "127.0.0.1", remotePort: ARGV[3].to_i, benchmark: ARGV[4] == "true")' "$@"
}
printf 'format\tengine\ttrial\tseconds\tMiB/s\tCPU seconds\tpeak RSS MiB\n'
for format in v1 hybrid; do
	for trial in 1 2 3; do
		for engine in libtorrent Swift; do
			torrent=$work/$format.torrent
			seedStatus=$work/seed-status.json
			rm -f "$seedStatus"
			job "$torrent" "$work/seed" "$seedStatus" 0 false > "$work/seed-job.json"
			"$reference" --run "$work/seed-job.json" &
			seed=$!
			port=
			attempt=0
			while kill -0 "$seed" 2>/dev/null && [ "$attempt" -lt 100 ]; do
				if [ -f "$seedStatus" ]; then port=$(ruby -rjson -e 's=JSON.parse(File.read(ARGV[0])); print s["port"] if s["seeding"] && s["port"] > 0' "$seedStatus"); fi
				[ -z "$port" ] || break
				attempt=$((attempt + 1))
				sleep 0.02
			done
			[ -n "$port" ] || { echo 'Benchmark seed did not start' >&2; exit 1; }
			destination=$work/download-$format-$trial-$engine
			if [ "$engine" = Swift ]; then
				set -- "$work/TransferBenchmark" download "$torrent" "$destination" "$destination-state" "$port"
			else
				job "$torrent" "$destination" "$work/download-status.json" "$port" true > "$work/download-job.json"
				set -- "$reference" --run "$work/download-job.json"
			fi
			/usr/bin/time -l "$@" 2> "$work/time" || { cat "$work/time" >&2; exit 1; }
			kill "$seed"; wait "$seed"; seed=
			cmp "$work/seed/payload.bin" "$destination/payload.bin"
			awk -v format="$format" -v engine="$engine" -v trial="$trial" '
				/ real .* user .* sys/ { wall=$1; cpu=$3+$5 }
				/maximum resident set size/ { rss=$1 }
				END {
					if (wall <= 0 || rss <= 0) exit 1
					printf "%s\t%s\t%d\t%.2f\t%.2f\t%.2f\t%.2f\n", format, engine, trial, wall, 32/wall, cpu, rss/1048576
				}
			' "$work/time"
			rm -rf "$destination" "$destination-state"
		done
	done
done
