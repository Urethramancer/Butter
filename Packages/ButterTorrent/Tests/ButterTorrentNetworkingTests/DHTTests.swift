import Foundation
import Testing
import ButterTorrentMetadata
@testable import ButterTorrentNetworking

func dhtMetadata(_ isPrivate: Bool = false) throws -> TorrentMetadata {
	try TorrentMetadata(DHTWire.dictionary(["info": DHTWire.dictionary(["name": .bytes(Data("a".utf8)), "length": .integer(1), "piece length": .integer(16384), "pieces": .bytes(Data(repeating: 42, count: 20)), "private": .integer(isPrivate ? 1 : 0)])]).encoded())
}

@Suite struct DHTTests {
	@Test func blockedNodesCannotQueryOrReceiveRepliesAndLimitsRemainExplicit() async throws {
		let serverSocket = try DatagramSocket(bind: NetworkEndpoint("127.0.0.1", port: 0)), serverUDP = UDPDispatcher(transport: serverSocket)
		let clientUDP = UDPDispatcher(transport: try DatagramSocket(bind: NetworkEndpoint("127.0.0.1", port: 0)))
		let address = try IPAddress("127.0.0.1"), filter = try PeerAddressFilter(ranges: [PeerAddressRange(first: address, last: address)])
		let server = try DHTNode(dispatcher: serverUDP, bootstrap: [], addressFilter: filter), metadata = try dhtMetadata()
		do {
			await #expect(throws: NetworkFailure.limit("DHT registered swarms")) { try await server.setTorrents(Array(repeating: metadata, count: 10_001)) }
			try await server.setTorrents([metadata])
			let transaction = Data([1]), query = try DHTWire.encode(["t": .bytes(transaction), "y": .bytes(Data("q".utf8)), "q": .bytes(Data("ping".utf8)), "a": DHTWire.dictionary(["id": .bytes(Data(repeating: 0, count: 20))])])
			await #expect(throws: NetworkFailure.timedOut) { try await clientUDP.exchange(query, with: serverSocket.localEndpoint, reply: .dht(transaction), timeout: 0.1) }
			await server.setAddressFilter(.init())
			let reply = try await clientUDP.exchange(query, with: serverSocket.localEndpoint, reply: .dht(transaction), timeout: 1)
			#expect(try DHTWire.decode(reply.payload)["y"]?.text == "r")
		} catch { await server.shutdown(); try? await serverUDP.shutdown(); try? await clientUDP.shutdown(); throw error }; await server.shutdown(); try await serverUDP.shutdown(); try await clientUDP.shutdown()
	}
	@Test func externalAddressVotesRequireIndependentNetworksAndDeadlinesDrain() async throws {
		let socket = try DatagramSocket(bind: NetworkEndpoint("0.0.0.0", port: 0)), udp = UDPDispatcher(transport: socket)
		let node = try DHTNode(dispatcher: udp, bootstrap: []), initial = await node.nodeID
		let claimed = try DHTWire.compact(NetworkEndpoint("8.8.8.8", port: 6881))
		for index in 1...3 { await node.observe(claimed, source: try NetworkEndpoint("198.51.100.\(index)", port: 6881)) }
		#expect(await node.nodeID == initial)
		await node.observe(claimed, source: try NetworkEndpoint("198.51.101.1", port: 6881))
		await node.observe(claimed, source: try NetworkEndpoint("198.51.102.1", port: 6881))
		#expect(await node.nodeID != initial)
		#expect(DHTIdentity.valid(await node.nodeID, address: try IPAddress("8.8.8.8")))
		await node.shutdown(); try await udp.shutdown()
		let transport = try InjectedDatagrams(), clock = ManualTransportClock(), timedUDP = UDPDispatcher(transport: transport, clock: clock)
		let timedNode = try DHTNode(dispatcher: timedUDP, bootstrap: [NetworkEndpoint("127.0.0.1", port: 54321)], clock: clock), metadata = try dhtMetadata()
		try await timedNode.setTorrents([metadata])
		let work = Task { try await timedNode.getPeers(for: metadata) }
		try await clock.waitForSleep(3); clock.advance(3)
		do { _ = try await work.value; Issue.record("DHT deadline was ignored") } catch { #expect(error as? NetworkFailure == .timedOut) }
		#expect(await timedUDP.pendingCount == 0)
		await timedNode.shutdown(); try await timedUDP.shutdown()
	}
	@Test func secureIdentityVectorsTokensAndRoutingBounds() throws {
		for (address, random, prefix) in [("124.31.75.21", 1, [0x5f, 0xbf, 0xbf]), ("21.75.31.124", 86, [0x5a, 0x3c, 0xe9]), ("65.23.51.170", 22, [0xa5, 0xd4, 0x32]), ("84.124.73.14", 65, [0x1b, 3, 0x21]), ("43.213.53.83", 90, [0xe5, 0x6f, 0x6c])] {
			let ip = try IPAddress(address); var entropy = Data(repeating: 0, count: 20); entropy[19] = UInt8(random)
			var id = try DHTIdentity.make(address: ip, entropy: entropy)
			#expect(id[0] == prefix[0] && id[1] == prefix[1] && id[2] & 248 == prefix[2] & 248)
			#expect(DHTIdentity.valid(id, address: ip)); id[0] ^= 1; #expect(!DHTIdentity.valid(id, address: ip))
		}
		let ip = try IPAddress("2001:4860:4860::8888"), tokenSource = DHTTokens(), token = tokenSource.token(address: ip, bucket: 1)
		#expect(tokenSource.valid(token, address: ip, now: 600))
		#expect(!tokenSource.valid(token, address: ip, now: 900))
		#expect(!tokenSource.valid(token, address: try IPAddress("2001:4860:4860::8844"), now: 600))
		var table = DHTRoutingTable(id: Data(repeating: 0, count: 20))
		for index in 0..<100 {
			var id = Data(repeating: 0, count: 20); id[0] = 128; id[19] = UInt8(index)
			table.insert(DHTContact(id: id, endpoint: try NetworkEndpoint("127.0.0.1", port: UInt16(1000 + index))), now: 0)
		}
		#expect(table.closest(table.id, now: 0, count: 100).count == 8)
		#expect(table.closest(table.id, now: 901).isEmpty)
	}
	@Test(arguments: ["127.0.0.1", "::1"]) func loopbackAnnounceLookupAndTokenRejection(_ host: String) async throws {
		let serverSocket = try DatagramSocket(bind: NetworkEndpoint(host, port: 0)), clientSocket = try DatagramSocket(bind: NetworkEndpoint(host, port: 0))
		let serverUDP = UDPDispatcher(transport: serverSocket), clientUDP = UDPDispatcher(transport: clientSocket)
		let server = try DHTNode(dispatcher: serverUDP, bootstrap: []), client = try DHTNode(dispatcher: clientUDP, bootstrap: [serverSocket.localEndpoint])
		let observerSocket = try DatagramSocket(bind: NetworkEndpoint(host, port: 0)), observerUDP = UDPDispatcher(transport: observerSocket)
		let observer = try DHTNode(dispatcher: observerUDP, bootstrap: [serverSocket.localEndpoint])
		do {
			let metadata = try dhtMetadata(), hash = metadata.hashes.v1!
			try await server.setTorrents([metadata]); try await client.setTorrents([metadata])
			#expect(try await client.getPeers(for: metadata, announcePort: 6881).isEmpty)
			// A second client must discover the announced TCP endpoint, not the UDP source port.
			try await observer.setTorrents([metadata])
			let found = try await observer.getPeers(for: metadata)
			#expect(found == [NetworkEndpoint(address: clientSocket.localEndpoint.address, port: 6881)])
			#expect(await server.contactCount == 1)
			let bad = try DHTWire.encode(["t": .bytes(Data([1])), "y": .bytes(Data("q".utf8)), "q": .bytes(Data("announce_peer".utf8)), "a": DHTWire.dictionary(["id": .bytes(await client.nodeID), "info_hash": .bytes(hash), "port": .integer(9999), "token": .bytes(Data(repeating: 0, count: 8))])])
			let reply = try await clientUDP.exchange(bad, with: serverSocket.localEndpoint, reply: .dht(Data([1])), timeout: 3)
			#expect(try DHTWire.decode(reply.payload)["y"]?.text == "e")
			await client.shutdown(); await server.shutdown()
			// Shutting down DHT must leave the shared dispatcher available to other protocols.
			try await clientUDP.send(Data([42]), to: serverSocket.localEndpoint)
		} catch { await observer.shutdown(); await client.shutdown(); await server.shutdown(); try? await observerUDP.shutdown(); try? await clientUDP.shutdown(); try? await serverUDP.shutdown(); throw error }
		await observer.shutdown(); try await observerUDP.shutdown(); try await clientUDP.shutdown(); try await serverUDP.shutdown()
	}
	@Test func privatePolicyCancelsOutstandingLookupBeforeAnotherSend() async throws {
		let transport = try InjectedDatagrams(), udp = UDPDispatcher(transport: transport)
		let node = try DHTNode(dispatcher: udp, bootstrap: [NetworkEndpoint("127.0.0.1", port: 54321)])
		let secret = try dhtMetadata(true), metadata = try dhtMetadata()
		try await node.setTorrents([secret])
		#expect(try await node.getPeers(for: secret, announcePort: 6881).isEmpty)
		#expect(await transport.sentCount == 0)
		try await node.setTorrents([metadata])
		let lookup = Task { try await node.getPeers(for: metadata, announcePort: 6881) }
		_ = try await transport.nextSent()
		try await node.setTorrents([secret])
		do { _ = try await lookup.value; Issue.record("Discovery survived public metadata removal") } catch {}
		await node.shutdown()
		#expect(await transport.sentCount == 1)
		#expect(await udp.pendingCount == 0)
		try await udp.shutdown()
	}
	@Test func rejectsSpoofedResponsesAndUnprovenRoutingReferrals() async throws {
		let transport = try InjectedDatagrams(), udp = UDPDispatcher(transport: transport)
		let peer = try NetworkEndpoint("127.0.0.1", port: 54321), attacker = try NetworkEndpoint("127.0.0.1", port: 54322)
		let node = try DHTNode(dispatcher: udp, bootstrap: [peer]), metadata = try dhtMetadata()
		try await node.setTorrents([metadata])
		let lookup = Task { try await node.getPeers(for: metadata) }
		let sent = try await transport.nextSent(), request = try DHTWire.decode(sent.0)
		let response = try DHTWire.encode(["t": request["t"]!, "y": .bytes(Data("r".utf8)), "r": DHTWire.dictionary(["id": .bytes(Data(repeating: 9, count: 20)), "values": .list([.bytes(DHTWire.compact(attacker))])])])
		await transport.inject(response, source: attacker)
		let referral = Data(repeating: 10, count: 20) + DHTWire.compact(attacker)
		let legitimate = try DHTWire.encode(["t": request["t"]!, "y": .bytes(Data("r".utf8)), "r": DHTWire.dictionary(["id": .bytes(Data(repeating: 8, count: 20)), "nodes": .bytes(referral)])])
		await transport.inject(legitimate, source: peer)
		let challenge = try await transport.nextSent()
		#expect(challenge.1 == attacker)
		#expect(await node.contactCount == 1)
		let rejected = try DHTWire.encode(["t": try DHTWire.decode(challenge.0)["t"]!, "y": .bytes(Data("e".utf8)), "e": .list([.integer(203), .bytes(Data("Rejected".utf8))])])
		await transport.inject(rejected, source: attacker)
		#expect(try await lookup.value.isEmpty)
		#expect(await node.contactCount == 1)
		await node.shutdown(); try await udp.shutdown()
	}
}
