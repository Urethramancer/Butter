import Foundation

@MainActor final class FakeEngine: EngineOperations, @unchecked Sendable {
	var commands: [String] = []
	var bandwidth: [String: Int] = [:]
	var addFailure = false
	var holdSnapshot = false
	var holdShutdown = false
	var cleanShutdownEligible = true
	private(set) var gateEntered = false
	private var gate: CheckedContinuation<Void, Never>?
	func release() { holdSnapshot = false; holdShutdown = false; gate?.resume(); gate = nil }
	private func wait() async { gateEntered = true; await withCheckedContinuation { gate = $0 } }
	nonisolated var creationProgress: Double { 0 }
	nonisolated func cancelCreation() { }
	func perform(_ command: String, _ payload: [String: Any]) async throws -> Data {
		commands.append(command)
		if command == "bandwidth" { bandwidth = payload as? [String: Int] ?? [:] }
		if command == "shutdown", holdShutdown { await wait() }
		if command == "add" && addFailure { throw CocoaError(.fileReadNoPermission) }
		await Task.yield()
		if command == "add" { return try JSONSerialization.data(withJSONObject: ["id": payload["id"]!, "duplicate": false]) }
		if command == "shutdown" { return try JSONSerialization.data(withJSONObject: ["cleanShutdownEligible": cleanShutdownEligible]) }
		return Data("{}".utf8)
	}
	func snapshot() async throws -> EngineSnapshot {
		if holdSnapshot { await wait() }
		return EngineSnapshot(transfers: [], events: [], port: 0, udp: false, networkError: "", creationProgress: 0)
	}
}

