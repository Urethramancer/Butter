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

private func blockedVerifiedStorage(_ body: (TorrentStorage, Data, StorageWorker, DiskGate) async throws -> Void) async throws {
	try await storageFixture { root in
		let (metadata, bytes) = try storageMetadata(root)
		let storage = try await TorrentStorage.open(metadata: metadata, destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"))
		try await storage.importFiles(from: root)
		for piece in 0..<storage.layout.pieceCount { #expect(try await storage.verify(piece: piece)) }
		let worker = await storage.worker, gate = DiskGate(); gate.arm()
		let blocker = Task { try await worker.run { _ in gate.enter() } }
		try await gate.wait()
		do { try await body(storage, bytes, worker, gate) }
		catch { gate.release(); _ = try? await blocker.value; try? await storage.shutdown(); throw error }
		gate.release(); try await blocker.value; try await storage.shutdown()
	}
}

private func waitForCommands(_ worker: StorageWorker, _ count: Int) async throws {
	try await storageDeadline { while worker.pendingCount != count { await Task.yield() } }
}

@Suite struct StorageConcurrencyTests {
	@Test(arguments: [false, true]) func queuedVerifiedReadsCancelIndependently(_ cancelFirst: Bool) async throws {
		try await blockedVerifiedStorage { storage, bytes, worker, gate in
			let first = Task { try await storage.readVerifiedPiece(0) }
			try await waitForCommands(worker, 2)
			let second = Task { try await storage.readVerifiedPiece(2) }
			try await waitForCommands(worker, 3)
			(cancelFirst ? first : second).cancel(); gate.release()
			await #expect(throws: CancellationError.self) { try await (cancelFirst ? first : second).value }
			let tail = Data([1, 2, 3]) + Data(repeating: 0, count: try storage.layout.length(of: 2) - 3)
			#expect(try await (cancelFirst ? second : first).value == (cancelFirst ? tail : bytes.prefix(16384)))
			#expect(try await storage.readVerifiedPiece(cancelFirst ? 0 : 2) == (cancelFirst ? bytes.prefix(16384) : tail))
			#expect(try await storage.snapshot().verifiedPieces == [0, 1, 2])
		}
	}
	@Test func queuedWriteSeparatesVerifiedReads() async throws {
		try await blockedVerifiedStorage { storage, bytes, worker, gate in
			let first = Task { try await storage.readVerifiedPiece(0) }
			try await waitForCommands(worker, 2)
			let write = Task { try await storage.write(piece: 0, offset: 0, data: Data([255])) }
			try await waitForCommands(worker, 3)
			let second = Task { try await storage.readVerifiedPiece(0) }
			try await waitForCommands(worker, 4); gate.release()
			#expect(try await first.value == bytes.prefix(16384)); try await write.value
			await #expect(throws: StorageFailure.invalid("piece has not been verified")) { try await second.value }
			#expect(try await storage.snapshot().verifiedPieces == [1, 2])
		}
	}
	@Test func bulkWorkReservesCapacityWithoutReorderingABlockedOwner() async throws {
		let pool = DiskWorkPool(maximum: 2), probe = DiskPoolProbe(), first = UUID(), second = UUID(), control = UUID()
		for (owner, bulk, label) in [(first, true, "a"), (second, true, "b1"), (second, false, "b2"), (control, false, "control")] {
			pool.submit(owner: owner, bulk: bulk) { probe.run(owner, label: label) }
		}
		do {
			try await storageDeadline { while probe.active != 2 { try await Task.sleep(for: .milliseconds(5)) } }
			#expect(Set(probe.started) == ["a", "control"])
			probe.release()
			try await storageDeadline { while probe.completed != 4 { try await Task.sleep(for: .milliseconds(5)) } }
			#expect(probe.started.filter { $0.hasPrefix("b") } == ["b1", "b2"])
			#expect(!probe.overlappedOwner && probe.peak == 2)
		} catch { probe.release(); throw error }
	}
	@Test func diskPoolBoundsParallelOwnersAndPreservesEachOwnersOrder() async throws {
		let pool = DiskWorkPool(maximum: 2), probe = DiskPoolProbe(), first = UUID(), second = UUID(), third = UUID()
		for (owner, label) in [(first, "a1"), (first, "a2"), (second, "b"), (third, "c")] {
			pool.submit(owner: owner) { probe.run(owner, label: label) }
		}
		do {
			try await storageDeadline {
				while probe.active != 2 { try await Task.sleep(for: .milliseconds(5)) }
			}
			#expect(probe.started == ["a1", "b"] || probe.started == ["b", "a1"])
			probe.release()
			try await storageDeadline {
				while probe.completed != 4 { try await Task.sleep(for: .milliseconds(5)) }
			}
			#expect(probe.peak == 2 && !probe.overlappedOwner)
			#expect(probe.started.filter { $0.hasPrefix("a") } == ["a1", "a2"])
		} catch { probe.release(); throw error }
	}
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

private final class DiskPoolProbe: @unchecked Sendable {
	private let lock = NSLock()
	private let gate = DispatchSemaphore(value: 0)
	private var owners: Set<UUID> = []
	private var labels: [String] = []
	private var maximum = 0, finished = 0
	private var overlap = false
	var active: Int { lock.withLock { owners.count } }
	var completed: Int { lock.withLock { finished } }
	var peak: Int { lock.withLock { maximum } }
	var started: [String] { lock.withLock { labels } }
	var overlappedOwner: Bool { lock.withLock { overlap } }
	func run(_ owner: UUID, label: String) {
		lock.withLock {
			if !owners.insert(owner).inserted { overlap = true }
			labels.append(label); maximum = max(maximum, owners.count)
		}
		_ = gate.wait(timeout: .now() + 5)
		lock.withLock { owners.remove(owner); finished += 1 }
	}
	func release() { for _ in 0..<4 { gate.signal() } }
}
