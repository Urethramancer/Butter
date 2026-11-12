#!/bin/sh
# Optional Release comparison with the pinned libtorrent counterpart.
set -eu
cd "$(dirname "$0")/.."
mode=${1:---full}
case "$mode" in --full|--smoke|--profile|--compare-source) ;; *) echo 'Usage: Scripts/test-benchmark.sh [--full|--smoke|--profile|--compare-source] [OUTPUT]' >&2; exit 2 ;; esac
case "${BUTTER_BENCHMARK_PROFILER:-sample}:$mode" in
	sample:*|time-profiler:--profile) ;;
	*) echo 'Use BUTTER_BENCHMARK_PROFILER=sample, or time-profiler with --profile.' >&2; exit 2 ;;
esac
out=${2:-$PWD/.build/benchmarks/$(date -u +%Y%m%dT%H%M%SZ)}
mkdir -p "$out"
out=$(cd "$out" && pwd)
[ ! -e "$out/environment.json" ] && [ ! -e "$out/trials.jsonl" ] || { echo 'Use a fresh output directory to preserve previous results.' >&2; exit 2; }
work=$(mktemp -d "${TMPDIR:-/tmp}/butter-benchmark.XXXXXX")
cleanup() {
	if [ -f "$work/previous-source/.git" ]; then
		git worktree remove --force "$work/previous-source" > "$out/cleanup.log" 2>&1 || return 1
		rm -f "$out/cleanup.log"
	fi
	rm -rf "$work"
}
trap 'cleanup || exit 1' EXIT
trap 'exit 1' HUP INT TERM
Scripts/build-bridge.sh > "$out/build.log" 2>&1
cmake -S Tests/Reference -B .dependencies/reference-build -DBUTTER_ENGINE_TESTS=ON >> "$out/build.log" 2>&1
cmake --build .dependencies/reference-build --target TCPPeerReference --parallel 4 >> "$out/build.log" 2>&1
reference=$PWD/.dependencies/reference-build/TCPPeerReference
scratch=$PWD/.build/benchmark-release
swift build -c release --package-path Packages/ButterTorrent --scratch-path "$scratch" >> "$out/build.log" 2>&1
bin=$(swift build -c release --package-path Packages/ButterTorrent --scratch-path "$scratch" --show-bin-path)
swiftc -O -swift-version 6 -parse-as-library -module-cache-path "$work/modules" -I "$bin" -L "$bin" \
	-lButterTorrentEngine -lButterTorrentStorage -lButterTorrentNetworking -lButterTorrentMetadata \
	Tests/TransferBenchmark.swift -o "$work/TransferBenchmark" >> "$out/build.log" 2>&1
previous_driver=
previous_root=
if [ "$mode" = --compare-source ]; then
	previous_revision=$(git rev-parse --verify --end-of-options "${BUTTER_BENCHMARK_PREVIOUS_REVISION:-1931e70}^{commit}")
	previous_root=$work/previous-source
	git worktree add --detach "$previous_root" "$previous_revision" >> "$out/build.log" 2>&1
	swift build -c release --package-path "$previous_root/Packages/ButterTorrent" --scratch-path "$work/previous-build" >> "$out/build.log" 2>&1
	previous_bin=$(swift build -c release --package-path "$previous_root/Packages/ButterTorrent" --scratch-path "$work/previous-build" --show-bin-path)
	previous_driver=$work/PreviousTransferBenchmark
	swiftc -O -swift-version 6 -parse-as-library -module-cache-path "$work/modules" -I "$previous_bin" -L "$previous_bin" \
		-lButterTorrentEngine -lButterTorrentStorage -lButterTorrentNetworking -lButterTorrentMetadata \
		Tests/TransferBenchmark.swift -o "$previous_driver" >> "$out/build.log" 2>&1
