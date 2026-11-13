import Foundation
import Testing
import ButterTorrentMetadata
import ButterTorrentStorage
@testable import ButterTorrentEngine

@Suite struct LazyVerificationTests {
	@Test func passingPiecesAreAdvertisedBeforeTheNextCheckCompletes() async throws {
		try await transferFixture { fixture in
			let entered = AsyncStream<Void>.makeStream(), release = DispatchSemaphore(value: 0)
			defer { release.signal() }
			let storage = try await TorrentStorage.open(metadata: fixture.metadata, destination: fixture.root.appendingPathComponent("source"), stateDirectory: fixture.root.appendingPathComponent("progressive-state"), checkpointPolicy: .managed, event: { event in
				if event == .pieceHashed(1) { entered.continuation.yield(()); _ = release.wait(timeout: .now() + 6) }
			})
			fixture.stores.append(storage)
			let transfer = try await TCPTransfer.open(metadata: fixture.metadata, storage: storage, configuration: plainTransferConfiguration())
			fixture.engines.append(transfer)
			try await engineDeadline { for await _ in entered.stream { return }; throw PeerFailure.closed }
			let partial = await transfer.snapshot()
			#expect(partial.verifiedPieces == [0] && !partial.complete)
			let peer = try await fixture.scripted(transfer); defer { peer.stream.close() }
			while true {
				if case .bitfield(let bytes) = try await peer.next() { #expect(bytes[0] == 128); break }
			}
			release.signal()
			try await engineDeadline { try await transfer.waitUntilComplete() }
			#expect(await transfer.snapshot().downloaded == 0)
		}
	}
	@Test(arguments: [false, true]) func incrementalExternalCopiesWaitForStabilityAndRespectPause(pause: Bool) async throws {
		try await transferFixture { fixture in
			let clock = EngineClock(), destination = fixture.root.appendingPathComponent("external")
			let managed = try await ManagedTransfer.open(metadata: fixture.metadata, destination: destination, stateDirectory: fixture.root.appendingPathComponent("external-state"), clock: clock)
			do {
				try await managed.start()
				try FileManager.default.createDirectory(at: destination.appendingPathComponent("bundle"), withIntermediateDirectories: true)
				try fixture.bytes.prefix(3).write(to: destination.appendingPathComponent("bundle/a"))
				let first = try await managed.snapshot()
				#expect(first.running && first.transfer == nil && first.storage.verifiedPieces.isEmpty)
				try await eventually { clock.sleepingCount == 1 }
				clock.advance(0.5)
				for name in fixture.names {
					let bytes = try Data(contentsOf: fixture.root.appendingPathComponent("source/bundle/" + name))
					try bytes.write(to: destination.appendingPathComponent("bundle/" + name))
				}
				_ = try await managed.snapshot()
				clock.advance(0.5)
				try await eventually { clock.sleepingCount == 1 }
				#expect(try await managed.snapshot().storage.verifiedPieces.isEmpty)
				if pause {
					try await managed.pause(); clock.advance(1)
					let snapshot = try await managed.snapshot()
					#expect(!snapshot.running && snapshot.storage.verifiedPieces.isEmpty && snapshot.storage.pendingVerificationCount > 0)
					try await managed.start()
				} else { clock.advance(1) }
				try await eventually { try await managed.snapshot().transfer?.complete == true }
				#expect(try await managed.snapshot().storage.verifiedPieces == [0, 1, 2])
				try await managed.close()
			} catch { try? await managed.close(); throw error }
		}
	}
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
