#!/bin/sh
# Profiles disposable native views; never opens the user's Butter state.
set -eu
cd "$(dirname "$0")/.."
case "${BUTTER_UI_COMPARE_SOURCE:-0}" in 0|1) ;; *) echo 'UI comparison must be 0 or 1.' >&2; exit 2 ;; esac
ui_profile_out=${1:-$PWD/.build/experiments/cpu-profiles/application-ui}
mkdir -p "$ui_profile_out"
ui_profile_out=$(cd "$ui_profile_out" && pwd)
[ ! -e "$ui_profile_out/environment.json" ] || { echo 'Use a fresh profile directory.' >&2; exit 2; }
ui_profile_work=$(mktemp -d "${TMPDIR:-/tmp}/butter-ui-profile.XXXXXX")
trap 'rm -rf "$ui_profile_work"' EXIT HUP INT TERM
swift build -c release --package-path Packages/ButterTorrent --scratch-path .build/benchmark-release > "$ui_profile_out/build.log" 2>&1
ui_profile_bin=$(swift build -c release --package-path Packages/ButterTorrent --scratch-path .build/benchmark-release --show-bin-path)
ui_profile_variants=current
ui_profile_previous=
if [ "${BUTTER_UI_COMPARE_SOURCE:-0}" = 1 ]; then
	ui_profile_variants='previous current'
	ui_profile_previous=$(git rev-parse --verify --end-of-options "${BUTTER_UI_PROFILE_PREVIOUS_REVISION:-HEAD}^{commit}")
fi
for ui_profile_variant in $ui_profile_variants; do
mkdir -p "$ui_profile_work/$ui_profile_variant"
ui_profile_inspector=$ui_profile_work/$ui_profile_variant/TorrentInspector.swift
if [ "$ui_profile_variant" = previous ]; then
	git show "$ui_profile_previous:Butter/UI/TorrentInspector.swift" > "$ui_profile_inspector"
else
	cp Butter/UI/TorrentInspector.swift "$ui_profile_inspector"
fi
cat >> "$ui_profile_inspector" <<'SWIFT'

// Test-only initial selection; production layout and defaults remain unchanged.
extension TorrentInspector {
	init(profiledTorrent: TransferSnapshot) {
		self.init(torrent: profiledTorrent)
		_tab = State(initialValue: "Files")
	}
}
SWIFT
set --
if rg -q '^struct FileTreeEntry:' "$ui_profile_inspector"; then set -- -D BUTTER_FILE_TREE_AVAILABLE; fi
for ui_profile_source in Butter/UI/*.swift; do
	[ "$ui_profile_source" = Butter/UI/TorrentInspector.swift ] || set -- "$@" "$ui_profile_source"
done
swiftc -O -swift-version 5 -parse-as-library -module-cache-path "$ui_profile_work/modules" \
	Butter/Core/*.swift Butter/Engine/*.swift Butter/TransferStore.swift Butter/ContentView.swift "$@" "$ui_profile_inspector" Tests/ApplicationUIProfile.swift Tests/FileTreeTests.swift \
	-I "$ui_profile_bin" -L "$ui_profile_bin" -lButterTorrentEngine -lButterTorrentStorage -lButterTorrentNetworking -lButterTorrentMetadata \
	-framework AppKit -framework SystemConfiguration -o "$ui_profile_work/ApplicationUIProfile-$ui_profile_variant" >> "$ui_profile_out/build.log" 2>&1
done
if rg -q '^struct FileTreeEntry:' Butter/UI/TorrentInspector.swift; then "$ui_profile_work/ApplicationUIProfile-current" --test-file-tree >> "$ui_profile_out/build.log" 2>&1; fi
if [ "${BUTTER_UI_PROFILE_VALIDATE_ONLY:-0}" = 1 ]; then exit; fi
ruby -rjson -rdigest -ropen3 -e '
 capture = ->(*args) { value, status = Open3.capture2e(*args); raise value unless status.success?; value.strip }
 files = Dir.glob("Butter/{Core,Engine,UI}/*.swift") + %w[Butter/ContentView.swift Butter/TransferStore.swift Tests/ApplicationUIProfile.swift Tests/FileTreeTests.swift Tests/ApplicationUIComparison.rb Scripts/test-ui-profile.sh Tests/TransferBenchmarkHarness.rb Tests/ProfileAttribution.rb]
 files += Dir.glob("Packages/ButterTorrent/Sources/**/*.swift")
 puts JSON.pretty_generate({revision: capture.call("git", "rev-parse", "HEAD"), dirty: capture.call("git", "status", "--short"), swift: capture.call("swift", "--version"), os: capture.call("sw_vers"),
  scope: "Synthetic models rendered by production ContentView and optional adjacent TorrentInspector, with test-only Files initial selection; includes window creation and 12 updates one second apart; 2000 files or 200 torrents with 512 files each; no payload or networking",
  sampling: ENV["BUTTER_UI_COMPARE_SMOKE"] == "1" ? "Two uninstrumented functional checks with final frames; no timing acceptance" : ENV["BUTTER_UI_COMPARE_SOURCE"] == "1" ? "Uninstrumented fixed workload: four warm-ups and six balanced ABBA/BAAB blocks (24 measured samples), no repetitions" : "Single instrumented diagnostics, not timing acceptance",
  visible_only: ENV["BUTTER_UI_PROFILE_VISIBLE_ONLY"] == "1",
  selected_case: ENV["BUTTER_UI_PROFILE_CASE"], previous_inspector_revision: ARGV[1], keep_raw: false,
  test_inspector_sha256: Dir.glob(ARGV[0] + "/*/TorrentInspector.swift").to_h { |path| [File.basename(File.dirname(path)), Digest::SHA256.file(path).hexdigest] },
  source_sha256: files.sort.to_h { |path| [path, Digest::SHA256.file(path).hexdigest] }, driver_sha256: Dir.glob(ARGV[0] + "/ApplicationUIProfile-*").to_h { |path| [File.basename(path), Digest::SHA256.file(path).hexdigest] }, flags: "Release package; application swiftc -O -swift-version 5"})
