#!/bin/sh
# Optional Release comparison with the pinned libtorrent counterpart.
set -eu
cd "$(dirname "$0")/.."
mode=${1:---full}
if [ -n "${BUTTER_BENCHMARK_FIXED_PAIRS:-}" ]; then
	[ "$mode" = --full ] || { echo 'Fixed matrix pair counts require --full.' >&2; exit 2; }
	case "$BUTTER_BENCHMARK_FIXED_PAIRS" in 6|12) ;; *) echo 'Fixed matrix pairs must be 6 or 12.' >&2; exit 2 ;; esac
fi
case "$mode" in --full|--smoke|--receive-profile|--write-profile|--profile|--compare-source|--profile-source|--rate-sweep|--rate-profile|--rate-compare) ;; *) echo 'Usage: Scripts/test-benchmark.sh [--full|--smoke|--receive-profile|--write-profile|--profile|--compare-source|--profile-source|--rate-sweep|--rate-profile|--rate-compare] [OUTPUT]' >&2; exit 2 ;; esac
if [ -n "${BUTTER_BENCHMARK_SOURCE_PAIRS:-}" ]; then
	[ "$mode" = --compare-source ] || { echo 'Source pair counts require --compare-source.' >&2; exit 2; }
	case "$BUTTER_BENCHMARK_SOURCE_PAIRS" in 6|12|24) ;; *) echo 'Source pairs must be 6, 12 or 24.' >&2; exit 2 ;; esac
fi
case "$mode" in
	--receive-profile|--profile|--profile-source|--compare-source)
		if [ -n "${BUTTER_BENCHMARK_CASE:-}" ]; then export BUTTER_BENCHMARK_FIXTURE_CASE=$BUTTER_BENCHMARK_CASE; fi ;;
esac
case "${BUTTER_BENCHMARK_RATE_FORMAT:-hybrid}" in
	hybrid|v2) ;;
	*) echo 'Rate format must be hybrid or v2.' >&2; exit 2 ;;
esac
case "${BUTTER_BENCHMARK_APPLICATION_INSPECTOR:-}" in
	'') ;;
	hidden|visible)
		case "$mode" in --rate-*) echo 'Application polling uses full-transfer workloads.' >&2; exit 2 ;; esac ;;
	*) echo 'Application inspector must be hidden or visible.' >&2; exit 2 ;;
esac
if [ "${BUTTER_RECEIVE_PIPELINE_TIMINGS:-0}" = 1 ]; then
	case "$mode" in --receive-profile|--profile|--profile-source|--write-profile|--rate-profile) ;; *) echo 'Receive timings are diagnostic only.' >&2; exit 2 ;; esac
	[ "${BUTTER_STORAGE_DIAGNOSTICS:-0}" = 1 ] || { echo 'Receive timings require BUTTER_STORAGE_DIAGNOSTICS=1.' >&2; exit 2; }
fi
if [ "$mode" = --receive-profile ]; then
	[ -n "${BUTTER_BENCHMARK_PREVIOUS_REVISION:-}" ] || { echo 'Receive profiles require BUTTER_BENCHMARK_PREVIOUS_REVISION.' >&2; exit 2; }
	[ "${BUTTER_BENCHMARK_DIRECTION:-download}" = download ] && [ -z "${BUTTER_BENCHMARK_APPLICATION_INSPECTOR:-}${BUTTER_RECEIVE_ORDER_TRACE:-}" ] && [ "${BUTTER_BENCHMARK_PROFILER:-sample}" = sample ] || { echo 'Receive profiles require downloads without traces, other profilers or application polling.' >&2; exit 2; }
	BUTTER_BENCHMARK_CASE=${BUTTER_BENCHMARK_CASE:-many}
	BUTTER_BENCHMARK_FORMAT=${BUTTER_BENCHMARK_FORMAT:-hybrid}
	case "$BUTTER_BENCHMARK_CASE:$BUTTER_BENCHMARK_FORMAT" in single:v1|single:v2|single:hybrid|many:v1|many:v2|many:hybrid|concurrent:v1|concurrent:v2|concurrent:hybrid) ;; *) echo 'Invalid receive-profile workload.' >&2; exit 2 ;; esac
	export BUTTER_BENCHMARK_CASE BUTTER_BENCHMARK_FORMAT
	export BUTTER_BENCHMARK_FIXTURE_CASE=$BUTTER_BENCHMARK_CASE
