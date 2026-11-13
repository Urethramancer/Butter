import Foundation
import Testing
import ButterTorrentMetadata
import ButterTorrentStorage
@testable import ButterTorrentEngine

@Suite struct LazyVerificationTests {
	@Test func pausedReopenDefersChecksAndRunningReopenHasOneOwner() async throws {
		try await transferFixture { fixture in
			let destination = fixture.root.appendingPathComponent("source"), directory = fixture.root.appendingPathComponent("lazy-state")
			let original = try await TorrentStorage.open(metadata: fixture.metadata, destination: destination, stateDirectory: directory)
			for piece in 0..<original.layout.pieceCount { #expect(try await original.verify(piece: piece)) }
			try await original.shutdown()
			let resources = try TransferResources(maximumDiskOperations: 1), counts = LazyHashCounts()
			let managed = try await ManagedTransfer.open(metadata: fixture.metadata, destination: destination, stateDirectory: directory, resources: resources, event: counts.record)
			var held = false
			do {
				let pending = try await managed.snapshot()
				#expect(!pending.running && pending.storage.verifiedPieces.isEmpty && pending.storage.pendingVerificationCount == original.layout.pieceCount)
				#expect(counts.pieces.isEmpty)
				try await resources.disk.acquire()
				held = true
				try await managed.start()
				try await eventually { await resources.snapshot().waitingDiskOperations == 1 }
				#expect(counts.pieces.isEmpty)
				await resources.disk.release(); held = false
				try await eventually { try await managed.snapshot().transfer?.complete == true }
				#expect(counts.pieces.sorted() == Array(0..<original.layout.pieceCount))
				#expect(try await managed.snapshot().storage.pendingVerificationCount == 0)
				try await managed.close()
			} catch { if held { await resources.disk.release() }; try? await managed.close(); throw error }
		}
	}
}

private final class LazyHashCounts: @unchecked Sendable {
	private let lock = NSLock()
	private var values: [Int] = []
	var pieces: [Int] { lock.withLock { values } }
	func record(_ event: StorageEvent) { if case .pieceHashed(let piece) = event { lock.withLock { values.append(piece) } } }
}
