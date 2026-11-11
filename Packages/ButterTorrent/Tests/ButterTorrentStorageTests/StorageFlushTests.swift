import Foundation
import Testing
import ButterTorrentMetadata
@testable import ButterTorrentStorage

private final class FlushRecorder: @unchecked Sendable {
	private let lock = NSLock()
	private var indices: [Int] = []
	func record(_ event: StorageEvent) { if case .payloadFlushed(let index) = event { lock.withLock { indices.append(index) } } }
	func take() -> [Int] { lock.withLock { let result = indices; indices.removeAll(); return result } }
}

@Suite struct StorageFlushTests {
	@Test(arguments: [false, true]) func flushesOnlyWrittenOrNewlyTrustedFiles(spilled: Bool) async throws {
		try await storageFixture { root in
			let (metadata, bytes) = try storageMetadata(root), events = FlushRecorder()
			let state = try StorageState(metadata: metadata, layout: StorageLayout(metadata: metadata), destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"), selected: metadata.inspection.files.map { !$0.pad && !spilled }, coordinator: StorageCoordinator(), event: events.record, check: {})
			#expect(events.take().isEmpty)
			try state.write(piece: 0, offset: 0, data: bytes.prefix(16384), check: {})
			#expect(try state.verify(piece: 0, check: {}))
			#expect(events.take() == [0] && state.pendingFlush.isEmpty)
			try state.save(); #expect(events.take().isEmpty)
			// Trust externally supplied bytes without an engine write or import.
			let b = metadata.inspection.files.first { $0.path.hasSuffix("/b") }!.index
			let (directory, path) = state.location(b)
			try directory.atomic(Data([1, 2, 3]), path: path)
			#expect(try state.verify(piece: 2, check: {}))
			#expect(events.take() == [b])
			try state.save(); #expect(events.take().isEmpty)
		}
	}
	@Test func failedCheckpointRetainsPendingFlushAndDoesNotPublishVerifiedProgress() async throws {
		try await storageFixture { root in
			let (metadata, bytes) = try storageMetadata(root), events = FlushRecorder()
			let state = try StorageState(metadata: metadata, layout: StorageLayout(metadata: metadata), destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"), selected: nil, coordinator: StorageCoordinator(), event: events.record, check: {})
			try state.write(piece: 0, offset: 0, data: bytes.prefix(16384), check: {})
			let checkpoint = state.state.url.appendingPathComponent("checkpoint.plist"), backup = root.appendingPathComponent("original-checkpoint")
			try FileManager.default.moveItem(at: checkpoint, to: backup)
			try FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: false)
			#expect(throws: (any Error).self) { try state.verify(piece: 0, check: {}) }
			#expect(!state.record.contains(0) && state.pendingFlush == [0] && events.take() == [0])
			try FileManager.default.removeItem(at: checkpoint)
			try FileManager.default.moveItem(at: backup, to: checkpoint)
			try state.save()
			#expect(state.pendingFlush.isEmpty && events.take() == [0])
			let saved = try PropertyListDecoder().decode(StorageCheckpoint.self, from: Data(contentsOf: checkpoint))
			#expect(!saved.contains(0))
		}
	}
	@Test func cancellationBeforeWriteRetainsNewFileForFlushing() async throws {
		try await storageFixture { root in
			let (metadata, bytes) = try storageMetadata(root), events = FlushRecorder()
			let state = try StorageState(metadata: metadata, layout: StorageLayout(metadata: metadata), destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"), selected: nil, coordinator: StorageCoordinator(), event: events.record, check: {})
			var checks = 0
			#expect(throws: CancellationError.self) {
				try state.write(piece: 0, offset: 0, data: bytes.prefix(16384), check: { checks += 1; if checks == 2 { throw CancellationError() } })
			}
			#expect(state.pendingFlush == [0] && !state.record.contains(0))
			try state.save(); #expect(events.take() == [0] && state.pendingFlush.isEmpty)
		}
	}
}
