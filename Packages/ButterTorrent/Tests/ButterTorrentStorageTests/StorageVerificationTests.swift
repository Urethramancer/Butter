import Foundation
import Testing
import ButterTorrentMetadata
@testable import ButterTorrentStorage

@Suite struct StorageVerificationTests {
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