' "$ui_profile_work" "$ui_profile_previous" > "$ui_profile_out/environment.json"
if [ "${BUTTER_UI_COMPARE_SOURCE:-0}" = 1 ]; then
	ruby Tests/ApplicationUIComparison.rb "$ui_profile_work/ApplicationUIProfile-previous" "$ui_profile_work/ApplicationUIProfile-current" "$ui_profile_out"
	exit
fi
ruby -I Tests -rTransferBenchmarkHarness -rProfileAttribution -e '
 h = TransferBenchmarkHarness; driver, out = ARGV; results = []
 %w[many-files many-torrents].product(%w[download seed], [false, true]).each do |workload, role, inspector|
  next if ENV["BUTTER_UI_PROFILE_VISIBLE_ONLY"] == "1" && !inspector
  id = [workload, role, inspector ? "visible" : "hidden"].join("-"); prefix = File.join(out,id)
  next if ENV["BUTTER_UI_PROFILE_CASE"] && ENV["BUTTER_UI_PROFILE_CASE"] != id
  job = {workload: workload, role: role, inspector: inspector, screenshot: prefix + ".png"}
  job_path = prefix + ".json"; File.write(job_path, JSON.generate(job))
  row = job.merge(id: id, accepted: false); child = nil; trace = nil
  begin
   child = h::Child.new([driver], job_path, prefix + ".log")
   h.wait([child], [[child,"ready"]], timeout: 60)
   trace = h::TimeProfiler.new(child.phase("ready").fetch("pid"), prefix); trace.wait_ready([child])
   child.send_command("start"); h.wait([child], [[child,"verified"]], timeout: 120)
   child.send_command("persist"); h.wait([child], [[child,"durable"]], timeout: 30)
   trace.finish; child.send_command("stop"); h.wait([child], [[child,"stopped"]], timeout: 30); child.finish
   trace.export
   h.write_profile_report(prefix, h.profile_summary(prefix + ".samples.xml", child.phase("ready").fetch("pid")))
   metrics = h.delta(child.phase("start"), child.phase("durable")); metrics[:cpu_seconds] = metrics[:user] + metrics[:system]
   row[:metrics] = metrics; row[:whole] = child.whole; row[:accepted] = true
  rescue StandardError => error
   row[:error] = "#{error.class}: #{error.message}"
  ensure
   row[:events] = child.events if child; child.cleanup if child; trace.cleanup if trace
   File.open(File.join(out,"trials.jsonl"),"a") { |file| file.puts(JSON.generate(row)) }; results << row
   puts "#{id}: #{row[:accepted] ? "captured" : row[:error]}"; $stdout.flush
  end
 end
 File.write(File.join(out,"summary.json"),JSON.pretty_generate(results.map { |row| row.reject { |key,_| key == :events } }))
 raise "No UI workload matched" if results.empty?
 raise "UI profiling contains failed captures" if results.any? { |row| !row[:accepted] }
' "$ui_profile_work/ApplicationUIProfile-current" "$ui_profile_out"
