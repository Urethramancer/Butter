import Foundation
import Testing
import ButterTorrentMetadata
import ButterTorrentStorage
@testable import ButterTorrentEngine

extension NativeSessionTests { @Suite struct LaunchVerificationTests {
	@Test(arguments: ["clean", "unclean", "partial", "dirty"]) func restoredPausedTransfersUseTheLaunchQueue(_ scenario: String) async throws {
		try await transferFixture { fixture in
			let source = fixture.root.appendingPathComponent("input.torrent"), library = fixture.root.appendingPathComponent("library")
			try fixture.metadata.document.original.write(to: source)
			let counts = LaunchHashCounts()
			let session = TorrentSession(storage: library, readPolicy: .trustedVerified, configuration: plainTransferConfiguration(), storageEvent: { _, event in counts.record(event) })
			do {
				_ = try await session.add(id: "torrent", source: source, destination: fixture.root.appendingPathComponent("source"))
				try await session.recheck(id: "torrent", files: scenario == "partial" ? [0] : nil)
				_ = try await session.remove(id: "torrent", retainState: true)
				if scenario == "dirty" { try Data(repeating: 255, count: fixture.lengths[0]).write(to: fixture.root.appendingPathComponent("source/bundle/a")) }
				counts.reset()
				try await session.setRestorePolicy(scenario == "unclean" ? .validateAll : .trustCompleted)
				_ = try await session.add(id: "torrent", source: source, destination: fixture.root.appendingPathComponent("source"), restore: true)
				#expect(try await session.shutdownEligibility())
				let row = try #require(await session.snapshot().transfers.first)
				#expect(!row.state.running && row.activity == nil)
				#expect(row.state.storage.verifiedPieces == (scenario == "dirty" ? [1, 2] : [0, 1, 2]))
				#expect(counts.pieces == (scenario == "clean" ? [] : [0, 1, 2]))
				try await session.close()
			} catch { try? await session.close(); throw error }
		}
	}
	@Test(arguments: [false, true]) func fileValidationChecksSharedPiecesWithoutChangingSelectionOrRunningState(running: Bool) async throws {
		try await transferFixture { fixture in
			let counts = LaunchHashCounts()
			let owner = try await ManagedTransfer.open(metadata: fixture.metadata, destination: fixture.root.appendingPathComponent("source"), stateDirectory: fixture.root.appendingPathComponent("state"), readPolicy: .trustedVerified, configuration: plainTransferConfiguration(), event: counts.record)
			do {
				try await owner.recheck(); if running { try await owner.start() }
				counts.reset()
				await #expect(throws: StorageFailure.self) { try await owner.recheck(files: [-1]) }
				let unchanged = try await owner.snapshot()
				#expect(counts.pieces.isEmpty && unchanged.running == running)
				// File a shares piece zero with skip. Damage the neighbouring file.
				try Data(repeating: 255, count: fixture.lengths[1]).write(to: fixture.root.appendingPathComponent("source/bundle/skip"))
				try await owner.recheck(files: [0, 0])
				let row = try await owner.snapshot()
				#expect(row.running == running && !row.storage.verifiedPieces.contains(0))
				#expect(row.storage.selected == [true, true, true, true])
				// Resuming may also begin normal recovery of the neighbouring file.
				if running { #expect(counts.pieces.first == 0) }
				else { #expect(counts.pieces == [0]) }
				try await owner.close()
			} catch { try? await owner.close(); throw error }
		}
	}
} }

private final class LaunchHashCounts: @unchecked Sendable {
	private let lock = NSLock()
	private var values: [Int] = []
	var pieces: [Int] { lock.withLock { values } }
	func reset() { lock.withLock { values = [] } }
	func record(_ event: StorageEvent) { if case .pieceHashed(let piece) = event { lock.withLock { values.append(piece) } } }
}
