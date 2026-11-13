import Foundation

enum CoreRegressionTests {
	static func quitModes() throws {
		var paused = fixture(); paused.state = "Paused"
		for (mode, empty, download, seed) in [("Always", true, true, true), ("Never", false, false, false), ("Active Transfers", false, true, true), ("Active Downloads", false, true, false)] {
			try require(QuitPolicy.shouldConfirm(mode: mode, transfers: [], wanted: []) == empty, "Empty quit mode \(mode)")
			try require(QuitPolicy.shouldConfirm(mode: mode, transfers: [fixture()], wanted: ["a"]) == download, "Download quit mode \(mode)")
			try require(QuitPolicy.shouldConfirm(mode: mode, transfers: [fixture(complete: true)], wanted: ["a"]) == seed, "Seed quit mode \(mode)")
			try require(QuitPolicy.shouldConfirm(mode: mode, transfers: [paused], wanted: ["a"]) == empty, "Queued quit mode \(mode)")
			try require(QuitPolicy.shouldConfirm(mode: mode, transfers: [fixture()], wanted: []) == empty, "Stopped quit mode \(mode)")
		}
	}
	static func parsers() throws {
		for (url, valid) in [("https://:80/announce", false), ("https://tracker:99999/announce", false), ("udp://tracker:0/announce", false), ("http://tracker:65535/announce", true), ("udp://tracker:1/announce", true), ("https://tracker/announce", true), ("https://tracker/a b", false), ("file:///tmp/tracker", false)] {
			try require(FavouriteTracker.valid(url) == valid, "Tracker boundary \(url)")
		}
		for bad in ["/1.2.3.4/24", "1.2.3.4/24/", "1..2.3", "256.0.0.0", "::/129", "::/", "1.2.3.4/-1", "1.2.3.4-::1", "2.0.0.0-1.0.0.0"] {
			do { _ = try Blocklist.parse(bad); throw TestFailure(description: "Accepted malformed blocklist: \(bad)") }
			catch is TestFailure { throw TestFailure(description: "Accepted malformed blocklist: \(bad)") } catch { }
		}
		for (input, first, last) in [("0.0.0.0/0", "0.0.0.0", "255.255.255.255"), ("::/0", "::", "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff"), ("255.255.255.255/32", "255.255.255.255", "255.255.255.255"), ("::1/128", "::1", "::1")] {
			let parsed = try Blocklist.parse(input)
			try require(parsed == [IPRange(first: first, last: last)], "CIDR boundary \(input)")
		}
		// Deterministic generated inputs cover overlap, adjacency, ordering and idempotence.
		for seed in 0..<128 {
			let input = (0..<16).map { index in
				let low = (seed * 17 + index * 31) % 240
				return IPRange(first: "10.0.0.\(low)", last: "10.0.0.\(low + 15)")
			}
			let merged = Blocklist.merge(input)
			let roundTrip = try Blocklist.parse(Blocklist.export(merged))
			try require(merged == roundTrip && Blocklist.merge(merged) == merged && Blocklist.merge(input.reversed()) == merged, "Merge invariants for seed \(seed)")
			for address in 0...255 {
				let ip = IPAddress("10.0.0.\(address)")!
				let contains: ([IPRange]) -> Bool = { $0.contains { IPAddress($0.first)! <= ip && ip <= IPAddress($0.last)! } }
				try require(contains(input) == contains(merged), "Merge changed membership")
			}
		}
	}
	static func estimator() throws {
		var estimator = CapacityEstimator()
		_ = estimator.observe(rate: 200_000, demand: true, now: 0)
		try require(estimator.estimate > 0, "Capacity is observed")
		let probing = estimator.observe(rate: 0, demand: false, now: 126)
		try require(probing && estimator.estimate == 0, "Expired capacity must not throttle new peers")
		_ = estimator.observe(rate: 500_000, demand: true, now: 127)
		try require(estimator.estimate > 500_000, "Capacity recovers after expiry")
	}
	static func storageFailures() async throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: root) }
		let storage = StateStorage(root: root)
		let initial = try await storage.load(); try await storage.save(initial)
		var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(initial)) as! [String: Any]
		legacy.removeValue(forKey: "cleanShutdown")
		let decoded = try JSONDecoder().decode(SavedState.self, from: JSONSerialization.data(withJSONObject: legacy))
		try require(!decoded.cleanShutdown, "Old state must require unclean-launch validation")
		var clean = initial; clean.cleanShutdown = true
		try await storage.save(clean)
		let cleanReload = try await storage.load()
		try require(cleanReload.cleanShutdown, "Clean marker survives durable replacement")
		let url = root.appendingPathComponent("state.json"), original = try Data(contentsOf: url)
		let failing = StateStorage(root: root, write: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
		do { try await failing.save(SavedState()); throw TestFailure(description: "Write failure was swallowed") } catch is TestFailure { throw TestFailure(description: "Write failure was swallowed") } catch { }
		let actual = try Data(contentsOf: url); try require(actual == original, "Failed replacement must preserve previous state")
		var invalid = SavedState(); invalid.transfers = [TransferRecord(id: "../escape", source: "x", destination: "/tmp")]
		for state in [invalid, SavedState(transfers: [TransferRecord(id: "same", source: "x", destination: "/tmp"), TransferRecord(id: "same", source: "y", destination: "/tmp")])] {
			try JSONEncoder().encode(state).write(to: url)
			do { _ = try await storage.load(); throw TestFailure(description: "Invalid identity accepted") } catch is TestFailure { throw TestFailure(description: "Invalid identity accepted") } catch { }
		}
		try Data("{broken".utf8).write(to: url)
		do { _ = try await storage.load(); throw TestFailure(description: "Corrupt state accepted") } catch is TestFailure { throw TestFailure(description: "Corrupt state accepted") } catch { }
		let corrupt = try Data(contentsOf: url); try require(corrupt == Data("{broken".utf8), "Load must retain corrupt state for recovery")
	}
	static func watchedReplacement() async throws {
		let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try fm.createDirectory(at: root, withIntermediateDirectories: true)
		defer { try? fm.removeItem(at: root) }
		let url = root.appendingPathComponent("example.torrent"), watcher = FolderWatcher(), now = Date().addingTimeInterval(10)
		try Data([1, 2, 3]).write(to: url)
		_ = try await watcher.scan(root.path, imported: [], now: now)
		let files = try await watcher.scan(root.path, imported: [], now: now.addingTimeInterval(4))
		try require(files.count == 1, "Watched fixture ready")
		let replacement = Data([4, 5, 6])
		try replacement.write(to: url, options: .atomic)
		try await watcher.removeImported(files[0])
		let actual = try Data(contentsOf: url); try require(actual == replacement, "Replacement must survive deletion of imported original")
		_ = try await watcher.scan(root.path, imported: [], now: now.addingTimeInterval(5))
		let next = try await watcher.scan(root.path, imported: [], now: now.addingTimeInterval(9))
		try require(next.count == 1 && next[0].signature != files[0].signature, "Replacement has a distinct identity")
		try await watcher.removeImported(next[0])
		try require(!fm.fileExists(atPath: url.path), "Unchanged imported original is removed")
		try fm.createSymbolicLink(at: url, withDestinationURL: root.appendingPathComponent("missing"))
		let symlinks = try await watcher.scan(root.path, imported: [], now: now.addingTimeInterval(13))
		try require(symlinks.isEmpty, "Watcher must ignore symlinks")
	}
}
