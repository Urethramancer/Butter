import Foundation
import Testing
import ButterTorrentMetadata
import ButterTorrentNetworking
import ButterTorrentStorage
@testable import ButterTorrentEngine

@Suite struct ManagedTransferTests {
	@Test func repairDrainsCachedUploadsAndRestoresRunningState() async throws {
		try await withManagedSeed { fixture, seed, resources in
			let source = fixture.root.appendingPathComponent("repair-copy")
			try fixture.bytes.prefix(10003).write(to: source)
			try await seed.setLimits(download: 0, upload: 1); try await seed.start()
			let listener = try await fixture.listen(), connecting = Task { try await seed.connect(to: NetworkEndpoint("127.0.0.1", port: listener.port)) }
			let peer = WirePeer(stream: try await listener.accept(timeout: 3)); _ = try await connecting.value
			defer { peer.stream.close() }
			try await peer.hello(hash: fixture.metadata.hashes.v1!, identity: 42)
			try await peer.send(.interested); try await peer.send(.request(PeerBlock(piece: 0, offset: 0, length: 16384)))
			try await eventually { await resources.snapshot().cachedBytes > 0 }
			try Data(repeating: 255, count: 10003).write(to: fixture.root.appendingPathComponent("source/bundle/a"))
			let repaired = try await engineDeadline { try await seed.repairFile(0, from: source) }
			#expect(repaired.repairedFiles == 1 && repaired.verifiedPieces == 1 && repaired.pendingPieces == 0)
			let snapshot = try await seed.snapshot()
			#expect(snapshot.running && snapshot.transfer?.complete == true && snapshot.transfer?.peers.isEmpty == true)
			#expect(await resources.snapshot().cachedBytes == 0)
			#expect(try Data(contentsOf: source) == fixture.bytes.prefix(10003))
		}
	}
	@Test func changedFilesRetireVerifiedAdvertisementsBeforeResuming() async throws {
		try await withManagedSeed { fixture, seed, _ in
			try await seed.start(); #expect(try await seed.snapshot().transfer?.complete == true)
			try Data(repeating: 255, count: fixture.lengths[0]).write(to: fixture.root.appendingPathComponent("source/bundle/a"))
			let snapshot = try await seed.snapshot()
			#expect(snapshot.running && snapshot.transfer == nil)
			#expect(!snapshot.storage.verifiedPieces.contains(0) && snapshot.storage.pendingVerificationCount > 0)
		}
	}
	@Test func pauseCancelsAnUnansweredOutgoingNegotiation() async throws {
		var config = plainTransferConfiguration(); config.encryption.outgoing = .required
		try await withManagedSeed(configuration: config) { fixture, seed, _ in
			try await seed.start()
			let listener = try await fixture.listen()
			let opening = Task { try await seed.connect(to: NetworkEndpoint("127.0.0.1", port: listener.port)) }
			let raw = try await listener.accept(timeout: 3); defer { raw.close() }
			#expect(!(try await raw.read()).isEmpty)
			try await engineDeadline { try await seed.pause() }
			await #expect(throws: CancellationError.self) { try await opening.value }
			let snapshot = try await seed.snapshot(); #expect(!snapshot.running && snapshot.transfer == nil)
		}
	}
	@Test func renameDrainsARateLimitedUploadAndResumesVerifiedSeeding() async throws {
		try await withManagedSeed { fixture, seed, resources in
			try await seed.setLimits(download: 0, upload: 1); try await seed.start()
			let listener = try await fixture.listen()
			let connecting = Task { try await seed.connect(to: NetworkEndpoint("127.0.0.1", port: listener.port)) }
			let peer = WirePeer(stream: try await listener.accept(timeout: 3)); _ = try await connecting.value
			try await peer.hello(hash: fixture.metadata.hashes.v1!, identity: 42)
			try await peer.send(.interested); try await peer.send(.request(PeerBlock(piece: 0, offset: 0, length: 16384)))
			try await eventually { await resources.snapshot().cachedBytes > 0 }
			try await engineDeadline { try await seed.changeStorage(.rename([0: "bundle/renamed/a"])) }
			let moved = try await seed.snapshot()
			#expect(moved.running && moved.transfer?.peers.isEmpty == true)
			#expect(moved.storage.paths[0] == "bundle/renamed/a" && moved.storage.verifiedPieces.count == 3)
			#expect(await resources.snapshot().diskOperations == 0)
			#expect(try Data(contentsOf: fixture.root.appendingPathComponent("source/bundle/renamed/a")) == fixture.bytes.prefix(10003))
			try await seed.setLimits(download: 0, upload: 0)
			let down = try await fixture.transfer("download"), serving = try await fixture.listen()
			let incoming = Task { try await seed.attach(serving.accept(timeout: 3)) }
			_ = try await down.connect(to: NetworkEndpoint("127.0.0.1", port: serving.port)); _ = try await incoming.value
			try await eventually { await down.snapshot().complete }
			var bytes = Data()
			for name in fixture.names { bytes.append(try Data(contentsOf: fixture.root.appendingPathComponent("download/bundle/" + name))) }
			#expect(bytes == fixture.bytes)
		}
	}
	@Test func overlappingExportsAndStorageCommandsRetainIdentityAndSelection() async throws {
		try await withManagedSeed { fixture, seed, _ in
			try await seed.start()
			let originalInfo = fixture.metadata.originalInfo, destination = fixture.root.appendingPathComponent("moved")
			try await withThrowingTaskGroup(of: Void.self) { group in
				for _ in 0..<16 {
					group.addTask { let data = try await seed.exportMetadata(); #expect(try TorrentMetadata(data).originalInfo == originalInfo) }
				}
				group.addTask { try await seed.changeStorage(.rename([0: "bundle/renamed"])) }
				group.addTask { try await seed.changeStorage(.move(destination)) }
				group.addTask { try await seed.changeStorage(.select([true, false, true, true])) }
				try await group.waitForAll()
			}
			let snapshot = try await seed.snapshot()
			#expect(snapshot.running && snapshot.storage.paths[0] == "bundle/renamed")
			#expect(snapshot.storage.destination == fixture.root.appendingPathComponent("moved"))
			#expect(snapshot.storage.selected == [true, false, true, true] && snapshot.transfer?.complete == true)
		}
	}
	@Test func failedCheckpointPreventsMutationAndPauseCanBeRetried() async throws {
		try await withManagedSeed { fixture, seed, _ in
			try await seed.start()
			let checkpoint = fixture.root.appendingPathComponent("managed-state/checkpoint.plist"), backup = fixture.root.appendingPathComponent("checkpoint-backup")
			try FileManager.default.moveItem(at: checkpoint, to: backup)
			try FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: false)
			await #expect(throws: (any Error).self) { try await seed.changeStorage(.rename([0: "bundle/renamed"])) }
			#expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("source/bundle/a").path))
			#expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("source/bundle/renamed").path))
			await #expect(throws: StorageFailure.self) { try await seed.start() }
			try FileManager.default.removeItem(at: checkpoint); try FileManager.default.moveItem(at: backup, to: checkpoint)
			try await seed.pause(); try await seed.start()
			#expect(try await seed.snapshot().running)
			await #expect(throws: StorageFailure.self) { try await seed.changeStorage(.rename([0: "bundle/c"])) }
			#expect(try await seed.snapshot().running)
		}
	}
	private func withManagedSeed(configuration: TCPTransferConfiguration = plainTransferConfiguration(), _ body: (TransferFixture, ManagedTransfer, TransferResources) async throws -> Void) async throws {
		let fixture = try TransferFixture(), resources = try TransferResources(maximumDiskOperations: 2)
		let seed = try await ManagedTransfer.open(metadata: fixture.metadata, destination: fixture.root.appendingPathComponent("source"),
			stateDirectory: fixture.root.appendingPathComponent("managed-state"), configuration: configuration, resources: resources)
		do { try await seed.recheck(); try await body(fixture, seed, resources); try await seed.close() }
		catch { try? await seed.close(); await fixture.clean(); throw error }
		await fixture.clean()
	}
}