fi

if [ "${BUTTER_STORAGE_WRITE_TIMINGS:-0}" = 1 ]; then
	case "$mode" in --receive-profile|--write-profile|--profile|--profile-source|--rate-profile) ;; *) echo 'Write timings are diagnostic only.' >&2; exit 2 ;; esac
	[ "${BUTTER_STORAGE_DIAGNOSTICS:-0}" = 1 ] || { echo 'Write timings require BUTTER_STORAGE_DIAGNOSTICS=1.' >&2; exit 2; }
fi
if [ "$mode" = --write-profile ]; then
	[ -z "${BUTTER_BENCHMARK_CASE:-}${BUTTER_BENCHMARK_FORMAT:-}${BUTTER_BENCHMARK_DIRECTION:-}${BUTTER_BENCHMARK_APPLICATION_INSPECTOR:-}${BUTTER_BENCHMARK_FIXTURE_CASE:-}" ] || { echo 'Write profiles use the four fixed download workloads.' >&2; exit 2; }
	[ "${BUTTER_BENCHMARK_PROFILER:-sample}" = sample ] || { echo 'Write profiles cannot use another profiler.' >&2; exit 2; }
fi

if [ "${BUTTER_STORAGE_DIAGNOSTICS:-0}" = 1 ]; then
	case "$mode" in --receive-profile|--write-profile|--profile|--profile-source|--rate-profile) ;; *) echo 'Storage counters are diagnostic only; use --profile or --profile-source.' >&2; exit 2 ;; esac
fi
if { [ "$mode" = --profile-source ] || [ "$mode" = --receive-profile ] || [ "$mode" = --rate-compare ]; } && [ -z "${BUTTER_BENCHMARK_PREVIOUS_REVISION:-}" ]; then
	echo 'Set BUTTER_BENCHMARK_PREVIOUS_REVISION for source profiles or rate comparisons.' >&2; exit 2
fi
if [ "$mode" = --rate-profile ]; then
	if [ "${BUTTER_STORAGE_DIAGNOSTICS:-0}" = 1 ]; then
		[ "${BUTTER_BENCHMARK_PROFILER:-sample}" = sample ] || { echo 'Run rate counters separately from Instruments.' >&2; exit 2; }
	else
		BUTTER_BENCHMARK_PROFILER=${BUTTER_BENCHMARK_PROFILER:-time-profiler}
		[ "$BUTTER_BENCHMARK_PROFILER" = time-profiler ] || { echo 'Rate profiles require Time Profiler or separate storage counters.' >&2; exit 2; }
		export BUTTER_BENCHMARK_PROFILER
	fi
fi
case "${BUTTER_BENCHMARK_PROFILER:-sample}:$mode" in
	sample:*|counts:--profile|counts:--profile-source|time-profiler:--rate-profile|time-profiler:--profile|file-activity:--profile|heap:--profile|allocations:--profile|system-trace:--profile|concurrency:--profile|time-profiler:--profile-source|file-activity:--profile-source|heap:--profile-source|allocations:--profile-source|system-trace:--profile-source|concurrency:--profile-source) ;;
	*) echo 'Use sample, or a diagnostic profiler with --profile or --profile-source.' >&2; exit 2 ;;
esac
if [ "${BUTTER_BENCHMARK_PROFILER:-sample}" = counts ] && [ "${BUTTER_STORAGE_DIAGNOSTICS:-0}" != 1 ]; then
	echo 'Counts require BUTTER_STORAGE_DIAGNOSTICS=1.' >&2; exit 2
fi
if [ "$mode" = --rate-sweep ] || [ "$mode" = --rate-compare ]; then
	[ "${BUTTER_STORAGE_DIAGNOSTICS:-0}" = 0 ] && [ "${BUTTER_BENCHMARK_PROFILER:-sample}" = sample ] || { echo "Rate sweeps require counters and profilers disabled." >&2; exit 2; }
