import Foundation
import Testing
import ButterTorrentMetadata
@testable import ButterTorrentStorage

@Suite struct StorageVerificationTests {
	@Test func deferredOpeningDoesNotTrustHistoricalClaimsAndChecksCoalesce() async throws {
		try await storageFixture { root in
			let (metadata, bytes) = try storageMetadata(root), destination = root.appendingPathComponent("data"), directory = root.appendingPathComponent("state")
			let original = try await TorrentStorage.open(metadata: metadata, destination: destination, stateDirectory: directory)
			try await original.write(piece: 0, offset: 0, data: bytes.prefix(16384)); #expect(try await original.verify(piece: 0)); try await original.shutdown()
			let counts = PieceHashCounts()
			let deferred = try await TorrentStorage.open(metadata: metadata, destination: destination, stateDirectory: directory, verificationPolicy: .deferred, event: counts.record)
			let snapshot = try await deferred.snapshot()
			#expect(snapshot.verifiedPieces.isEmpty && snapshot.pendingVerificationCount > 0 && counts.pieces.isEmpty)
			async let a = deferred.recoverExistingPiece(0)
			async let b = deferred.recoverExistingPiece(0)
			let results = try await (a, b); #expect(results.0 && results.1)
			#expect(counts.pieces == [0]); #expect(try await deferred.snapshot().verifiedPieces == [0])
			try await deferred.shutdown()
			let eager = try await TorrentStorage.open(metadata: metadata, destination: destination, stateDirectory: directory)
			#expect(try await eager.snapshot().verifiedPieces == [0]); try await eager.shutdown()
		}
	}
	@Test(arguments: [false, true]) func changedFilesResetMissingAndCorruptRecoveryAttempts(corrupt: Bool) async throws {
		try await storageFixture { root in
			let (metadata, bytes) = try storageMetadata(root), counts = PieceHashCounts()
			let storage = try await TorrentStorage.open(metadata: metadata, destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"), checkpointPolicy: .managed, event: counts.record)
			if corrupt { try await storage.write(piece: 0, offset: 0, data: Data(repeating: 255, count: 16384)) }
			#expect(try await storage.recoverExistingPiece(0) == false)
			#expect(try await storage.recoverExistingPiece(0) == false)
			let old = try await storage.snapshot().integrityGeneration
			try FileManager.default.createDirectory(at: root.appendingPathComponent("data/source"), withIntermediateDirectories: true)
			try bytes.write(to: root.appendingPathComponent("data/source/a"))
			#expect(try await storage.snapshot().integrityGeneration > old)
			#expect(try await storage.recoverExistingPiece(0))
			#expect(counts.pieces.filter { $0 == 0 }.count == (corrupt ? 2 : 1))
			try await storage.shutdown()
		}
	}
	@Test(arguments: [false, true]) func verificationObservesOnlyItsDependencies(changeDependency: Bool) async throws {
		try await storageFixture { root in
			let (metadata, bytes) = try storageMetadata(root)
			let state = try StorageState(metadata: metadata, layout: StorageLayout(metadata: metadata), destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"), selected: nil, coordinator: StorageCoordinator(), checkpointPolicy: .managed, event: { _ in }, check: {})
			try state.write(piece: 0, offset: 0, data: bytes.prefix(16384), check: {})
			try state.write(piece: 2, offset: 0, data: Data([1, 2, 3]) + Data(repeating: 0, count: 16381), check: {})
			#expect(try state.verify(piece: 0, check: {}))
			var changed = false
			let mutate = {
				if !changed {
					changed = true
					try Data([255]).write(to: root.appendingPathComponent(changeDependency ? "data/source/b" : "data/source/a"))
				}
			}
			if changeDependency { #expect(throws: StorageFailure.self) { try state.verify(piece: 2, check: mutate) } }
			else {
				#expect(try state.verify(piece: 2, check: mutate))
				#expect(state.record.contains(0))
				#expect(try state.snapshot().verifiedPieces == [2])
			}
		}
	}
}

private final class PieceHashCounts: @unchecked Sendable {
	private let lock = NSLock()
	private var values: [Int] = []
	var pieces: [Int] { lock.withLock { values } }
	func record(_ event: StorageEvent) { if case .pieceHashed(let piece) = event { lock.withLock { values.append(piece) } } }
}
