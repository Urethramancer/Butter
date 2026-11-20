import Foundation
import Testing
import ButterTorrentNetworking
@testable import ButterTorrentStorage
@testable import ButterTorrentEngine

@Suite struct TCPTransferTests {
	@Test func saturatedRequestsWaitBeforeRescueAndStillCancelLateDuplicates() async throws {
		let fixture = try TransferFixture(lengths: [16 * 65536, 0, 0, 0], pieceLength: 65536), clock = EngineClock()
		do {
			let engine = try await fixture.transfer("download", clock: clock)
			let owner = try await fixture.scripted(engine, identity: 11), rescuer = try await fixture.scripted(engine, identity: 12)
			try await owner.seed(pieceCount: 16); let requests = try await owner.requests(32)
			try await rescuer.seed(pieceCount: 16)
			try await eventually { await engine.snapshot().peers.contains { $0.peerID == Data(repeating: 12, count: 20) && !$0.remoteChoking } }
			#expect(await engine.snapshot().peers.first { $0.peerID == Data(repeating: 12, count: 20) }?.pendingRequests == 0)
			clock.advance(1); await engine.tick()
			#expect(try await rescuer.requests(32) == requests)
			try await rescuer.reply(requests[0], bytes: fixture.bytes, pieceLength: 65536)
			var cancelled: PeerBlock?
			while cancelled == nil { if case .cancel(let block) = try await owner.next() { cancelled = block } }
			#expect(cancelled == requests[0])
			try await owner.reply(requests[0], bytes: fixture.bytes, pieceLength: 65536)
			try await eventually { await engine.snapshot().redundantBytes == 16384 }
			owner.stream.close()
			for block in requests.dropFirst() { try await rescuer.reply(block, bytes: fixture.bytes, pieceLength: 65536) }
			let remaining = try await rescuer.requests(32)
			#expect(remaining.allSatisfy { $0.piece >= 8 })
			for block in remaining { try await rescuer.reply(block, bytes: fixture.bytes, pieceLength: 65536) }
			try await eventually { await engine.snapshot().complete }
			let snapshot = await engine.snapshot()
			#expect(snapshot.corruptPieces == 0 && snapshot.redundantBytes == 16384)
			#expect(snapshot.downloaded == Int64(fixture.bytes.count + 16384))
		} catch { await fixture.clean(); throw error }; await fixture.clean()
	}
	@Test func crossedTCPConnectionsSurviveTheSingleAddressPolicy() async throws {
		try await transferFixture { fixture in
			var configuration = plainTransferConfiguration(); configuration.allowSameIP = false
			let seed = try await fixture.transfer("seed", seed: true, configuration: configuration)
			let down = try await fixture.transfer("download", configuration: configuration)
			let left = try await fixture.listen(), right = try await fixture.listen()
			let downChannel = try await PeerStream.connect(to: NetworkEndpoint("127.0.0.1", port: left.port), hash: fixture.metadata.hashes.v1!, configuration: .disabled)
			let seedChannel = try await PeerStream.connect(to: NetworkEndpoint("127.0.0.1", port: right.port), hash: fixture.metadata.hashes.v1!, configuration: .disabled)
			// Both incoming sockets exist before either outgoing wire hello is sent.
			_ = try await seed.attach(left.accept(timeout: 3)); _ = try await down.attach(right.accept(timeout: 3))
			_ = try await down.attach(downChannel.raw, outgoing: true, transport: downChannel)
			_ = try await seed.attach(seedChannel.raw, outgoing: true, transport: seedChannel)
			try await eventually {
				let a = await seed.snapshot(), b = await down.snapshot()
				return b.complete && a.peers.count == 1 && b.peers.count == 1 && a.peers[0].peerID != nil && b.peers[0].peerID != nil
			}
			let thirdListener = try await fixture.listen()
			let connecting = Task { try await down.connect(to: NetworkEndpoint("127.0.0.1", port: thirdListener.port)) }
			let third = try await thirdListener.accept(timeout: 3); defer { third.close() }
			_ = try await connecting.value
			try await third.write(PeerHandshake(infoHash: fixture.metadata.hashes.v1!, peerID: Data(repeating: 77, count: 20)).encoded)
			try await eventually { await down.snapshot().peers.count == 1 }
			#expect(await down.snapshot().lastPeerError?.contains("connections from the same IP") == true)
		}
	}
	@Test func disconnectingPeersDrainsRequestsAndUnfinishedConnectionsWithoutStoppingStorage() async throws {
		try await transferFixture { fixture in
			var configuration = plainTransferConfiguration(); configuration.encryption.outgoing = .required
			let engine = try await fixture.transfer("download", configuration: configuration), listener = try await fixture.listen()
			let remote = try await TCPStream.connect(to: NetworkEndpoint("127.0.0.1", port: listener.port))
			_ = try await engine.attach(listener.accept(timeout: 3)); let old = WirePeer(stream: remote)
			try await old.hello(hash: fixture.metadata.hashes.v1!, identity: 11)
			try await old.seed(pieceCount: 3); _ = try await old.requests(6)
			let unanswered = try await fixture.listen()
			let connecting = Task { try await engine.connect(to: NetworkEndpoint("127.0.0.1", port: unanswered.port)) }
			let pending = try await unanswered.accept(timeout: 3); defer { pending.close(); old.stream.close(); connecting.cancel() }
			await engine.disconnectPeers()
			await #expect(throws: (any Error).self) { try await connecting.value }
			#expect(await engine.snapshot().peers.isEmpty)
			#expect(await engine.snapshot().stopped == false)
			let replacement = try await fixture.scripted(engine, identity: 12, encryption: .init(incoming: .required))
			try await replacement.seed(pieceCount: 3)
			for block in try await replacement.requests(6) { try await replacement.reply(block, bytes: fixture.bytes) }
			try await eventually { await engine.snapshot().complete }
			replacement.stream.close()
		}
	}
	@Test(.serialized, arguments: [false, true], [false, true]) func duplicateDirectionsChooseTheSamePeerIDRuleInEitherHandshakeOrder(_ incomingFirst: Bool, _ localIDIsGreater: Bool) async throws {
		try await transferFixture { fixture in
			let engine = try await fixture.transfer("download", peerID: Data(repeating: localIDIsGreater ? 200 : 1, count: 20)), remoteID = Data(repeating: 77, count: 20)
			func open(_ outgoing: Bool) async throws -> (UUID, WirePeer) {
				let listener = try await fixture.listen(), endpoint = try NetworkEndpoint("127.0.0.1", port: listener.port)
				if outgoing {
					let connecting = Task { try await engine.connect(to: endpoint) }
					let raw = try await listener.accept(timeout: 3); return try await (connecting.value, WirePeer(stream: raw))
				}
				let raw = try await TCPStream.connect(to: endpoint), accepted = try await listener.accept(timeout: 3)
				return (try await engine.attach(accepted), WirePeer(stream: raw))
			}
			let firstOutgoing = !incomingFirst, first = try await open(firstOutgoing)
			let firstID = first.0
			try await first.1.hello(hash: fixture.metadata.hashes.v1!, identity: 77)
			try await eventually { await engine.snapshot().peers.contains { $0.id == firstID && $0.peerID == remoteID } }
			let second = try await open(!firstOutgoing)
			// Rejected incoming attempts can close before returning their hello.
			_ = try? await second.1.hello(hash: fixture.metadata.hashes.v1!, identity: 77)
			let retained = firstOutgoing == localIDIsGreater ? first.0 : second.0
			try await eventually { let peers = await engine.snapshot().peers; return peers.count == 1 && peers[0].id == retained && peers[0].peerID == remoteID }
			first.1.stream.close(); second.1.stream.close()
		}
	}
	@Test func failedShutdownPreservesCheckpointAndCanBeRetried() async throws {
		try await transferFixture { fixture in
			let engine = try await fixture.transfer("download")
			let checkpoint = fixture.root.appendingPathComponent("download-state/checkpoint.plist"), backup = fixture.root.appendingPathComponent("checkpoint-backup")
			let bytes = try Data(contentsOf: checkpoint)
			try FileManager.default.moveItem(at: checkpoint, to: backup)
			try FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: false)
			await #expect(throws: (any Error).self) { try await engine.shutdown() }
			#expect(await engine.snapshot().stopped == false)
			#expect(try Data(contentsOf: backup) == bytes)
			try FileManager.default.removeItem(at: checkpoint); try FileManager.default.moveItem(at: backup, to: checkpoint)
			try await withThrowingTaskGroup(of: Void.self) { group in
				for _ in 0..<4 { group.addTask { try await engine.shutdown() } }; try await group.waitForAll()
			}
			#expect(await engine.snapshot().stopped)
		}
	}
	@Test func repeatedUnsolicitedDuplicateIsClosed() async throws {
		try await transferFixture { fixture in
			var configuration = plainTransferConfiguration(); configuration.pipeline = 1
			let engine = try await fixture.transfer("download", configuration: configuration), peer = try await fixture.scripted(engine)
			try await peer.seed(pieceCount: 3); let first = try await peer.requests(1)[0]
			try await peer.reply(first, bytes: fixture.bytes); try await peer.reply(first, bytes: fixture.bytes)
			try await eventually { await engine.snapshot().peers.isEmpty }
			#expect(await engine.snapshot().downloaded == Int64(first.length))
		}
	}
	@Test func cancelledQueuedDiskWriteDoesNotLeaveAnUnrequestableBlock() async throws {
		try await transferFixture { fixture in
			let engine = try await fixture.transfer("download"), peer = try await fixture.scripted(engine)
			try await peer.seed(pieceCount: 3); let requests = try await peer.requests(6)
			let worker = await fixture.stores[0].worker, entered = AsyncStream<Void>.makeStream(), release = DispatchSemaphore(value: 0)
			let blocker = Task { try await worker.run { _ in entered.continuation.yield(()); _ = release.wait(timeout: .now() + 3) } }
			defer { release.signal() }
			try await engineDeadline { for await _ in entered.stream { return }; throw PeerFailure.closed }
			try await peer.reply(requests[0], bytes: fixture.bytes)
			try await eventually { await engine.snapshot().writingBlocks == 1 }
			let id = await engine.snapshot().peers[0].id
			await engine.drop(id, error: PeerFailure.invalid("fixture disconnect")); release.signal(); try await blocker.value
			try await eventually { await engine.snapshot().peers.isEmpty }
			#expect(await engine.lastPeerError?.contains("fixture disconnect") == true)
			#expect(await engine.snapshot().writingBlocks == 0)
			let seed = try await fixture.transfer("seed", seed: true); try await fixture.join(engine, seed)
			try await eventually { await engine.snapshot().complete }
		}
	}
	@Test func realBidirectionalTransferAndSelectiveBoundaryStorage() async throws {
		try await transferFixture { fixture in
			let seed = try await fixture.transfer("seed", seed: true), full = try await fixture.transfer("full")
			try await fixture.join(full, seed)
			try await eventually { await full.snapshot().complete }
			#expect(try Data(contentsOf: fixture.root.appendingPathComponent("full/bundle/skip")) == fixture.bytes.subdata(in: 10003..<60022))
			let partial = try await fixture.transfer("partial", selected: [true, false, false, false])
			try await fixture.join(partial, full)
			try await eventually { await partial.snapshot().complete }
			let snapshot = await partial.snapshot()
			#expect(snapshot.verifiedPieces == [0] && snapshot.downloaded == 32768)
			#expect(try Data(contentsOf: fixture.root.appendingPathComponent("partial/bundle/a")) == fixture.bytes.prefix(10003))
			#expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("partial/bundle/skip").path))
			#expect(await full.snapshot().uploaded == 32768)
		}
	}
	@Test func endgameCancelsDuplicatesAndDisconnectCompletes() async throws {
		try await transferFixture { fixture in
			var config = plainTransferConfiguration(); config.pipeline = 32
			let engine = try await fixture.transfer("download", configuration: config)
			let first = try await fixture.scripted(engine, identity: 11), second = try await fixture.scripted(engine, identity: 12)
			try await first.seed(pieceCount: 3); let requests = try await first.requests(6)
			try await second.seed(pieceCount: 3); let duplicates = try await second.requests(6)
			#expect(requests == duplicates)
			try await first.reply(requests[0], bytes: fixture.bytes)
			var canceled: PeerBlock?
			while canceled == nil { if case .cancel(let block) = try await second.next() { canceled = block } }
			#expect(canceled == requests[0])
			try await second.reply(requests[0], bytes: fixture.bytes)
			try await eventually { await engine.snapshot().redundantBytes == Int64(requests[0].length) }
			second.stream.close()
			for block in requests.dropFirst() { try await first.reply(block, bytes: fixture.bytes) }
			try await eventually { await engine.snapshot().complete }
			#expect(await engine.snapshot().downloaded == Int64(fixture.bytes.count + requests[0].length))
		}
	}
	@Test func corruptPeerIsDroppedAndGoodPeerRecovers() async throws {
		try await transferFixture { fixture in
			let engine = try await fixture.transfer("download"), bad = try await fixture.scripted(engine, identity: 13)
			try await bad.seed(pieceCount: 3)
			let requests = try await bad.requests(6)
			for block in requests.filter({ $0.piece == 0 }) { try await bad.reply(block, bytes: fixture.bytes, corrupt: block.offset == 0) }
			try await eventually { await engine.snapshot().corruptPieces == 1 }
			#expect(await engine.snapshot().verifiedPieces.isEmpty)
			#expect(await engine.snapshot().corruptBytes == 32768)
			let good = try await fixture.transfer("seed", seed: true); try await fixture.join(engine, good)
			try await eventually { await engine.snapshot().complete }
			#expect(await engine.snapshot().storageError == nil)
			try await engine.shutdown()
			let restored = try await TCPTransfer.open(metadata: fixture.metadata, storage: fixture.stores[0], configuration: plainTransferConfiguration()); fixture.engines.append(restored)
			let counters = await restored.snapshot()
			#expect(counters.corruptBytes == 32768 && counters.redundantBytes == 0 && counters.downloaded == Int64(fixture.bytes.count + 32768))
		}
	}
	@Test func chokeAndLateBlockDoNotPoisonRecovery() async throws {
		try await transferFixture { fixture in
			let engine = try await fixture.transfer("download"), stalled = try await fixture.scripted(engine, identity: 14)
			try await stalled.seed(pieceCount: 3); let requests = try await stalled.requests(6)
			try await stalled.send(.choke)
			try await stalled.reply(requests[0], bytes: fixture.bytes)
			let seed = try await fixture.transfer("seed", seed: true); try await fixture.join(engine, seed)
			try await eventually { await engine.snapshot().complete }
			#expect(await engine.snapshot().corruptPieces == 0)
		}
	}
	@Test func malformedPeersAreClosedWithoutStorageProgress() async throws {
		try await transferFixture { fixture in
			let engine = try await fixture.transfer("download")
			let frames = [Data([0, 1, 0, 1]), try PeerMessage.bitfield(Data([255])).encoded(), try PeerMessage.have(99).encoded(), try PeerMessage.piece(0, 0, Data([42])).encoded()]
			for (index, frame) in frames.enumerated() {
				let peer = try await fixture.scripted(engine, identity: UInt8(20 + index))
				try await peer.stream.write(frame)
				try await eventually { await engine.snapshot().peers.isEmpty }
			}
			#expect(await engine.snapshot().verifiedPieces.isEmpty)
			#expect(await engine.snapshot().storageError == nil)
		}
	}
	@Test func concurrentShutdownCancelsRateLimitedUploads() async throws {
		try await transferFixture { fixture in
			var config = plainTransferConfiguration(); config.uploadLimit = 1024
			let seed = try await fixture.transfer("seed", seed: true, configuration: config), download = try await fixture.transfer("download")
			try await fixture.join(download, seed)
			try await eventually { await download.snapshot().peers.contains { $0.pendingRequests > 0 } }
			try await withThrowingTaskGroup(of: Void.self) { group in
				for _ in 0..<6 { group.addTask { try await seed.shutdown(); try await download.shutdown() } }
				try await group.waitForAll()
			}
			let seedStopped = await seed.snapshot().stopped, downloadStopped = await download.snapshot().stopped
			#expect(seedStopped && downloadStopped)
		}
	}
	@Test func downloadRequestLimitsRemainBounded() throws {
		var configuration = plainTransferConfiguration()
		for window in [1, 16, 32] { configuration.pipeline = window; try configuration.validate() }
		for window in [0, 33, 48, 64, 65] {
			configuration.pipeline = window
			#expect(throws: (any Error).self) { try configuration.validate() }
		}
		var handshake = ExtensionHandshake()
		try handshake.apply(extensionDictionary([:]).encoded())
		#expect(handshake.queueLimit == 32)
		for remote in [1, 31, 32, 48, 64, 2000, 65536] {
			try handshake.apply(extensionDictionary(["reqq": .integer(Int64(remote))]).encoded())
			#expect(handshake.queueLimit == min(48, remote))
		}
		for remote in [0, 65537] {
			#expect(throws: (any Error).self) { try handshake.apply(extensionDictionary(["reqq": .integer(Int64(remote))]).encoded()) }
		}
	}
	@Test(arguments: [4, 8, 31, 32, 48, 64], [0, 8, 16, 32]) func requestWindowRespectsConfigurationAndRemoteQueue(_ remoteLimit: Int, _ configured: Int) async throws {
		try await checkRequestWindow(remoteLimit: remoteLimit, configured: configured, pieceLength: 131072)
	}
	@Test(arguments: zip([16384, 32768, 65536, 262144, 1048576], [8, 16, 32, 32, 32])) func requestWindowRespectsAvailablePieces(_ pieceLength: Int, _ expected: Int) async throws {
		try await checkRequestWindow(remoteLimit: 64, configured: 32, pieceLength: pieceLength, expectedRequests: expected)
	}
	@Test func readWindowDistinguishesWaitsFromLocalWorkAndSlowDelivery() {
		var window = PeerReadWindow()
		// Exactly representable interval boundaries keep the assertions independent of rounding.
		func quarter(_ base: Double, wait: Double, payload: Int) -> Int? {
			var result: Int?
			for i in 1...16 {
				let end = base + Double(i) / 64
				result = window.record(start: i == 1 && base == 0 ? 0 : end - wait, end: end, payload: payload)
			}
			return result
		}
		#expect(quarter(0, wait: 0.0001, payload: 262_144) == 32)
		#expect(quarter(0.25, wait: 0.010, payload: 262_144) == 48)
		#expect(quarter(0.5, wait: 0.010, payload: 65_536) == 32)
		#expect(window.record(start: 0.75, end: 1.75, payload: 262_144) == 32)
	}
	private func checkRequestWindow(remoteLimit: Int, configured: Int, pieceLength: Int, expectedRequests: Int? = nil) async throws {
		let fixture = try TransferFixture(lengths: [2097152, 0, 0, 0], pieceLength: pieceLength)
		do {
			var configuration = plainTransferConfiguration()
			if configured != 0 { configuration.pipeline = configured }
			let expected = expectedRequests ?? min(configuration.pipeline, remoteLimit)
			let down = try await fixture.transfer("window-download", configuration: configuration)
			var reserved = Data(repeating: 0, count: 8); reserved[5] = 16
			let peer = try await fixture.scripted(down, reserved: reserved)
			try await peer.send(.extended(0, extensionDictionary(["m": extensionDictionary([:]), "reqq": .integer(Int64(remoteLimit))]).encoded()))
			try await peer.seed(pieceCount: fixture.stores[0].layout.pieceCount)
			let requests = try await peer.requests(expected)
			#expect(Set(requests).count == expected)
			#expect(requests.allSatisfy { $0.length == 16384 })
			try await eventually { await down.snapshot().peers.first?.pendingRequests == expected }
			let returned = min(requests.count, pieceLength / 16384)
			for block in requests.prefix(returned) { try await peer.reply(block, bytes: fixture.bytes, pieceLength: pieceLength) }
			let replacements = try await peer.requests(returned)
			#expect(Set(replacements).isDisjoint(with: requests))
			try await eventually { await down.snapshot().peers.first?.pendingRequests == expected }
			try await down.shutdown()
			#expect(await down.snapshot().peers.isEmpty)
			await fixture.clean()
		} catch { await fixture.clean(); throw error }
	}
}
