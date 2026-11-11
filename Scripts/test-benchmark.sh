#!/bin/sh
# Optional Release comparison with the pinned libtorrent counterpart.
set -eu
cd "$(dirname "$0")/.."
mode=${1:---full}
case "$mode" in --full|--smoke|--profile) ;; *) echo 'Usage: Scripts/test-benchmark.sh [--full|--smoke|--profile] [OUTPUT]' >&2; exit 2 ;; esac
out=${2:-$PWD/.build/benchmarks/$(date -u +%Y%m%dT%H%M%SZ)}
mkdir -p "$out"
out=$(cd "$out" && pwd)
[ ! -e "$out/environment.json" ] && [ ! -e "$out/trials.jsonl" ] || { echo 'Use a fresh output directory to preserve previous results.' >&2; exit 2; }
work=$(mktemp -d /tmp/butter-benchmark.XXXXXX)
trap 'rm -rf "$work"' EXIT
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
ruby -rjson -rdigest -ropen3 -rrbconfig -e '
  capture = ->(*cmd) { output, status = Open3.capture2e(*cmd); raise output unless status.success?; output.strip }
  root, out, mode, reference, swift_driver = ARGV
  record = {schema: 1, mode: mode, revision: capture.call("git", "rev-parse", "HEAD"), dirty: capture.call("git", "status", "--short"),
    libtorrent_revision: "6da363d2994f17c0b3c0450d124cf73a31a73847", swift: capture.call("swift", "--version"), clang: capture.call("clang++", "--version"),
    os: capture.call("sw_vers"), machine: capture.call("sysctl", "-n", "hw.model", "hw.memsize", "hw.logicalcpu"),
    filesystem: capture.call("df", "-h", root), resource_limits: capture.call("sh", "-c", "ulimit -a"),
    filters: ENV.select { |key, _| key.start_with?("BUTTER_BENCHMARK_") },
    swift_flags: "Release; swiftc -O -swift-version 6", reference_flags: "CMake Release; arm64; pinned static libtorrent",
    transport: "loopback TCP, encryption disabled, PEX/discovery disabled; production request windows",
    cache: "fresh processes and destinations; sources streamed and SHA256 checked before every trial; explicitly warm, no cold-cache claim",
    durability: "Swift native payload fsync then atomic state fsync/rename/directory fsync; libtorrent flush_disk_cache fence plus explicit payload/directory fsync then resume fsync/rename/directory fsync",
    sampling: mode == "--profile" ? "one instrumented pair per selected case; no warm-ups; profile-only, excluded from timing acceptance" : "one warm-up per engine per case, six balanced shuffled pairs; extend inconclusive cases to twelve pairs; smoke uses one pair and 32 MiB",
    timing: "phase wall/user/system from each driver; CPU/GiB through durable completion; whole process wall/user/system/peak RSS from /usr/bin/time -l, including teardown"}
  files = %w[Tests/TransferBenchmark.swift Tests/TransferBenchmarkReference.hpp Tests/TCPPeerReference.mm Tests/TransferBenchmarkHarness.rb Scripts/test-benchmark.sh]
  record[:harness_sha256] = files.to_h { |path| [path, Digest::SHA256.file(path).hexdigest] }
  record[:swift_source_sha256] = Dir.glob("Packages/ButterTorrent/Sources/**/*.swift").sort.to_h { |path| [path, Digest::SHA256.file(path).hexdigest] }
  record[:driver_sha256] = {swift: Digest::SHA256.file(swift_driver).hexdigest, reference: Digest::SHA256.file(reference).hexdigest}
  record[:reference_cmake] = File.readlines(".dependencies/reference-build/CMakeCache.txt").select { |line| line.match?(/\A(?:CMAKE_(?:BUILD_TYPE|OSX_ARCHITECTURES|(?:CXX|OBJCXX)(?:_COMPILER|_FLAGS(?:_RELEASE)?))|Boost_INCLUDE_DIR|OPENSSL_ROOT_DIR):/) }.map(&:strip)
  record[:ruby] = capture.call(RbConfig.ruby, "--version")
  File.write(File.join(out, "environment.json"), JSON.pretty_generate(record))
' "$work" "$out" "$mode" "$reference" "$work/TransferBenchmark"
if [ "$mode" = --smoke ]; then "$work/TransferBenchmark" fixture "$work/fixtures" --small
else "$work/TransferBenchmark" fixture "$work/fixtures"; fi
ruby Tests/TransferBenchmarkHarness.rb "$work/TransferBenchmark" "$reference" "$out" "$work" "$mode"
rm -f "$out/build.log"
printf 'Raw results and summaries: %s\n' "$out"