fi
ruby -rjson -rdigest -ropen3 -rrbconfig -e '
  capture = ->(*cmd) { output, status = Open3.capture2e(*cmd); raise output unless status.success?; output.strip }
  root, out, mode, reference, swift_driver, previous_driver, previous_root = ARGV
  record = {schema: 1, mode: mode, revision: capture.call("git", "rev-parse", "HEAD"), dirty: capture.call("git", "status", "--short"),
    libtorrent_revision: "6da363d2994f17c0b3c0450d124cf73a31a73847", swift: capture.call("swift", "--version"), clang: capture.call("clang++", "--version"),
    os: capture.call("sw_vers"), machine: capture.call("sysctl", "-n", "hw.model", "hw.memsize", "hw.logicalcpu"),
    filesystem: capture.call("df", "-h", root), work_directory: root, resource_limits: capture.call("sh", "-c", "ulimit -a"),
    filters: ENV.select { |key, _| key.start_with?("BUTTER_BENCHMARK_") },
    swift_flags: "Release; swiftc -O -swift-version 6", reference_flags: "CMake Release; arm64; pinned static libtorrent",
    transport: "loopback TCP, encryption disabled, PEX/discovery disabled; production request windows",
    cache: "fresh processes and destinations; sources streamed and SHA256 checked before every trial; explicitly warm, no cold-cache claim",
    durability: "Swift native payload fsync then atomic state fsync/rename/directory fsync; its forced completion checkpoint is inside the verified interval. Libtorrent finished precedes pause/flush_cache fence plus explicit payload/directory fsync then resume fsync/rename/directory fsync. Through-durable metrics include both placements.",
    sampling: mode == "--compare-source" ? "one warm-up per engine/source; fixed six balanced source-order pairs, each with a balanced Swift/native engine-order pair per source; source-comparison-only, no acceptance inference or uncertainty-driven retries" : mode == "--profile" ? "one instrumented pair per selected case; no warm-ups; profile-only, excluded from timing acceptance" : "one warm-up per engine per case, six balanced shuffled pairs; extend inconclusive cases to twelve pairs; smoke uses one pair and 32 MiB",
    profiler: mode == "--profile" ? {name: ENV.fetch("BUTTER_BENCHMARK_PROFILER", "sample"), time_profiler_method: "attach tested process before start using Instruments notification; Running samples only; stop after durable; counterpart phase CPU retained, not instrumented"} : nil,
    timing: "phase wall/user/system from each driver; CPU/GiB through durable completion; whole process wall/user/system/peak RSS from /usr/bin/time -l, including teardown"}
  files = %w[Tests/TransferBenchmark.swift Tests/TransferBenchmarkReference.hpp Tests/TCPPeerReference.mm Tests/TransferBenchmarkHarness.rb Tests/Reference/CMakeLists.txt Scripts/test-benchmark.sh Scripts/bootstrap-engine.sh]
  record[:harness_sha256] = files.to_h { |path| [path, Digest::SHA256.file(path).hexdigest] }
  record[:swift_source_sha256] = Dir.glob("Packages/ButterTorrent/Sources/**/*.swift").sort.to_h { |path| [path, Digest::SHA256.file(path).hexdigest] }
  record[:package_sha256] = Digest::SHA256.file("Packages/ButterTorrent/Package.swift").hexdigest
  record[:driver_sha256] = {swift: Digest::SHA256.file(swift_driver).hexdigest, reference: Digest::SHA256.file(reference).hexdigest}
  if mode == "--compare-source"
    record[:source_comparison] = {previous_revision: capture.call("git", "-C", previous_root, "rev-parse", "HEAD"), current_revision: record[:revision], driver_source: "same current Tests/TransferBenchmark.swift for both engines", native_counterpart: "one identical pinned binary for all sources, engines and counterparts"}
    record[:previous_swift_source_sha256] = Dir.glob(File.join(previous_root, "Packages/ButterTorrent/Sources/**/*.swift")).sort.to_h { |path| [path.delete_prefix(previous_root + "/"), Digest::SHA256.file(path).hexdigest] }
    record[:previous_package_sha256] = Digest::SHA256.file(File.join(previous_root, "Packages/ButterTorrent/Package.swift")).hexdigest
    record[:driver_sha256][:previous_swift] = Digest::SHA256.file(previous_driver).hexdigest
  end
  record[:reference_cmake] = File.readlines(".dependencies/reference-build/CMakeCache.txt").select { |line| line.match?(/\A(?:CMAKE_(?:BUILD_TYPE|OSX_ARCHITECTURES|(?:CXX|OBJCXX)(?:_COMPILER|_FLAGS(?:_RELEASE)?))|Boost_INCLUDE_DIR|OPENSSL_ROOT_DIR):/) }.map(&:strip)
  record[:reference_target_flags] = File.read(".dependencies/reference-build/CMakeFiles/TCPPeerReference.dir/flags.make") if File.file?(".dependencies/reference-build/CMakeFiles/TCPPeerReference.dir/flags.make")
  record[:reference_link_command] = File.read(".dependencies/reference-build/CMakeFiles/TCPPeerReference.dir/link.txt") if File.file?(".dependencies/reference-build/CMakeFiles/TCPPeerReference.dir/link.txt")
  record[:libtorrent_flags] = File.read(".dependencies/engine-apple-build/CMakeFiles/torrent-rasterbar.dir/flags.make") if File.file?(".dependencies/engine-apple-build/CMakeFiles/torrent-rasterbar.dir/flags.make")
  record[:dependency_archives_sha256] = %w[libtorrent-rasterbar libssl libcrypto].to_h { |name| [name, Digest::SHA256.file(".dependencies/install/lib/#{name}.a").hexdigest] }
  record[:reference_linkage] = capture.call("otool", "-L", reference)
  record[:ruby] = capture.call(RbConfig.ruby, "--version")
  File.write(File.join(out, "environment.json"), JSON.pretty_generate(record))
' "$work" "$out" "$mode" "$reference" "$work/TransferBenchmark" "$previous_driver" "$previous_root"
rm -f "$out/build.log"
if [ "$mode" = --smoke ]; then "$work/TransferBenchmark" fixture "$work/fixtures" --small
else "$work/TransferBenchmark" fixture "$work/fixtures"; fi
if [ "$mode" = --compare-source ]; then
	ruby Tests/TransferBenchmarkHarness.rb "$work/TransferBenchmark" "$reference" "$out" "$work" "$mode" "$previous_driver"
else
	ruby Tests/TransferBenchmarkHarness.rb "$work/TransferBenchmark" "$reference" "$out" "$work" "$mode"
fi
printf 'Raw results and summaries: %s\n' "$out"
