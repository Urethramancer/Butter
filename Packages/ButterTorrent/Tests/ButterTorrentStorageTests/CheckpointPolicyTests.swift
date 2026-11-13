import Foundation
import Testing
import ButterTorrentMetadata
@testable import ButterTorrentStorage

private final class CheckpointClock: StorageCheckpointClock, @unchecked Sendable {
	private let lock = NSLock()
	private var time: TimeInterval = 100
	private var pending: [UUID: (TimeInterval, CheckedContinuation<Void, Error>)] = [:]
	var sleeping: Int { lock.withLock { pending.count } }
	func now() -> TimeInterval { lock.withLock { time } }
	func sleep(for seconds: TimeInterval) async throws {
		let id = UUID()
		try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
				lock.withLock {
					if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
					else { pending[id] = (time + seconds, continuation) }
				}
			}
		} onCancel: { self.lock.withLock { self.pending.removeValue(forKey: id)?.1 }?.resume(throwing: CancellationError()) }
	}
	func advance(_ seconds: TimeInterval) {
		let ready = lock.withLock {
			time += seconds; let ready = pending.filter { $0.value.0 <= time }
			for id in ready.keys { pending[id] = nil }; return ready.values.map(\.1)
		}
		for continuation in ready { continuation.resume() }
	}
}
private func savedCheckpoint(_ root: URL) throws -> StorageCheckpoint {
	try PropertyListDecoder().decode(StorageCheckpoint.self, from: Data(contentsOf: root.appendingPathComponent("state/checkpoint.plist")))
}
private struct FailingCheckpointClock: StorageCheckpointClock {
	func now() -> TimeInterval { 100 }
	func sleep(for seconds: TimeInterval) async throws { throw StorageFailure.invalid("injected checkpoint clock") }
}
private final class CheckpointMutation: @unchecked Sendable {
	private let lock = NSLock()
	private var armed = false
	func arm() { lock.withLock { armed = true } }
	func take() -> Bool { lock.withLock { let value = armed; armed = false; return value } }
}
private func checkpointEventually(_ operation: () async throws -> Bool) async throws {
	let end = ProcessInfo.processInfo.systemUptime + 3
	while ProcessInfo.processInfo.systemUptime < end {
		if try await operation() { return }; try await Task.sleep(for: .milliseconds(5))
	}
	throw StorageFailure.invalid("checkpoint test deadline")
}

