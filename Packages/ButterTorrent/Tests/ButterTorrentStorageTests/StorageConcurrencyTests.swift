import Foundation
import Testing
import ButterTorrentMetadata
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

private func blockedVerifiedStorage(selective: Bool = false, format: Int = 3, _ body: (TorrentStorage, Data, StorageWorker, DiskGate) async throws -> Void) async throws {
	try await storageFixture { root in
		let (original, bytes) = try storageMetadata(root)
		var metadata = original
		if format != 3 {
			var info = metadata.document.root["info"]!.dictionary!
			for key in format == 1 ? ["meta version", "file tree"] : ["pieces", "files", "length"] { info[Data(key.utf8)] = nil }
			var root: [Data: BencodeValue] = [Data("info".utf8): .dictionary(info)]
			if format == 2 { root[Data("piece layers".utf8)] = .dictionary(metadata.pieceLayers.mapValues(BencodeValue.bytes)) }
			metadata = try TorrentMetadata(BencodeValue.dictionary(root).encoded())
		}
		let selection = metadata.inspection.files.map { !$0.pad && (!selective || $0.path.hasSuffix("/a")) }
		let storage = try await TorrentStorage.open(metadata: metadata, destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"), selected: selection)
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

private enum ReadCancellation: CaseIterable, Sendable { case none, first, second }

private final class PieceReadProbe: @unchecked Sendable {
	private let lock = NSLock()
	private var calls = 0
	private let action: @Sendable () throws -> Void
	init(_ action: @escaping @Sendable () throws -> Void) { self.action = action }
	func check() throws {
		if lock.withLock({ calls += 1; return calls == 3 }) { try action() }
	}
}

@Suite struct StorageConcurrencyTests {
	@Test(arguments: [1, 2, 3], [false, true]) func explicitReadBatchKeepsPaddingSelectiveBytesAndLogicalAdmission(_ format: Int, selective: Bool) async throws {
		try await blockedVerifiedStorage(selective: selective, format: format) { storage, bytes, worker, gate in
			let reading = Task { try await storage.readVerifiedPieces([0, 1, 2]) }
			try await waitForCommands(worker, 4); gate.release()
			let results = try await reading.value
			#expect(results.count == 3)
			let expected = [Data(bytes.prefix(16384)), bytes.suffix(bytes.count - 16384) + Data(repeating: 0, count: 32768 - bytes.count), Data([1, 2, 3]) + Data(repeating: 0, count: try storage.layout.length(of: 2) - 3)]
			for piece in 0..<3 { let actual = try #require(results[piece]).get(); #expect(actual == expected[piece], "piece \(piece)") }
			#expect(try await storage.snapshot().verifiedPieces == [0, 1, 2])
		}
	}
	@Test func explicitReadBatchRejectsInvalidShapesWithoutReservingCredits() async throws {
		try await blockedVerifiedStorage { storage, _, worker, gate in
			for pieces in [[], Array(repeating: 0, count: 9)] {
				await #expect(throws: StorageFailure.limit("verified read batch pieces")) { try await storage.readVerifiedPieces(pieces) }
			}
			await #expect(throws: StorageFailure.invalid("duplicate verified read pieces")) { try await storage.readVerifiedPieces([0, 0]) }
			await #expect(throws: StorageFailure.invalid("piece index")) { try await storage.readVerifiedPieces([-1]) }
			#expect(worker.pendingCount == 1); gate.release()
		}
	}
	@Test func explicitReadBatchRejectsMoreThanTheExistingSinglePieceByteLimit() async throws {
		try await storageFixture { root in
			let info: [Data: BencodeValue] = [Data("name".utf8): .bytes(Data("payload".utf8)), Data("length".utf8): .integer(16_777_217), Data("piece length".utf8): .integer(16_777_216), Data("pieces".utf8): .bytes(Data(count: 40))]
			let metadata = try TorrentMetadata(BencodeValue.dictionary([Data("info".utf8): .dictionary(info)]).encoded())
			let storage = try await TorrentStorage.open(metadata: metadata, destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"))
			await #expect(throws: StorageFailure.limit("verified read batch bytes")) { try await storage.readVerifiedPieces([0, 1]) }
			#expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("data/payload").path))
			try await storage.shutdown()
		}
	}
	@Test(arguments: [false, true]) func explicitReadBatchRetainsFullLayoutChecksAndStoredByteHashes(_ corrupt: Bool) async throws {
		try await blockedVerifiedStorage { storage, bytes, worker, gate in
			let state = await storage.state; gate.release()
			try await worker.run { _ in
				if corrupt {
					let file = state.payload.url.appendingPathComponent(try #require(state.record.paths.first { $0.hasSuffix("/a") }))
					let handle = try FileHandle(forWritingTo: file); try handle.write(contentsOf: Data([255])); try handle.close()
					// Coarse/untrusted stamps cannot replace a hash of the stored bytes.
					state.record.stamps = try state.stamps()
				}
				let other = state.payload.url.appendingPathComponent(try #require(state.record.paths.first { $0.hasSuffix("/b") }))
				let probe = PieceReadProbe {
					if !corrupt {
						try FileManager.default.moveItem(at: other, to: other.appendingPathExtension("retired"))
						try Data([1, 2, 3]).write(to: other)
					}
				}
				let results = state.verifiedPieces([0, 1], check: probe.check)
				if corrupt {
					#expect(throws: StorageFailure.invalid("verified payload failed its hash")) { try #require(results[0]).get() }
					#expect(try #require(results[1]).get() == bytes.suffix(bytes.count - 16384) + Data(repeating: 0, count: 32768 - bytes.count))
					#expect(!state.record.contains(0) && state.record.contains(1))
				} else {
					for piece in [0, 1] { #expect(throws: StorageFailure.invalid("payload changed during verification")) { try #require(results[piece]).get() } }
					#expect(!state.record.contains(0) && !state.record.contains(1))
				}
			}
		}
	}
	@Test(arguments: [false, true]) func multiReadWorkerAdmissionChargesEveryReadWithoutPartialReservation(_ cancel: Bool) async throws {
		let worker = StorageWorker(), gate = DiskGate(); gate.arm()
		let active = Task { try await worker.run(units: 5) { cancellation in gate.enter(); try cancellation.check() } }
		try await gate.wait()
		do {
			#expect(worker.pendingCount == 5)
			await #expect(throws: StorageFailure.limit("queued disk commands")) { try await worker.run(units: 4) { _ in } }
			#expect(worker.pendingCount == 5)
			let queued = Task { try await worker.run(units: 3) { _ in } }
			try await waitForCommands(worker, 8)
			if cancel { active.cancel() }; gate.release()
			if cancel { await #expect(throws: CancellationError.self) { try await active.value } }
			else { try await active.value }
			try await queued.value
			#expect(worker.pendingCount == 0)
			for invalid in [0, 9] { await #expect(throws: StorageFailure.limit("disk command units")) { try await worker.run(units: invalid) { _ in } } }
		} catch { gate.release(); _ = try? await active.value; throw error }
	}
	@Test(arguments: ReadCancellation.allCases, [false, true]) fileprivate func queuedVerifiedReadsCancelIndependently(_ cancellation: ReadCancellation, selective: Bool) async throws {
		try await blockedVerifiedStorage(selective: selective) { storage, bytes, worker, gate in
			let first = Task { try await storage.readVerifiedPiece(0) }
			try await waitForCommands(worker, 2)
			let second = Task { try await storage.readVerifiedPiece(2) }
			try await waitForCommands(worker, 3)
			if cancellation != .none { (cancellation == .first ? first : second).cancel() }; gate.release()
			let tail = Data([1, 2, 3]) + Data(repeating: 0, count: try storage.layout.length(of: 2) - 3)
			for (kind, task, expected) in [(ReadCancellation.first, first, Data(bytes.prefix(16384))), (.second, second, tail)] {
				if cancellation == kind { await #expect(throws: CancellationError.self) { try await task.value } }
				else { #expect(try await task.value == expected) }
			}
			#expect(try await storage.readVerifiedPiece(0) == bytes.prefix(16384))
			#expect(try await storage.readVerifiedPiece(2) == tail)
			#expect(try await storage.snapshot().verifiedPieces == [0, 1, 2])
		}
	}
	@Test func queuedVerifiedReadsConsumeIndividualAdmissionSlots() async throws {
		try await blockedVerifiedStorage { storage, _, worker, gate in
			var reads: [Task<Data, Error>] = []
			for index in 0..<7 {
				reads.append(Task { try await storage.readVerifiedPiece(index % 3) })
				try await waitForCommands(worker, index + 2)
			}
			await #expect(throws: StorageFailure.limit("queued disk commands")) { try await storage.readVerifiedPiece(0) }
			gate.release(); for read in reads { _ = try await read.value }
			#expect(worker.pendingCount == 0)
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
