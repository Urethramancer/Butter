import Foundation
import Testing
@testable import ButterTorrentStorage

private final class DiskGate: @unchecked Sendable {
	private let lock = NSLock()
	private var armed = false
	private let semaphore = DispatchSemaphore(value: 0)
	let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
	func arm() { lock.withLock { armed = true } }
	func enter() {
		guard lock.withLock({ if !armed { return false }; armed = false; return true }) else { return }
		entered.continuation.yield(())
		_ = semaphore.wait(timeout: .now() + 5)
	}
	func release() { semaphore.signal() }
	func wait() async throws {
		try await storageDeadline { for await _ in self.entered.stream { return }; throw StorageFailure.closed }
	}
}

private func storageDeadline<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
	try await withThrowingTaskGroup(of: T.self) { group in
		group.addTask(operation: operation)
		group.addTask { try await Task.sleep(for: .seconds(5)); throw StorageFailure.invalid("test deadline") }
		defer { group.cancelAll() }; return try await group.next()!
	}
}

@Suite struct StorageConcurrencyTests {
	@Test func cancellationLeavesDurableJournalAndMalformedRecoveryDoesNotTouchFiles() async throws {
		try await storageFixture { root in
			let (metadata, bytes) = try storageMetadata(root), gate = DiskGate()
			let storage = try await TorrentStorage.open(metadata: metadata, destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"), event: { if $0 == .journalDurable { gate.enter() } })
			try await storage.importFiles(from: root)
			gate.arm()
			let rename = Task { try await storage.rename([0: "renamed/a"]) }
			try await gate.wait(); rename.cancel(); gate.release()
			await #expect(throws: CancellationError.self) { try await rename.value }
			#expect(try await storage.snapshot().needsRecovery)
			await #expect(throws: StorageFailure.self) { try await storage.write(piece: 0, offset: 0, data: Data([1])) }
			let state = try StorageDirectory(root.appendingPathComponent("state"))
			let original = try state.read("operation.plist", maximum: 33_554_432)
			var corrupt = try PropertyListDecoder().decode(StorageJournal.self, from: original)
			corrupt.version = 99; try state.atomic(corrupt.encoded(), path: "operation.plist")
			await #expect(throws: StorageFailure.self) { try await storage.recover() }
			#expect(try Data(contentsOf: root.appendingPathComponent("data/source/a")) == bytes)
			try state.atomic(original, path: "operation.plist")
			try await storage.recover()
			#expect(try Data(contentsOf: root.appendingPathComponent("data/renamed/a")) == bytes)
			try await storage.shutdown()
		}
	}
	@Test func boundedWorkerRejectsExcessAndSettlesActiveCancellation() async throws {
		let worker = StorageWorker(), gate = DiskGate()
		gate.arm()
		let active = Task { try await worker.run { cancellation in gate.enter(); try cancellation.check() } }
		try await gate.wait()
		let rejected = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
		let pending = Task {
			await withTaskGroup(of: Bool.self) { group in
				for _ in 0..<16 {
					group.addTask {
						do { try await worker.run { _ in }; return true }
						catch StorageFailure.limit { rejected.continuation.yield(()); return false }
						catch { Issue.record("Unexpected worker error: \(error)"); return false }
					}
				}
				var results: [Bool] = []
				for await result in group { results.append(result) }; return results
			}
		}
		try await storageDeadline { for await _ in rejected.stream { return }; throw StorageFailure.closed }
		active.cancel(); gate.release()
		await #expect(throws: CancellationError.self) { try await active.value }
		let results = await pending.value
		#expect(results.count == 16 && results.contains(false))
	}
}
