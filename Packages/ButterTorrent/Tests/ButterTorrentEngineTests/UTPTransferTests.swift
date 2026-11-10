import Foundation
import Testing
import ButterTorrentMetadata
import ButterTorrentNetworking
@testable import ButterTorrentEngine

@Suite struct UTPTransferTests {
	@Test(arguments: [false, true]) func crossedUTPConnectionsResolveBeforePeerIDs(_ localPortIsLower: Bool) async throws {
		try await transferFixture { fixture in
			let leftEndpoint = try NetworkEndpoint("127.0.0.1", port: localPortIsLower ? 41001 : 41002), rightEndpoint = try NetworkEndpoint("127.0.0.1", port: localPortIsLower ? 41002 : 41001)
			let link = CrossedUTPLink(initiator: leftEndpoint)
			let leftPort = CrossedUTPPort(endpoint: leftEndpoint, link: link), rightPort = CrossedUTPPort(endpoint: rightEndpoint, link: link)
			await link.add(leftPort); await link.add(rightPort)
			let leftUDP = UDPDispatcher(transport: leftPort), rightUDP = UDPDispatcher(transport: rightPort)
			let left = try await UTPTransport.open(dispatcher: leftUDP), right = try await UTPTransport.open(dispatcher: rightUDP)
			let engine = try await fixture.transfer("download")
			let connecting = Task { try await engine.connect(to: right.localEndpoint, utp: left) }
			var stage = "accept outgoing"
			do {
				// Hold its STATE reply so the outgoing connection cannot finish early.
				let pending = try await right.accept(timeout: 3)
				try await eventually { await link.holding }
				stage = "open incoming"
				let incoming = Task { try await left.accept(timeout: 3) }
				let remote = try await right.connect(to: left.localEndpoint, timeout: 3), peer = WirePeer(stream: remote)
				let raw = try await incoming.value
				let retained: UUID?
				stage = "admit incoming"
				if localPortIsLower {
					await #expect(throws: PeerFailure.self) { try await engine.attach(raw) }; retained = nil
				} else {
					retained = try await engine.attach(raw)
					try await peer.hello(hash: fixture.metadata.hashes.v1!, identity: 77, fragmented: false)
					try await eventually { await engine.snapshot().peers.contains { $0.id == retained && $0.peerID != nil } }
				}
				await link.release()
				stage = "wait outgoing result"
				let connected = try await connecting.value
				stage = "wire handshake"
				let serving: WirePeer
				if localPortIsLower { serving = WirePeer(stream: pending); try await serving.hello(hash: fixture.metadata.hashes.v1!, identity: 77, fragmented: false) }
				else { #expect(connected == retained); serving = peer }
				#expect(await engine.snapshot().peers.count == 1)
				stage = "payload transfer"
				try await serving.seed(pieceCount: 3)
				for block in try await serving.requests(6) { try await serving.reply(block, bytes: fixture.bytes) }
				try await eventually { await engine.snapshot().complete }
				pending.close(); peer.stream.close()
			} catch {
				connecting.cancel()
				let connection: String
				do { connection = "retained \(try await connecting.value)" } catch { connection = String(describing: error) }
				let state = await engine.snapshot()
				await left.shutdown(); await right.shutdown(); try? await leftUDP.shutdown(); try? await rightUDP.shutdown()
				throw PeerFailure.invalid("crossed µTP \(stage): \(error); outgoing: \(connection); peer error: \(state.lastPeerError ?? "")")
			}
			await left.shutdown(); await right.shutdown(); try await leftUDP.shutdown(); try await rightUDP.shutdown()
		}
	}
	@Test func encryptedMagnetOwnsItsUTPTransferAndShutdown() async throws {
		let fixture = try V2Fixture(version: 3), registry = TorrentIdentityRegistry()
		let sourceSocket = try DatagramSocket(bind: NetworkEndpoint("127.0.0.1", port: 0)), downSocket = try DatagramSocket(bind: NetworkEndpoint("127.0.0.1", port: 0))
		let sourceUDP = UDPDispatcher(transport: sourceSocket), downUDP = UDPDispatcher(transport: downSocket)
		let source = try await UTPTransport.open(dispatcher: sourceUDP), down = try await UTPTransport.open(dispatcher: downUDP)
		var config = TCPTransferConfiguration(); config.encryption = .init(incoming: .required, outgoing: .required, levels: .rc4)
		let magnet = MagnetDownload(magnet: Magnet(hashes: fixture.metadata.hashes), destination: fixture.root.appendingPathComponent("download"), stateDirectory: fixture.root.appendingPathComponent("state"), registry: registry, configuration: config, utp: down)
		var serving: Task<Void, Error>?
		do {
			let seed = try await fixture.engine("seed", seed: true, encryption: config.encryption)
			let task = Task { for _ in 0..<2 { _ = try await seed.attach(source.accept(timeout: 10)) } }; serving = task
			guard case .ready(_, let engine, _) = try await magnet.resolve(peers: [sourceSocket.localEndpoint]) else { throw PeerFailure.invalid("unexpected duplicate") }
			try await task.value; try await eventually { await engine.snapshot().complete }
			#expect(await engine.snapshot().peers.contains { $0.transport == .utp && $0.encryption == .rc4 })
			try await magnet.shutdown(); #expect(await down.snapshot().connections == 0)
		} catch { serving?.cancel(); try? await magnet.shutdown(); await fixture.close(); await source.shutdown(); await down.shutdown(); try? await sourceUDP.shutdown(); try? await downUDP.shutdown(); throw error }
		await fixture.close(); await source.shutdown(); await down.shutdown(); try await sourceUDP.shutdown(); try await downUDP.shutdown()
	}
	@Test func shutdownCancelsAnOutgoingUTPSYN() async throws {
		try await transferFixture { fixture in
			let sourceSocket = try DatagramSocket(bind: NetworkEndpoint("127.0.0.1", port: 0)), unanswered = try DatagramSocket(bind: NetworkEndpoint("127.0.0.1", port: 0))
			let udp = UDPDispatcher(transport: sourceSocket), owner = try await UTPTransport.open(dispatcher: udp)
			do {
				let engine = try await fixture.transfer("download")
				let connection = Task { try await engine.connect(to: unanswered.localEndpoint, utp: owner) }
				_ = try await engineDeadline { for await datagram in unanswered.datagrams { return datagram }; throw PeerFailure.closed }
				try await engine.shutdown()
				await #expect(throws: CancellationError.self) { try await connection.value }
				#expect(await owner.snapshot().connections == 0)
			} catch { await owner.shutdown(); try? await udp.shutdown(); try? await unanswered.shutdown(); throw error }
			await owner.shutdown(); try await udp.shutdown(); try await unanswered.shutdown()
		}
	}
	@Test(arguments: [1, 2, 3], [false, true]) func metadataAndTransfersWithoutTCP(_ version: Int, _ encrypted: Bool) async throws {
		let fixture = try V2Fixture(version: version)
		let seedSocket = try DatagramSocket(bind: NetworkEndpoint("127.0.0.1", port: 0)), downSocket = try DatagramSocket(bind: NetworkEndpoint("127.0.0.1", port: 0))
		let seedUDP = UDPDispatcher(transport: seedSocket), downUDP = UDPDispatcher(transport: downSocket)
		let seedUTP = try await UTPTransport.open(dispatcher: seedUDP, maximumConnections: 1), downUTP = try await UTPTransport.open(dispatcher: downUDP, maximumConnections: 1)
		let encryption = encrypted ? PeerEncryptionConfiguration(incoming: .required, outgoing: .required, levels: .rc4) : .disabled
		var serving: Task<Void, Error>?
		do {
			let seed = try await fixture.engine("seed", seed: true, encryption: encryption), down = try await fixture.engine("download", seed: false, sparse: true, encryption: encryption)
			let task = Task { for _ in 0..<2 { _ = try await seed.attach(seedUTP.accept(timeout: 10)) } }; serving = task
			let received = try await MetadataExchange(encryption: encryption, utp: downUTP).fetch(Magnet(hashes: fixture.metadata.hashes), peers: [seedSocket.localEndpoint], timeout: 10)
			#expect(received.originalInfo == fixture.metadata.originalInfo)
			_ = try await down.connect(to: seedSocket.localEndpoint, utp: downUTP); try await task.value
			try await eventually { await down.snapshot().complete }
			#expect(await down.snapshot().peers.contains { $0.transport == .utp && $0.encryption == (encrypted ? .rc4 : .plaintext) })
			#expect(try Data(contentsOf: fixture.root.appendingPathComponent("download/Bundle/b")) == Data(repeating: 17, count: 200003))
		} catch {
			serving?.cancel(); await fixture.close(); await seedUTP.shutdown(); await downUTP.shutdown(); try? await seedUDP.shutdown(); try? await downUDP.shutdown(); throw error
		}
		await fixture.close(); await seedUTP.shutdown(); await downUTP.shutdown(); try await seedUDP.shutdown(); try await downUDP.shutdown()
	}
}
