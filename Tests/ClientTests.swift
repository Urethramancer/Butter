import Foundation
import AppKit

struct TestFailure: Error, CustomStringConvertible { var description: String }
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws { if !condition() { throw TestFailure(description: message) } }
func fixture(id: String = "a", complete: Bool = false) -> TransferSnapshot {
	TransferSnapshot(id: id, name: "Example Linux", path: "/tmp/download", state: complete ? "Seeding" : "Downloading", error: "", metadata: true, private: false, complete: complete, progress: complete ? 1 : 0, wanted: 1024, done: complete ? 1024 : 0, total: 1024, down: 0, up: 0, downloaded: 0, uploaded: 0, demand: false, hashes: ["hash"], pieces: [0], files: [TransferFile(index: 0, path: "linux/image.bin", original: "linux/image.bin", size: 1024, done: 0, selected: true, pad: false)], trackers: [TrackerSnapshot(url: "https://user:secret@tracker.example/announce?key=secret", message: "")], peers: [])
}
func observation(_ id: String, _ priority: TransferPriority = .normal, order: Int = 0, complete: Bool = false, force: Bool = false, rate: Int = 100_000, demand: Bool = true) -> TransferObservation {
	TransferObservation(id: id, order: order, priority: priority, wanted: true, force: force, complete: complete, blocked: false, downloadRate: rate, uploadRate: rate, downloadDemand: demand && !complete, uploadDemand: demand)
}
@main struct ClientTests {
	static func main() async {
		do {
			let cases: [(String, () async throws -> Void)] = [
				("groups", { try groups() }), ("queue", { try queue() }), ("bandwidth", { try bandwidth() }),
				("piece-state-encoding", { try pieceStateEncoding() }),
				("blocklists", { try blocklists() }), ("persistence-watcher", { try await persistenceAndWatcher() }),
				("port-checker", { try await checker() }), ("parser-invariants", { try CoreRegressionTests.parsers() }),
				("estimator-expiry", { try CoreRegressionTests.estimator() }),
				("storage-failures", { try await CoreRegressionTests.storageFailures() }),
				("watched-replacement", { try await CoreRegressionTests.watchedReplacement() }),
				("watcher-race-boundaries", { try await CoreRegressionTests.watcherRaceBoundaries() }),
				("watcher-read-limits", { try await CoreRegressionTests.watcherReadLimits() }),
				("quit-modes", { try CoreRegressionTests.quitModes() })
			]
			let filter = ProcessInfo.processInfo.environment["BUTTER_TEST_CASE"]
			guard filter == nil || cases.contains(where: { $0.0 == filter }) else { throw TestFailure(description: "Unknown test case: \(filter!)") }
			for (name, run) in cases where filter == nil || filter == name { try await run(); print("PASS: \(name)") }
		} catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
	}
	static func pieceStateEncoding() throws {
		var snapshot = fixture(); snapshot.pieces = [0, 1, 2, 3, 4]
		let encoded = try JSONEncoder().encode(snapshot)
		let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
		try require(object["pieces"] as? [Int] == [0, 1, 2, 3, 4], "Compact states retain the numeric JSON contract")
		let decoded = try JSONDecoder().decode(TransferSnapshot.self, from: encoded)
		try require(decoded.pieces == snapshot.pieces, "All display states round-trip")
		let v1 = String(repeating: "a", count: 40), v2 = String(repeating: "b", count: 64)
		for (hashes, label): ([String], String?) in [([], nil), ([v1], "v1"), ([v2], "v2"), ([v2, v1], "Hybrid")] {
			snapshot.hashes = hashes; snapshot.metadata = true
			try require(snapshot.formatLabel == label, "Format badge follows metadata identities")
			snapshot.metadata = false
			try require(snapshot.formatLabel == nil, "Pending magnets do not claim a metadata format")
		}
	}
	static func groups() throws {
		let t = fixture()
		let first = TorrentGroup(name: "First", priority: .high, trackerHosts: "example", maximumMiB: 1, keywords: "unrelated, linux")
		let second = TorrentGroup(name: "Second", priority: .low)
		try require(TransferGrouping.group(for: t, groups: [first, second])?.id == first.id, "First matching group must win")
		try require(TransferGrouping.priority(nil, torrent: t, groups: []) == .normal, "Unmatched transfers default to normal priority")
		var mismatch = first; mismatch.minimumMiB = 2
		try require(!mismatch.matches(t), "All group criteria must match")
		mismatch = first; mismatch.trackerHosts = "notexample"
		try require(!mismatch.matches(t), "Tracker hosts must match domain boundaries")
		var magnet = t; magnet.metadata = false
		try require(!first.matches(magnet), "Unresolved magnets must not match")
		try require(TransferGrouping.priority(nil, torrent: t, groups: [first]) == .high, "Priority must inherit")
		try require(TransferGrouping.priority(.low, torrent: t, groups: [first]) == .low, "Explicit priority overrides group")
		try require(FavouriteTracker.valid("udp://tracker.example:80/announce") && !FavouriteTracker.valid("file:///tmp/no"), "Validate tracker URLs")
	}
	static func queue() throws {
		var scheduler = TransferScheduler(clock: { 100 })
		let inputs = [observation("normal", order: 0), observation("high", .high, order: 1), observation("forced", .low, force: true), observation("seed", complete: true), observation("later", order: 2)]
		let result = scheduler.schedule(inputs, downloads: 1, seeds: 1)
		try require(result["high"]?.running == true && result["normal"]?.running == false, "Admit higher priority first")
		try require(result["forced"]?.running == true && result["seed"]?.running == true, "Force Start bypasses independent limits")
		let tied = scheduler.schedule([observation("late", order: 2), observation("early", order: 1)], downloads: 1, seeds: 0)
		try require(tied["early"]?.running == true && tied["late"]?.running == false, "Break ties by addition order")
		var queued = observation("queued", complete: true, rate: 0, demand: false); queued.blocked = true
		_ = scheduler.stoppedSeeds([queued], idleMinutes: 1)
		try require(scheduler.stoppedSeeds([queued], idleMinutes: 1).isEmpty, "Queued seeds do not accrue idle time")
		var now = 0.0; var idle = TransferScheduler(clock: { now }); let seed = observation("idle", complete: true, rate: 0, demand: false)
		_ = idle.stoppedSeeds([seed], idleMinutes: 1); now = 61
		try require(idle.stoppedSeeds([seed], idleMinutes: 1) == ["idle"], "Stop a running seed after configured idle time")
		var requested = seed; requested.uploadDemand = true; now = 62
		try require(idle.stoppedSeeds([requested], idleMinutes: 1).isEmpty, "Upload demand resets the idle clock")
		var ratio = fixture(complete: true); ratio.uploaded = 2048; ratio.downloaded = 1024
		for (limit, stopped) in [(0.0, false), (1.0, true), (2.0, true), (3.0, false)] { try require(TransferStoppingPolicy.reachedRatio(ratio, limit: limit) == stopped, "Seed ratio stopping at \(limit)") }
		ratio.complete = false; try require(!TransferStoppingPolicy.reachedRatio(ratio, limit: 1), "Ratio stopping applies only to completed transfers")
	}
	static func bandwidth() throws {
		var now = 0.0; var scheduler = TransferScheduler(clock: { now })
		let peers = [observation("a"), observation("b")]
		_ = scheduler.schedule(peers, downloads: 3, seeds: 3); now = 6
		let equal = scheduler.schedule(peers, downloads: 3, seeds: 3)
		try require(equal["a"]?.downloadLimit == equal["b"]?.downloadLimit && equal["a"]!.downloadLimit > 0, "Equal priorities must receive equal opportunities")
		let spare = scheduler.schedule([observation("high", .high, rate: 1000), observation("low", .low, rate: 100_000)], downloads: 3, seeds: 3)
		try require(spare["low"]!.downloadLimit > spare["high"]!.downloadLimit, "Spare capacity must reach lower priorities")
		now = 31
		let probe = scheduler.schedule(peers, downloads: 3, seeds: 3)
		try require(probe.values.allSatisfy { $0.downloadLimit == 0 && $0.uploadLimit == 0 }, "Periodic unrestricted probes recover capacity")
		now = 36
		let recovered = scheduler.schedule([observation("a", rate: 1_000_000), observation("b", rate: 1_000_000)], downloads: 3, seeds: 3)
		try require(recovered["a"]!.downloadLimit > equal["a"]!.downloadLimit, "Estimator recovers after a low initial observation")
		let lone = scheduler.schedule([observation("only", .low)], downloads: 1, seeds: 1)
		try require(lone["only"]?.downloadLimit == 0, "Lone transfer remains unrestricted")
	}
	static func blocklists() throws {
		let ranges = try Blocklist.parse("label:1.2.3.0-1.2.3.10\n001.002.003.009 - 001.002.003.020 , 000 , label\n1.2.3.21\n2001:db8::/126\n")
		try require(ranges.count == 2 && ranges[0] == IPRange(first: "1.2.3.0", last: "1.2.3.21"), "Merge overlaps and adjacent ranges")
		let roundTrip = try Blocklist.parse(Blocklist.export(ranges)); try require(roundTrip == ranges, "Optimised export round trip")
		do { _ = try Blocklist.parse("invalid\n1.2.3.999"); throw TestFailure(description: "Malformed lines accepted") } catch is TestFailure { throw TestFailure(description: "Malformed lines accepted") } catch { }
	}
	static func persistenceAndWatcher() async throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: root) }
		let storage = StateStorage(root: root)
		var state = try await storage.load(); state.transfers = [TransferRecord(source: "magnet:?xt=test", destination: "/tmp", priority: .high)]; state.preferences.autoRemove = true
		try await storage.save(state)
		let restored = try await storage.load()
		try require(restored.transfers.first?.id == state.transfers.first?.id && restored.preferences.autoRemove, "Persist transfer identity and preferences")
		let watcher = FolderWatcher(), file = root.appendingPathComponent("arriving.torrent")
		try Data([1, 2, 3]).write(to: file)
		let now = Date().addingTimeInterval(10)
		let early = try await watcher.scan(root.path, imported: [], now: now)
		try require(early.isEmpty, "Watch imports wait for stability")
		let stable = try await watcher.scan(root.path, imported: [], now: now.addingTimeInterval(4))
		try require(stable.count == 1, "Stable torrent becomes ready")
		let seen = try await watcher.scan(root.path, imported: [stable[0].signature], now: now.addingTimeInterval(8))
		try require(seen.isEmpty, "Avoid repeated watched imports")
	}
	static func checker() async throws {
		let unavailable = PortChecker(fetch: { _ in throw URLError(.cannotConnectToHost) })
		let result = await unavailable.check(6881)
		try require(result.hasPrefix("Unknown"), "Unavailable services must report unknown")
		for (body, expected) in [("1", "External TCP reachable"), ("0", "External TCP not reachable"), ("html", "Unknown")] {
			let checker = PortChecker(fetch: { request in (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) })
			let result = await checker.check(6881); try require(result.hasPrefix(expected), "Port checker response \(body)")
		}
	}
}
