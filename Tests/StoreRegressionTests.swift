import Foundation

@MainActor final class FakeEngine: EngineOperations, @unchecked Sendable {
	var commands: [String] = []
	var addFailure = false
	nonisolated var creationProgress: Double { 0 }
	nonisolated func cancelCreation() { }
	func perform(_ command: String, _ payload: [String: Any]) async throws -> Data {
		commands.append(command)
		if command == "add" && addFailure { throw CocoaError(.fileReadNoPermission) }
		await Task.yield()
		if command == "add" { return try JSONSerialization.data(withJSONObject: ["id": payload["id"]!, "duplicate": false]) }
		return Data("{}".utf8)
	}
	func snapshot() async throws -> EngineSnapshot { EngineSnapshot(transfers: [], events: [], port: 0, udp: false, networkError: "", creationProgress: 0) }
}

enum StoreRegressionTests {
	@MainActor static func run() async throws {
		let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try fm.createDirectory(at: root, withIntermediateDirectories: true)
		defer { try? fm.removeItem(at: root) }
		let url = root.appendingPathComponent("state.json"), corrupt = Data("invalid state".utf8)
		try corrupt.write(to: url)
		let damaged = TransferStore(root: root, engine: FakeEngine(), automaticPolling: false, allowsSystemIntegration: false)
		await damaged.start()
		try check(!damaged.ready && damaged.error != nil, "Invalid saved state is reported")
		let stopped = await damaged.shutdown()
		let retained = try Data(contentsOf: url)
		try check(!stopped && retained == corrupt, "Shutdown must retain unreadable saved state")
		var saved = SavedState()
		saved.transfers = [TransferRecord(id: "restored", source: "magnet:?xt=test", destination: root.path)]
		try await StateStorage(root: root).save(saved)
		let engine = FakeEngine(), store = TransferStore(root: root, engine: engine, automaticPolling: false, allowsSystemIntegration: false)
		async let first: Void = store.start()
		async let second: Void = store.start()
		_ = await (first, second)
		try check(store.ready && engine.commands.filter { $0 == "add" }.count == 1, "Concurrent startup restores exactly once")
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
		let failing = StateStorage(root: root, write: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
		let rollbackEngine = FakeEngine()
		let rollback = TransferStore(root: root, engine: rollbackEngine, storage: failing, automaticPolling: false, allowsSystemIntegration: false)
		await rollback.start()
		let added = await rollback.add(AddRequest(source: "magnet:?xt=test", destination: root.path, start: false), id: "rollback")
		try check(!added && rollback.record("rollback") == nil && rollbackEngine.commands.last == "remove", "Failed persistence rolls back imported handle and record")
		await rollback.remove(["restored"], trash: false)
		await rollback.refresh()
		try check(rollback.record("restored")?.wanted == false && rollback.transfers.first?.error.contains("Metadata was retained") == true && !rollbackEngine.commands.contains("forget"), "Removal save failure retains metadata and a paused recovery record")
		let suspending = SuspendingStorage()
		let serial = TransferStore(root: root, engine: FakeEngine(), storage: suspending, automaticPolling: false, allowsSystemIntegration: false)
		await serial.start()
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
}

actor SuspendingStorage: StatePersisting {
	private var continuation: CheckedContinuation<Void, Never>?
	private(set) var entered = 0
	private(set) var written: [String] = []
	func load() async throws -> SavedState { SavedState() }
	func save(_ state: SavedState) async throws {
		entered += 1
		if entered == 1 { await withCheckedContinuation { continuation = $0 } }
		written.append(state.transfers.first?.id ?? "empty")
	}
	func release() { continuation?.resume(); continuation = nil }
}