@Suite struct CheckpointPolicyTests {
	@Test(arguments: [false, true], [19000, 20000]) func byteThresholdCountsPayloadOnceAndExcludesPadding(sliced: Bool, budget: Int64) async throws {
		try await storageFixture { root in
			let (metadata, bytes) = try storageMetadata(root)
			let state = try StorageState(metadata: metadata, layout: StorageLayout(metadata: metadata), destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"), selected: nil,
				coordinator: StorageCoordinator(), checkpointPolicy: .batched(interval: 1, bytes: budget), event: { _ in }, check: {})
			try state.write(piece: 0, offset: 0, data: bytes.prefix(16384), check: {})
			#expect(try state.verify(piece: 0, check: {}))
			#expect(state.pendingVerifiedBytes == 16384 && state.record.contains(0) && !state.committedContains(0))
			#expect(try state.verify(piece: 0, check: {}))
			#expect(state.pendingVerifiedBytes == 16384); #expect(!(try savedCheckpoint(root).contains(0)))
			let block = bytes.suffix(3616) + Data(repeating: 0, count: 16384 - 3616)
			try state.write(piece: 1, offset: 0, data: sliced ? block : Data(block), check: {})
			#expect(try state.verify(piece: 1, check: {}))
			let saved = try savedCheckpoint(root)
			#expect(saved.contains(0) && saved.contains(1) == (budget == 20000))
			#expect(state.pendingVerifiedBytes == (budget == 20000 ? 0 : 3616))
			try state.save(); #expect(try savedCheckpoint(root).contains(1))
		}
	}
	@Test func idleTimeThresholdAndShutdownDrainTheOwnedTimer() async throws {
		try await storageFixture { root in
			let (metadata, bytes) = try storageMetadata(root), clock = CheckpointClock()
			let storage = try await TorrentStorage.open(metadata: metadata, destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"), checkpointPolicy: .managed, checkpointClock: clock)
			try await storage.write(piece: 0, offset: 0, data: bytes.prefix(16384)); #expect(try await storage.verify(piece: 0))
			#expect(try await storage.snapshot().verifiedPieces == [0]); #expect(!(try savedCheckpoint(root).contains(0)))
			try await checkpointEventually { clock.sleeping == 1 }
			clock.advance(0.9); #expect(!(try savedCheckpoint(root).contains(0)))
			clock.advance(0.1)
			try await checkpointEventually { try savedCheckpoint(root).contains(0) }
			try await storage.shutdown()
			#expect(clock.sleeping == 0); #expect(await storage.checkpointTimer == nil)
		}
	}
	@Test func byteBarrierPreservesTheNextEpochTimeDeadline() async throws {
		try await storageFixture { root in
			let (metadata, bytes) = try storageMetadata(root), clock = CheckpointClock()
			let storage = try await TorrentStorage.open(metadata: metadata, destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"), checkpointPolicy: .batched(interval: 1, bytes: 20000), checkpointClock: clock)
			try await storage.write(piece: 0, offset: 0, data: bytes.prefix(16384)); #expect(try await storage.verify(piece: 0))
			try await checkpointEventually { clock.sleeping == 1 }; clock.advance(0.5)
			try await storage.write(piece: 1, offset: 0, data: bytes.suffix(3616) + Data(repeating: 0, count: 12768)); #expect(try await storage.verify(piece: 1))
			try await storage.write(piece: 2, offset: 0, data: Data([1, 2, 3]) + Data(repeating: 0, count: 16381)); #expect(try await storage.verify(piece: 2))
			clock.advance(0.5); #expect(!(try savedCheckpoint(root).contains(2)))
			try await checkpointEventually { clock.sleeping == 1 }; clock.advance(0.5)
			try await checkpointEventually { try savedCheckpoint(root).contains(2) }
			try await storage.shutdown()
		}
	}
	@Test func shutdownDrainsAnExpiredTimerQueuedBehindBlockedDiskWork() async throws {
		try await storageFixture { root in
			let (metadata, bytes) = try storageMetadata(root), clock = CheckpointClock()
			let storage = try await TorrentStorage.open(metadata: metadata, destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"), checkpointPolicy: .managed, checkpointClock: clock)
			try await storage.write(piece: 0, offset: 0, data: bytes.prefix(16384)); #expect(try await storage.verify(piece: 0))
			try await checkpointEventually { clock.sleeping == 1 }
			let worker = await storage.worker, entered = AsyncStream<Void>.makeStream(), release = DispatchSemaphore(value: 0)
			let blocker = Task { try await worker.run { _ in entered.continuation.yield(()); _ = release.wait(timeout: .now() + 3) } }
			defer { release.signal() }
			try await withThrowingTaskGroup(of: Void.self) { group in
				group.addTask { for await _ in entered.stream { return }; throw StorageFailure.invalid("checkpoint test signal") }
				group.addTask { try await Task.sleep(for: .seconds(3)); throw StorageFailure.invalid("checkpoint test signal deadline") }
				defer { group.cancelAll() }; try await group.next()
			}
			clock.advance(1); #expect(!(try savedCheckpoint(root).contains(0)))
			let shutdown = Task { try await storage.shutdown() }
			try await checkpointEventually { await storage.closing }
			release.signal(); try await blocker.value; try await shutdown.value
			#expect(try savedCheckpoint(root).contains(0)); #expect(clock.sleeping == 0)
			#expect(await storage.checkpointTimer == nil)
		}
	}
	@Test(arguments: ["flush", "save", "export", "rename", "move", "select", "shutdown"])
	func forcedBarriersPublishPendingVerification(_ operation: String) async throws {
		try await storageFixture { root in
			let (metadata, bytes) = try storageMetadata(root), clock = CheckpointClock()
			let storage = try await TorrentStorage.open(metadata: metadata, destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"), checkpointPolicy: .managed, checkpointClock: clock)
			try await storage.write(piece: 0, offset: 0, data: bytes.prefix(16384)); #expect(try await storage.verify(piece: 0))
			switch operation {
			case "flush": try await storage.flush()
			case "save": try await storage.checkpoint(downloaded: 16384, uploaded: 0)
			case "export": _ = try await storage.exportMetadata()
			case "rename": try await storage.rename([0: "renamed/a"])
			case "move": try await storage.move(to: root.appendingPathComponent("moved"))
			case "select": try await storage.select(metadata.inspection.files.map { !$0.pad })
			default: try await storage.shutdown()
			}
			#expect(try savedCheckpoint(root).contains(0))
			try await storage.shutdown(); #expect(clock.sleeping == 0)
		}
	}
	@Test func failedPublicationRetainsPendingAndCommittedProgressSeparately() async throws {
		try await storageFixture { root in
			let (metadata, bytes) = try storageMetadata(root)
			let state = try StorageState(metadata: metadata, layout: StorageLayout(metadata: metadata), destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"), selected: nil,
				coordinator: StorageCoordinator(), checkpointPolicy: .batched(interval: 1, bytes: 16384), event: { _ in }, check: {})
			let checkpoint = root.appendingPathComponent("state/checkpoint.plist"), backup = root.appendingPathComponent("backup")
			try FileManager.default.moveItem(at: checkpoint, to: backup); try FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: false)
			try state.write(piece: 0, offset: 0, data: bytes.prefix(16384), check: {})
			#expect(throws: (any Error).self) { try state.verify(piece: 0, check: {}) }
			#expect(state.record.contains(0) && !state.committedContains(0) && state.pendingVerifiedBytes == 16384 && state.pendingFlush == [0])
			#expect(throws: (any Error).self) { try state.snapshot() }
			try FileManager.default.removeItem(at: checkpoint); try FileManager.default.moveItem(at: backup, to: checkpoint)
			try state.save()
			#expect(state.committedContains(0) && state.pendingVerifiedBytes == 0 && state.checkpointError == nil)
			#expect(try savedCheckpoint(root).contains(0))
		}
	}
	@Test func timerPublicationFailureIsReportedAndExplicitFlushCanRetry() async throws {
		try await storageFixture { root in
			let (metadata, bytes) = try storageMetadata(root), clock = CheckpointClock()
			let storage = try await TorrentStorage.open(metadata: metadata, destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"), checkpointPolicy: .managed, checkpointClock: clock)
			try await storage.write(piece: 0, offset: 0, data: bytes.prefix(16384)); #expect(try await storage.verify(piece: 0))
			let checkpoint = root.appendingPathComponent("state/checkpoint.plist"), backup = root.appendingPathComponent("backup")
			try FileManager.default.moveItem(at: checkpoint, to: backup); try FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: false)
			try await checkpointEventually { clock.sleeping == 1 }; clock.advance(1)
			let state = await storage.state
			try await checkpointEventually { state.checkpointFailures.error != nil }
			await #expect(throws: (any Error).self) { try await storage.snapshot() }
			try FileManager.default.removeItem(at: checkpoint); try FileManager.default.moveItem(at: backup, to: checkpoint)
			try await storage.flush(); #expect(try savedCheckpoint(root).contains(0)); try await storage.shutdown()
		}
	}
	@Test func clockFailureCannotSilentlyAbandonPendingVerification() async throws {
		try await storageFixture { root in
			let (metadata, bytes) = try storageMetadata(root)
			let storage = try await TorrentStorage.open(metadata: metadata, destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"), checkpointPolicy: .managed, checkpointClock: FailingCheckpointClock())
			try await storage.write(piece: 0, offset: 0, data: bytes.prefix(16384)); #expect(try await storage.verify(piece: 0))
			let state = await storage.state
			try await checkpointEventually { state.checkpointFailures.error != nil }
			await #expect(throws: StorageFailure.invalid("injected checkpoint clock")) { try await storage.snapshot() }
			#expect(!(try savedCheckpoint(root).contains(0)))
			try await storage.flush(); #expect(try savedCheckpoint(root).contains(0)); try await storage.shutdown()
		}
	}
	@Test func legacyHybridRecoveryChecksStoredBytesButDoesNotTrustMissingV2Hashes() async throws {
		try await storageFixture { root in
			let (fullMetadata, bytes) = try storageMetadata(root)
			var document = fullMetadata.document.root.dictionary!; document[Data("piece layers".utf8)] = nil
			let metadata = try TorrentMetadata(BencodeValue.dictionary(document).encoded())
			let state = try StorageState(metadata: metadata, layout: StorageLayout(metadata: metadata), destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"), selected: nil, coordinator: StorageCoordinator(), checkpointPolicy: .managed, event: { _ in }, check: {})
			try state.write(piece: 0, offset: 0, data: bytes.prefix(16384), check: {})
			var checks = 0
			#expect(throws: CancellationError.self) { try state.recoverExistingPiece(0, check: { checks += 1; if checks == 3 { throw CancellationError() } }) }
			#expect(state.recoveryChecked[0] & 128 == 0)
			#expect(try state.recoverExistingPiece(0, check: {}) == false)
			#expect(!state.record.contains(0) && state.recoveryChecked[0] & 128 != 0)
		}
	}
	@Test func failedDurableInvalidationCannotOverwriteCommittedBytes() async throws {
		try await storageFixture { root in
			let (metadata, bytes) = try storageMetadata(root)
			let storage = try await TorrentStorage.open(metadata: metadata, destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"), checkpointPolicy: .managed)
			try await storage.write(piece: 0, offset: 0, data: bytes.prefix(16384)); #expect(try await storage.verify(piece: 0)); try await storage.flush()
			let checkpoint = root.appendingPathComponent("state/checkpoint.plist"), backup = root.appendingPathComponent("backup")
			try FileManager.default.moveItem(at: checkpoint, to: backup); try FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: false)
			await #expect(throws: (any Error).self) { try await storage.write(piece: 0, offset: 0, data: Data([255])) }
			#expect(try Data(contentsOf: root.appendingPathComponent("data/source/a")) == bytes.prefix(16384))
			try FileManager.default.removeItem(at: checkpoint); try FileManager.default.moveItem(at: backup, to: checkpoint)
			try await storage.flush(); try await storage.write(piece: 0, offset: 0, data: Data([255]))
			#expect(!(try savedCheckpoint(root).contains(0)))
			try await storage.shutdown()
		}
	}
	@Test(arguments: [false, true]) func failedInvalidationCannotRestoreExternallyChangedVerification(batched: Bool) async throws {
		try await storageFixture { root in
			let (metadata, bytes) = try storageMetadata(root), mutation = CheckpointMutation()
			let fileA = root.appendingPathComponent("data/source/a"), fileB = metadata.inspection.files.first { $0.path.hasSuffix("/b") }!.index
			let state = try StorageState(metadata: metadata, layout: StorageLayout(metadata: metadata), destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"), selected: nil,
				coordinator: StorageCoordinator(), checkpointPolicy: batched ? .managed : .immediate, event: { event in
					if event == .payloadFlushed(fileB), mutation.take(), let handle = try? FileHandle(forWritingTo: fileA) {
						try? handle.write(contentsOf: Data([255])); try? handle.close()
					}
				}, check: {})
			try state.write(piece: 0, offset: 0, data: bytes.prefix(16384), check: {})
			#expect(try state.verify(piece: 0, check: {})); try state.save()
			try state.write(piece: 2, offset: 0, data: Data([1, 2, 3]) + Data(repeating: 0, count: 16381), check: {})
			let checkpoint = root.appendingPathComponent("state/checkpoint.plist"), backup = root.appendingPathComponent("backup")
			try FileManager.default.moveItem(at: checkpoint, to: backup); try FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: false)
			mutation.arm()
			#expect(throws: (any Error).self) { try state.write(piece: 0, offset: 1, data: Data([23]), check: {}) }
			#expect(!state.record.contains(0) && state.committedContains(0))
			let changed = try Data(contentsOf: fileA); #expect(changed[0] == 255 && changed[1] == bytes[1])
			try FileManager.default.removeItem(at: checkpoint); try FileManager.default.moveItem(at: backup, to: checkpoint)
			try state.save(); #expect(!(try savedCheckpoint(root).contains(0)))
		}
	}
	@Test func recoveryChecksExistingBytesOnlyOnceAndKeepsCorruptOrShortData() async throws {
		try await storageFixture { root in
			let (metadata, bytes) = try storageMetadata(root)
			let storage = try await TorrentStorage.open(metadata: metadata, destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"), checkpointPolicy: .managed)
			try await storage.write(piece: 0, offset: 0, data: bytes.prefix(16384))
			#expect(try await storage.recoverExistingPiece(0)); #expect(try await storage.snapshot().verifiedPieces == [0])
			#expect(try await storage.recoverExistingPiece(0))
			try await storage.write(piece: 1, offset: 0, data: Data([255]))
			#expect(try await storage.recoverExistingPiece(1) == false)
			try await storage.write(piece: 1, offset: 0, data: bytes.suffix(3616) + Data(repeating: 0, count: 16384 - 3616))
			#expect(try await storage.recoverExistingPiece(1)) // New writes reset the attempted generation.
			#expect(try await storage.verify(piece: 1))
			try await storage.shutdown()
		}
	}
}
