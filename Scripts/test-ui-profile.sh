#!/bin/sh
# Profiles disposable native views; never opens the user's Butter state.
set -eu
cd "$(dirname "$0")/.."
ui_profile_out=${1:-$PWD/.build/experiments/cpu-profiles/application-ui}
mkdir -p "$ui_profile_out"
ui_profile_out=$(cd "$ui_profile_out" && pwd)
[ ! -e "$ui_profile_out/environment.json" ] || { echo 'Use a fresh profile directory.' >&2; exit 2; }
ui_profile_work=$(mktemp -d "${TMPDIR:-/tmp}/butter-ui-profile.XXXXXX")
trap 'rm -rf "$ui_profile_work"' EXIT HUP INT TERM
swift build -c release --package-path Packages/ButterTorrent --scratch-path .build/benchmark-release > "$ui_profile_out/build.log" 2>&1
ui_profile_bin=$(swift build -c release --package-path Packages/ButterTorrent --scratch-path .build/benchmark-release --show-bin-path)
cp Butter/UI/TorrentInspector.swift "$ui_profile_work/TorrentInspector.swift"
cat >> "$ui_profile_work/TorrentInspector.swift" <<'SWIFT'

// Test-only initial selection; production layout and defaults remain unchanged.
extension TorrentInspector {
	init(profiledTorrent: TransferSnapshot) {
		self.init(torrent: profiledTorrent)
		_tab = State(initialValue: "Files")
	}
}
SWIFT
set --
for ui_profile_source in Butter/UI/*.swift; do
	[ "$ui_profile_source" = Butter/UI/TorrentInspector.swift ] || set -- "$@" "$ui_profile_source"
done
swiftc -O -swift-version 5 -parse-as-library -module-cache-path "$ui_profile_work/modules" \
	Butter/Core/*.swift Butter/Engine/*.swift Butter/TransferStore.swift Butter/ContentView.swift "$@" "$ui_profile_work/TorrentInspector.swift" Tests/ApplicationUIProfile.swift \
	-I "$ui_profile_bin" -L "$ui_profile_bin" -lButterTorrentEngine -lButterTorrentStorage -lButterTorrentNetworking -lButterTorrentMetadata \
	-framework AppKit -framework SystemConfiguration -o "$ui_profile_work/ApplicationUIProfile" >> "$ui_profile_out/build.log" 2>&1
ruby -rjson -rdigest -ropen3 -e '
 capture = ->(*args) { value, status = Open3.capture2e(*args); raise value unless status.success?; value.strip }
 files = Dir.glob("Butter/{Core,Engine,UI}/*.swift") + %w[Butter/ContentView.swift Butter/TransferStore.swift Tests/ApplicationUIProfile.swift Scripts/test-ui-profile.sh Tests/TransferBenchmarkHarness.rb]
 files += Dir.glob("Packages/ButterTorrent/Sources/**/*.swift")
 puts JSON.pretty_generate({revision: capture.call("git", "rev-parse", "HEAD"), dirty: capture.call("git", "status", "--short"), swift: capture.call("swift", "--version"), os: capture.call("sw_vers"),
  scope: "Synthetic models rendered by production ContentView and optional adjacent TorrentInspector, with test-only Files initial selection; includes window creation and 12 updates one second apart; 2000 files or 200 torrents with 512 files each; no payload or networking; not timing acceptance",
  visible_only: ENV["BUTTER_UI_PROFILE_VISIBLE_ONLY"] == "1",
  source_sha256: files.sort.to_h { |path| [path, Digest::SHA256.file(path).hexdigest] }, driver_sha256: Digest::SHA256.file(ARGV[0]).hexdigest, flags: "Release package; application swiftc -O -swift-version 5"})
' "$ui_profile_work/ApplicationUIProfile" > "$ui_profile_out/environment.json"
ruby -I Tests -rTransferBenchmarkHarness -e '
 h = TransferBenchmarkHarness; driver, out = ARGV; results = []
 %w[many-files many-torrents].product(%w[download seed], [false, true]).each do |workload, role, inspector|
  next if ENV["BUTTER_UI_PROFILE_VISIBLE_ONLY"] == "1" && !inspector
  id = [workload, role, inspector ? "visible" : "hidden"].join("-"); prefix = File.join(out,id)
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
   trace.export; File.write(prefix + ".cpu.json", JSON.pretty_generate(h.profile_summary(prefix + ".samples.xml", child.phase("ready").fetch("pid"))))
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
 raise "UI profiling contains failed captures" if results.any? { |row| !row[:accepted] }
' "$ui_profile_work/ApplicationUIProfile" "$ui_profile_out"
