import Foundation
import Testing
import ButterTorrentMetadata
import ButterTorrentNetworking
@testable import ButterTorrentEngine

@Suite struct PeerDiscoveryTests {
	@Test(arguments: [false, true]) func pexIsNegotiatedAndAcceptedOnlyForVerifiedPublicMetadata(_ isPrivate: Bool) async throws {
		let fixture = try V2Fixture(version: 1, isPrivate: isPrivate)
		do {
			let engine = try await fixture.engine("download", seed: false), (endpoint, serving) = try await fixture.provider(engine)
			let wire = WirePeer(stream: try await TCPStream.connect(to: endpoint)); var flags = Data(repeating: 0, count: 8); flags[5] = 16
			try await wire.hello(hash: fixture.metadata.hashes.v1!, identity: 77, reserved: flags); try await serving.value
			var foundHandshake = false
			while !foundHandshake {
				if case .extended(0, let bytes) = try await wire.next() {
					let map = try BencodeDocument(bytes).root["m"]
					#expect((map?["ut_pex"] != nil) == !isPrivate); foundHandshake = true
					#expect((map?["ut_metadata"] != nil) == !isPrivate)
				}
			}
			let pieces = Int((fixture.metadata.inspection.files.reduce(Int64(0)) { $0 + $1.size } + fixture.metadata.pieceLength - 1) / fixture.metadata.pieceLength)
			try await wire.send(.bitfield(PieceBitfield(count: pieces).bytes))
			try await wire.send(.extended(0, extensionDictionary(["m": extensionDictionary(["ut_pex": .integer(9)])]).encoded()))
			let advertised = try NetworkEndpoint("127.0.0.1", port: 54321)
			let payload = try PeerExchange.encode(added: [ExchangedPeer(endpoint: advertised, flags: 0)], dropped: [])
			try await wire.send(.extended(2, payload))
			if isPrivate {
				try await eventually { await engine.snapshot().peers.isEmpty }
				#expect(await engine.snapshot().lastPeerError?.contains("private/disabled") == true)
				try await engine.shutdown()
				var events = 0; for await _ in engine.discoveredPeers { events += 1 }; #expect(events == 0)
			} else {
				let peer = try await engineDeadline { for await peer in engine.discoveredPeers { return peer }; throw PeerFailure.closed }
				#expect(peer.endpoint == advertised)
				try await wire.send(.extended(2, payload))
				try await eventually { await engine.snapshot().peers.isEmpty }
				#expect(await engine.snapshot().lastPeerError?.contains("PEX update rate") == true)
			}
		} catch { await fixture.close(); throw error }; await fixture.close()
	}
	@Test func dhtDiscoveryFeedsTheHeadlessV2Transfer() async throws {
		let fixture = try V2Fixture(version: 2)
		let routerSocket = try DatagramSocket(bind: NetworkEndpoint("127.0.0.1", port: 0)), seedSocket = try DatagramSocket(bind: NetworkEndpoint("127.0.0.1", port: 0)), downSocket = try DatagramSocket(bind: NetworkEndpoint("127.0.0.1", port: 0))
		let routerUDP = UDPDispatcher(transport: routerSocket), seedUDP = UDPDispatcher(transport: seedSocket), downUDP = UDPDispatcher(transport: downSocket)
		let router = try DHTNode(dispatcher: routerUDP, bootstrap: []), source = try DHTNode(dispatcher: seedUDP, bootstrap: [routerSocket.localEndpoint]), destination = try DHTNode(dispatcher: downUDP, bootstrap: [routerSocket.localEndpoint])
		do {
			let seed = try await fixture.engine("seed", seed: true), download = try await fixture.engine("download", seed: false, sparse: true)
			let (endpoint, serving) = try await fixture.provider(seed)
			for node in [router, source, destination] { try await node.setTorrents([fixture.metadata]) }
			_ = try await source.getPeers(for: fixture.metadata, announcePort: endpoint.port)
			let contacts = try await destination.getPeers(for: fixture.metadata)
			#expect(contacts == [endpoint])
			for contact in contacts { _ = try await download.connect(to: contact) }
			try await serving.value; try await eventually { await download.snapshot().complete }
		} catch {
			for node in [router, source, destination] { await node.shutdown() }; for udp in [routerUDP, seedUDP, downUDP] { try? await udp.shutdown() }; await fixture.close(); throw error
		}
		for node in [router, source, destination] { await node.shutdown() }; for udp in [routerUDP, seedUDP, downUDP] { try await udp.shutdown() }; await fixture.close()
	}
}