fi
default_output=$PWD/.build/benchmarks
[ "$mode" != --rate-sweep ] || default_output=$default_output/rate-sweep
out=${2:-$default_output/$(date -u +%Y%m%dT%H%M%SZ)}
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
build_driver() {
	driver_root=$1
	driver_bin=$2
	driver_output=$3
	driver_version=6
	set --
	if [ -f "$driver_root/Packages/ButterTorrent/Sources/ButterTorrentEngine/ReceivePipelineDiagnostics.swift" ]; then set -- "$@" -D BUTTER_RECEIVE_PIPELINE_DIAGNOSTICS_AVAILABLE; fi
	if [ -f "$driver_root/Packages/ButterTorrent/Sources/ButterTorrentStorage/StorageDiagnostics.swift" ]; then set -- "$@" -D BUTTER_STORAGE_DIAGNOSTICS_AVAILABLE; fi
	if rg -q 'public enum StorageReadPolicy' "$driver_root/Packages/ButterTorrent/Sources/ButterTorrentStorage/StorageVerification.swift"; then set -- "$@" -D BUTTER_VERIFICATION_POLICY_AVAILABLE; fi
	if [ -n "${BUTTER_BENCHMARK_APPLICATION_INSPECTOR:-}" ]; then
		driver_version=5
		set -- "$@" -D BUTTER_APPLICATION_BENCHMARK "$driver_root"/Butter/Core/*.swift "$driver_root"/Butter/Engine/*.swift "$PWD/Tests/ApplicationBenchmark.swift" -framework AppKit -framework SystemConfiguration
		if rg -q 'public enum SessionSnapshotProjection' "$driver_root/Packages/ButterTorrent/Sources/ButterTorrentEngine/TorrentSession.swift"; then set -- "$@" -D BUTTER_SNAPSHOT_PROJECTION_AVAILABLE; fi
	fi
	swiftc -O "$@" -swift-version "$driver_version" -parse-as-library -module-cache-path "$work/modules" -I "$driver_bin" -L "$driver_bin" \
		-lButterTorrentEngine -lButterTorrentStorage -lButterTorrentNetworking -lButterTorrentMetadata \
		"$PWD/Tests/TransferBenchmark.swift" -o "$driver_output" >> "$out/build.log" 2>&1
}
build_driver "$PWD" "$bin" "$work/TransferBenchmark"
previous_driver=
previous_root=
if [ "$mode" = --compare-source ] || [ "$mode" = --profile-source ] || [ "$mode" = --receive-profile ] || [ "$mode" = --rate-compare ]; then
	previous_revision=$(git rev-parse --verify --end-of-options "${BUTTER_BENCHMARK_PREVIOUS_REVISION:-1931e70}^{commit}")
	previous_root=$work/previous-source
	git worktree add --detach "$previous_root" "$previous_revision" >> "$out/build.log" 2>&1
	if [ "$mode" = --receive-profile ]; then
		for instrumentation in ButterTorrentEngine/ReceivePipelineDiagnostics.swift ButterTorrentStorage/StorageWriteQueueDiagnostics.swift; do
			cmp -s "$PWD/Packages/ButterTorrent/Sources/$instrumentation" "$previous_root/Packages/ButterTorrent/Sources/$instrumentation" || { echo 'Receive profiles require the same receive instrumentation in both sources.' >&2; exit 2; }
		done
	fi
	swift build -c release --package-path "$previous_root/Packages/ButterTorrent" --scratch-path "$work/previous-build" >> "$out/build.log" 2>&1
	previous_bin=$(swift build -c release --package-path "$previous_root/Packages/ButterTorrent" --scratch-path "$work/previous-build" --show-bin-path)
	previous_driver=$work/PreviousTransferBenchmark
	build_driver "$previous_root" "$previous_bin" "$previous_driver"
fi
ruby -rjson -rdigest -ropen3 -rrbconfig -e '
  capture = ->(*cmd) { output, status = Open3.capture2e(*cmd); raise output unless status.success?; output.strip }
  root, out, mode, reference, swift_driver, previous_driver, previous_root = ARGV
  rate_mode = mode.start_with?("--rate-")
  profiled = %w[--profile --profile-source --rate-profile].include?(mode)
  profiler = ENV.fetch("BUTTER_BENCHMARK_PROFILER", "sample")
  profile_window = mode == "--rate-profile" ? "transfer start through stopped after durable engine/storage shutdown; includes settle, measurement, drain and persistence; counters use a separate run" : {"counts" => "whole-transfer operation counters; no sampling or timing acceptance", "heap" => "ready/verified/durable gate snapshots; intrusive diagnostics, not peak RSS or allocation churn", "file-activity" => "requested trailing 1s before durable completion; diagnostic only", "time-profiler" => "whole transfer through durable completion", "allocations" => "requested trailing 2s before durable completion; intrusive allocation diagnostic", "system-trace" => "requested trailing 2s before durable completion; intrusive scheduler/syscall diagnostic", "concurrency" => "requested trailing 2s before durable completion; intrusive Swift task/actor diagnostic"}.fetch(profiler, "2s samples after start")
  record = {schema: 1, mode: mode, revision: capture.call("git", "rev-parse", "HEAD"), dirty: capture.call("git", "status", "--short"),
    libtorrent_revision: "6da363d2994f17c0b3c0450d124cf73a31a73847", swift: capture.call("swift", "--version"), clang: capture.call("clang++", "--version"),
    os: capture.call("sw_vers"), machine: capture.call("sysctl", "-n", "hw.model", "hw.memsize", "hw.logicalcpu"),
    filesystem: capture.call("df", "-h", root), work_directory: root, resource_limits: capture.call("sh", "-c", "ulimit -a"),
    filters: ENV.select { |key, _| key.start_with?("BUTTER_BENCHMARK_") || %w[BUTTER_STORAGE_DIAGNOSTICS BUTTER_STORAGE_WRITE_TIMINGS BUTTER_RECEIVE_PIPELINE_TIMINGS BUTTER_PROFILE_KEEP_RAW].include?(key) },
    swift_flags: "Release package; swiftc -O -swift-version #{ENV["BUTTER_BENCHMARK_APPLICATION_INSPECTOR"] ? 5 : 6}", reference_flags: "CMake Release; arm64; pinned static libtorrent",
    transport: "loopback TCP, encryption disabled, PEX/discovery disabled; production request windows",
    cache: "fresh processes and destinations; sources streamed and SHA256 checked before every trial; explicitly warm, no cold-cache claim",
    durability: rate_mode ? "After measurement: stop traffic, drain, checkpoint and fsync; independently compare every claimed verified piece with the fixture and reopen the partial checkpoint. Not full-transfer acceptance." : "Swift native payload fsync then atomic state fsync/rename/directory fsync; its forced completion checkpoint is inside the verified interval. Libtorrent finished precedes pause/flush_cache fence plus explicit payload/directory fsync then resume fsync/rename/directory fsync. Through-durable metrics include both placements.",
    sampling: mode == "--receive-profile" ? "one warm-up per source/mode, then off/counts/timed/timed/counts/off with balanced source order; 18 trials; diagnostic only; no repetitions" : mode == "--write-profile" ? "four fixed workloads; one warm-up per off/counts/timed mode, then off, counts, timed, timed, counts, off; 36 trials; one Release binary; no repetitions; diagnostic only" : mode == "--rate-profile" ? "one diagnostic per engine at 500 Mbps; excluded from comparisons" : mode == "--rate-compare" ? "one warm-up per source/engine; fixed six balanced pairs at 500 Mbps, 28 samples; no automatic repetitions" : rate_mode ? "Exploratory; one sample per engine/rate; fixed shuffled rates, alternating engine order; 5s settle and 10s measurement; no retries or significance inference" : %w[--compare-source --rate-compare].include?(mode) ? "one warm-up per engine/source; fixed #{ENV.fetch("BUTTER_BENCHMARK_SOURCE_PAIRS", "6")} balanced source-order pairs, each with a balanced Swift/native engine-order pair per source; source-comparison-only, no acceptance inference or uncertainty-driven retries" : profiled ? "one diagnostic trial per engine and source variant per selected case; no warm-ups; excluded from timing acceptance" : "one warm-up per engine per case, six balanced shuffled pairs; extend inconclusive cases to twelve pairs; smoke uses one pair and 32 MiB",
    profiler: profiled ? {name: profiler, capture_window: profile_window, time_profiler_method: %w[time-profiler file-activity].include?(profiler) ? "attach tested process before start using Instruments notification; Running samples only; stop at the labelled capture end; counterpart phase CPU retained, not instrumented" : nil} : nil,
    timing: rate_mode ? "Monotonic wall/user/system and received payload deltas between measurement-start/end; CPU 100% means one core; CPU/GiB excludes settle, persistence and teardown; counterpart CPU retained separately." : "phase wall/user/system from each driver; CPU/GiB through durable completion; whole process wall/user/system/peak RSS from /usr/bin/time -l, including teardown"}
  files = %w[Tests/TransferBenchmark.swift Tests/ApplicationBenchmark.swift Tests/TransferBenchmarkReference.hpp Tests/TCPPeerReference.mm Tests/TransferBenchmarkHarness.rb Tests/WriteProfileReport.rb Tests/ReceivePipelineReport.rb Tests/ProfileAttribution.rb Tests/RateSweep.rb Tests/Reference/CMakeLists.txt Scripts/test-benchmark.sh Scripts/bootstrap-engine.sh]
  record[:harness_sha256] = files.to_h { |path| [path, Digest::SHA256.file(path).hexdigest] }
  record[:swift_source_sha256] = Dir.glob("Packages/ButterTorrent/Sources/**/*.swift").sort.to_h { |path| [path, Digest::SHA256.file(path).hexdigest] }
  record[:package_sha256] = Digest::SHA256.file("Packages/ButterTorrent/Package.swift").hexdigest
  if ENV["BUTTER_BENCHMARK_APPLICATION_INSPECTOR"]
    record[:application_polling] = {inspector: ENV["BUTTER_BENCHMARK_APPLICATION_INSPECTOR"], cadence: "one second", scope: "production TorrentSession and NativeSnapshotMapper; headless; no SwiftUI rendering or OS services"}
    record[:application_source_sha256] = Dir.glob("Butter/{Core,Engine}/*.swift").sort.to_h { |path| [path, Digest::SHA256.file(path).hexdigest] }
  end
  record[:driver_sha256] = {swift: Digest::SHA256.file(swift_driver).hexdigest, reference: Digest::SHA256.file(reference).hexdigest}
  if %w[--compare-source --profile-source --receive-profile --rate-compare].include?(mode)
    record[:source_comparison] = {previous_revision: capture.call("git", "-C", previous_root, "rev-parse", "HEAD"), current_revision: record[:revision], driver_source: "same current Tests/TransferBenchmark.swift for both engines", native_counterpart: "one identical pinned binary for all sources, engines and counterparts"}
    record[:previous_swift_source_sha256] = Dir.glob(File.join(previous_root, "Packages/ButterTorrent/Sources/**/*.swift")).sort.to_h { |path| [path.delete_prefix(previous_root + "/"), Digest::SHA256.file(path).hexdigest] }
    record[:previous_package_sha256] = Digest::SHA256.file(File.join(previous_root, "Packages/ButterTorrent/Package.swift")).hexdigest
    if ENV["BUTTER_BENCHMARK_APPLICATION_INSPECTOR"]
      record[:previous_application_source_sha256] = Dir.glob(File.join(previous_root, "Butter/{Core,Engine}/*.swift")).sort.to_h { |path| [path.delete_prefix(previous_root + "/"), Digest::SHA256.file(path).hexdigest] }
    end
    record[:driver_sha256][:previous_swift] = Digest::SHA256.file(previous_driver).hexdigest
  end
  record[:reference_cmake] = File.readlines(".dependencies/reference-build/CMakeCache.txt").select { |line| line.match?(/\A(?:CMAKE_(?:BUILD_TYPE|OSX_ARCHITECTURES|(?:CXX|OBJCXX)(?:_COMPILER|_FLAGS(?:_RELEASE)?))|Boost_INCLUDE_DIR|OPENSSL_ROOT_DIR):/) }.map(&:strip)
  record[:reference_target_flags] = File.read(".dependencies/reference-build/CMakeFiles/TCPPeerReference.dir/flags.make") if File.file?(".dependencies/reference-build/CMakeFiles/TCPPeerReference.dir/flags.make")
  record[:reference_link_command] = File.read(".dependencies/reference-build/CMakeFiles/TCPPeerReference.dir/link.txt") if File.file?(".dependencies/reference-build/CMakeFiles/TCPPeerReference.dir/link.txt")
  record[:libtorrent_flags] = File.read(".dependencies/engine-apple-build/CMakeFiles/torrent-rasterbar.dir/flags.make") if File.file?(".dependencies/engine-apple-build/CMakeFiles/torrent-rasterbar.dir/flags.make")
  record[:dependency_archives_sha256] = %w[libtorrent-rasterbar libssl libcrypto].to_h { |name| [name, Digest::SHA256.file(".dependencies/install/lib/#{name}.a").hexdigest] }
  record[:reference_linkage] = capture.call("otool", "-L", reference)
  record[:ruby] = capture.call(RbConfig.ruby, "--version")
  if ENV["BUTTER_BENCHMARK_FIXED_PAIRS"]
    record[:sampling] = "one warm-up per engine per case, fixed #{ENV.fetch("BUTTER_BENCHMARK_FIXED_PAIRS")} balanced pairs; no uncertainty-driven extensions or repetitions"
  end
  File.write(File.join(out, "environment.json"), JSON.pretty_generate(record))
' "$work" "$out" "$mode" "$reference" "$work/TransferBenchmark" "$previous_driver" "$previous_root"
rm -f "$out/build.log"
if [ "${mode#--rate-}" != "$mode" ]; then "$work/TransferBenchmark" fixture "$work/fixtures" --rate-sweep
elif [ "$mode" = --smoke ]; then "$work/TransferBenchmark" fixture "$work/fixtures" --small
else "$work/TransferBenchmark" fixture "$work/fixtures"; fi
if [ "${mode#--rate-}" != "$mode" ]; then
	ruby Tests/RateSweep.rb "$work/TransferBenchmark" "$reference" "$out" "$work" "$mode" "$previous_driver"
elif [ "$mode" = --compare-source ] || [ "$mode" = --profile-source ] || [ "$mode" = --receive-profile ] || [ "$mode" = --rate-compare ]; then
	ruby Tests/TransferBenchmarkHarness.rb "$work/TransferBenchmark" "$reference" "$out" "$work" "$mode" "$previous_driver"
else
	ruby Tests/TransferBenchmarkHarness.rb "$work/TransferBenchmark" "$reference" "$out" "$work" "$mode"
fi
printf 'Raw results and summaries: %s\n' "$out"
# Refuse to interpret measurements if their source or binary changed during traffic.
ruby -rjson -rdigest -e '
  out, driver, reference = ARGV
  record = JSON.parse(File.read(File.join(out, "environment.json")))
  %w[harness_sha256 swift_source_sha256 application_source_sha256].each do |group|
    record.fetch(group, {}).each { |path, hash| raise "Benchmark source changed: #{path}" unless Digest::SHA256.file(path).hexdigest == hash }
  end
  raise "Benchmark package changed" unless Digest::SHA256.file("Packages/ButterTorrent/Package.swift").hexdigest == record.fetch("package_sha256")
  {"swift" => driver, "reference" => reference}.each { |name, path| raise "Benchmark binary changed: #{name}" unless Digest::SHA256.file(path).hexdigest == record.fetch("driver_sha256").fetch(name) }
  File.write(File.join(out, "fingerprints-verified.json"), JSON.generate({unchanged: true}))
' "$out" "$work/TransferBenchmark" "$reference"