enum StoreRegressionTests {
	@MainActor static func run() async throws {
		let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try fm.createDirectory(at: root, withIntermediateDirectories: true)
		defer { try? fm.removeItem(at: root) }
		try await shutdownDeadlines(root)
		try await cleanMarkers(root)
		try await interruptedCleanMarker(root)
		let url = root.appendingPathComponent("state.json"), corrupt = Data("invalid state".utf8)
		try corrupt.write(to: url)
		let damaged = TransferStore(root: root, engine: FakeEngine(), automaticPolling: false, allowsSystemIntegration: false)
		await damaged.start()
		try check(!damaged.ready && damaged.error != nil, "Invalid saved state is reported")
		let stopped = await damaged.shutdown()
		let retained = try Data(contentsOf: url)
		try check(!stopped && retained == corrupt, "Shutdown must retain unreadable saved state")
		var saved = SavedState()
		saved.preferences.downloadLimit = 62_500_000
		saved.transfers = [TransferRecord(id: "restored", source: "magnet:?xt=test", destination: root.path)]
		try await StateStorage(root: root).save(saved)
		let engine = FakeEngine(), store = TransferStore(root: root, engine: engine, automaticPolling: false, allowsSystemIntegration: false)
		async let first: Void = store.start()
		async let second: Void = store.start()
		_ = await (first, second)
		try check(store.ready && engine.commands.filter { $0 == "add" }.count == 1, "Concurrent startup restores exactly once")
		try check(engine.bandwidth == ["downloadLimit": 62_500_000, "uploadLimit": 0], "Restore the download cap before starting transfers")
		let previous = store.preferences
		store.preferences.downloadLimit = nil; store.preferences.uploadLimit = 1_250_000
		await store.settingsChanged(from: previous)
		let updated = try await StateStorage(root: root).load().preferences
		try check(updated == store.preferences && engine.bandwidth == ["downloadLimit": 0, "uploadLimit": 1_250_000], "Editing a cap updates the live engine and persists both directions")
		let failedEngine = FakeEngine(); failedEngine.addFailure = true
		let failedRestore = TransferStore(root: root, engine: failedEngine, automaticPolling: false, allowsSystemIntegration: false)
		await failedRestore.start(); await failedRestore.refresh()
		try check(failedRestore.transfers.count == 1 && !failedRestore.transfers[0].error.isEmpty, "Failed restoration remains visible and actionable")
		await failedRestore.remove(["restored"], trash: false)
		try check(failedRestore.records.isEmpty && !failedEngine.commands.contains("remove"), "Failed restoration can be removed without touching data")
		try await StateStorage(root: root).save(saved)
		await store.checkPort()
		try check(store.portStatus.contains("isolated"), "Test configuration stubs external port checks")
		let settings = store.networkSettings()
		try check(settings["mapping"] as? Bool == false && settings["dht"] as? Bool == false, "Test configuration disables router mapping and discovery")
		let selection = TransferStore(root: root, engine: FakeEngine(), automaticPolling: false, allowsSystemIntegration: false)
		selection.records = [TransferRecord(id: "a", source: "x", destination: root.path), TransferRecord(id: "b", source: "y", destination: root.path)]
		selection.selectFromList(["a"]); selection.selectFromList(["a", "b"])
		try check(selection.selection.isEmpty, "List changes must not publish during the view update")
		await drainSelectionQueue()
		try check(selection.selection == ["a", "b"], "Latest queued list selection wins")
		selection.selectFromList(["a"]); selection.selection = ["b"]; selection.selection = ["a", "b"]
		await drainSelectionQueue()
		try check(selection.selection == ["a", "b"], "Newer programmatic updates must win even when they return to the original value")
		selection.selectFromList(["a"]); selection.selection = ["b"]
		await drainSelectionQueue()
		try check(selection.selection == ["b"], "A newer programmatic selection must not be overwritten")
		selection.selectFromList(["a", "removed"])
		selection.records.removeAll { $0.id == "a" }
		await drainSelectionQueue()
		try check(selection.selection.isEmpty, "Deferred selection must discard removed IDs")
		let shutdown = await store.shutdown()
		try check(shutdown, "Fake store shuts down")
		let failing = SwitchableStorage(root: root)
		let rollbackEngine = FakeEngine()
		let rollback = TransferStore(root: root, engine: rollbackEngine, storage: failing, automaticPolling: false, allowsSystemIntegration: false)
		await rollback.start()
		await failing.failWrites()
		let added = await rollback.add(AddRequest(source: "magnet:?xt=test", destination: root.path, start: false), id: "rollback")
		try check(!added && rollback.record("rollback") == nil && rollbackEngine.commands.last == "remove", "Failed persistence rolls back imported handle and record")
		await rollback.remove(["restored"], trash: false)
		await rollback.refresh()
		try check(rollback.record("restored")?.wanted == false && rollback.transfers.first?.error.contains("Metadata was retained") == true && !rollbackEngine.commands.contains("forget"), "Removal save failure retains metadata and a paused recovery record")
		let suspending = SuspendingStorage()
		let serial = TransferStore(root: root, engine: FakeEngine(), storage: suspending, automaticPolling: false, allowsSystemIntegration: false)
		await serial.start()
		await suspending.holdNextSave()
		serial.records = [TransferRecord(id: "first", source: "x", destination: root.path)]
		let firstSave = Task { await serial.persist() }
		let deadline = ProcessInfo.processInfo.systemUptime + 5
		while await suspending.entered == 0 && ProcessInfo.processInfo.systemUptime < deadline { await Task.yield() }
		let entered = await suspending.entered
		try check(entered == 1, "First save reached its suspension point")
		serial.records = [TransferRecord(id: "second", source: "x", destination: root.path)]
		let secondSave = Task { await serial.persist() }
		await Task.yield(); await suspending.release()
		let saves = await (firstSave.value, secondSave.value)
		let written = await suspending.written
		try check(saves.0 && saves.1 && written == ["first", "second"], "Persistence serialises snapshots across suspension points")
		// A failed automatic import must retry unchanged bytes after a bounded backoff.
		let watch = root.appendingPathComponent("watch")
		try fm.createDirectory(at: watch, withIntermediateDirectories: true)
		let original = watch.appendingPathComponent("retry.torrent")
		try Data([1, 2, 3]).write(to: original)
		var time = Date().addingTimeInterval(10)
		let retryEngine = FakeEngine()
		retryEngine.addFailure = true
		let retry = TransferStore(root: root, engine: retryEngine, automaticPolling: false, allowsSystemIntegration: false, now: { time })
		await retry.start()
		retry.preferences.watchFolder = watch.path
		retry.preferences.deleteOriginal = true
		await retry.refresh(); time = time.addingTimeInterval(4); await retry.refresh()
		let before = retryEngine.commands.filter { $0 == "add" }.count
		retryEngine.addFailure = false
		await retry.refresh()
		try check(retryEngine.commands.filter { $0 == "add" }.count == before, "Watch failures back off")
		time = time.addingTimeInterval(31); await retry.refresh()
		try check(retryEngine.commands.filter { $0 == "add" }.count == before + 1 && !fm.fileExists(atPath: original.path), "Watch retries transient failure and deletes only successfully imported bytes")
		print("PASS: corrupt-state quit protection, concurrent startup, isolated services")
	}
	@MainActor private static func drainSelectionQueue() async {
		await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { continuation.resume() } }
	}
	@MainActor private static func cleanMarkers(_ root: URL) async throws {
		for eligible in [false, true] {
			let location = root.appendingPathComponent("marker-\(eligible)"), storage = StateStorage(root: location)
			var saved = SavedState(); saved.cleanShutdown = true
			try await storage.save(saved)
			let engine = FakeEngine(); engine.cleanShutdownEligible = eligible
			let store = TransferStore(root: location, engine: engine, automaticPolling: false, allowsSystemIntegration: false)
			await store.start()
			let launched = try await storage.load()
			try check(store.ready && !launched.cleanShutdown && engine.commands.first == "restorePolicy", "Launch clears the marker before engine restoration")
			let result = await store.shutdown()
			try check(result, "Ineligible completion does not prevent quitting")
			let stopped = try await storage.load()
			try check(stopped.cleanShutdown == eligible, "Shutdown uses fresh engine eligibility")
			let added = await store.add(AddRequest(source: "magnet:?xt=test", destination: location.path, start: true))
			try check(!added && !engine.commands.contains("add"), "Successful shutdown keeps new transfers stopped until termination")
		}
		let location = root.appendingPathComponent("marker-true"), engine = FakeEngine()
		let failing = StateStorage(root: location, write: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
		let store = TransferStore(root: location, engine: engine, storage: failing, automaticPolling: false, allowsSystemIntegration: false)
		await store.start()
		try check(!store.ready && store.error != nil && engine.commands.isEmpty, "Marker-clear failure prevents engine operations")
	}
	@MainActor private static func interruptedCleanMarker(_ root: URL) async throws {
		let storage = MarkerRaceStorage(), engine = FakeEngine()
		let store = TransferStore(root: root, engine: engine, storage: storage, automaticPolling: false, allowsSystemIntegration: false, shutdownTimeout: 0.05)
		await store.start()
		let quitting = Task { await store.shutdown() }
		let deadline = ContinuousClock.now + .seconds(2)
		while !(await storage.entered) && ContinuousClock.now < deadline { await Task.yield() }
		let entered = await storage.entered
		try check(entered, "Quit reached the clean-marker write")
		let stopped = await quitting.value
		try check(!stopped, "A suspended clean-marker write times out")
		await storage.release()
		while (await storage.history).suffix(2) != [true, false] && ContinuousClock.now < deadline { await Task.yield() }
		let history = await storage.history
		try check(history.suffix(2) == [true, false], "Late clean publication is durably cleared before resume")
	}
	@MainActor private static func shutdownDeadlines(_ root: URL) async throws {
		for boundary in ["polling", "save", "engine"] {
			let engine = FakeEngine(), storage = SuspendingStorage()
			engine.holdSnapshot = boundary == "polling"; engine.holdShutdown = boundary == "engine"
			let store = TransferStore(root: root.appendingPathComponent(boundary), engine: engine,
				storage: boundary == "save" ? storage : nil, automaticPolling: boundary == "polling", allowsSystemIntegration: false, shutdownTimeout: 0.05)
			await store.start()
			if boundary == "save" { await storage.holdNextSave() }
			if boundary == "polling" {
				let deadline = ContinuousClock.now + .seconds(2)
				while !engine.gateEntered && ContinuousClock.now < deadline { await Task.yield() }
				try check(engine.gateEntered, "Polling reached the cancellation-insensitive gate")
			}
			// A fallback release bounds the old implementation's regression case too.
			let release = Task {
				do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
				engine.release(); await storage.release()
			}
			let began = ContinuousClock.now, result = await store.shutdown()
			engine.release(); await storage.release(); release.cancel(); await release.value
			try check(!result && began.duration(to: .now) < .milliseconds(400), "Quit deadline covers \(boundary)")
			try check(store.error?.contains("remain open") == true, "Timed-out quit reports its retained operation")
			let deadline = ContinuousClock.now + .seconds(2)
			var completed = false
			repeat {
				completed = await store.shutdown()
				if !completed { try await Task.sleep(for: .milliseconds(5)) }
			} while !completed && ContinuousClock.now < deadline
			try check(completed, "Quit can be retried after the owned \(boundary) operation settles")
		}
		print("PASS: quit deadlines cover polling drain, persistence and engine shutdown with owned late completion")
	}
}

actor SuspendingStorage: StatePersisting {
	private var continuation: CheckedContinuation<Void, Never>?
	private(set) var entered = 0
	private(set) var written: [String] = []
	private var suspend = false
	func holdNextSave() { entered = 0; written = []; suspend = true }
	func load() async throws -> SavedState { SavedState() }
	func save(_ state: SavedState) async throws {
		entered += 1
		if suspend { suspend = false; await withCheckedContinuation { continuation = $0 } }
		written.append(state.transfers.first?.id ?? "empty")
	}
	func release() { continuation?.resume(); continuation = nil }
}

actor SwitchableStorage: StatePersisting {
	let storage: StateStorage
	var failing = false
	init(root: URL) { storage = StateStorage(root: root) }
	func failWrites() { failing = true }
	func load() async throws -> SavedState { try await storage.load() }
	func save(_ state: SavedState) async throws {
		if failing { throw CocoaError(.fileWriteOutOfSpace) }
		try await storage.save(state)
	}
}

actor MarkerRaceStorage: StatePersisting {
	private var continuation: CheckedContinuation<Void, Never>?
	private(set) var entered = false
	private(set) var history: [Bool] = []
	func load() async throws -> SavedState { SavedState() }
	func save(_ state: SavedState) async throws {
		if state.cleanShutdown { entered = true; await withCheckedContinuation { continuation = $0 } }
		history.append(state.cleanShutdown)
	}
	func release() { continuation?.resume(); continuation = nil }
}
