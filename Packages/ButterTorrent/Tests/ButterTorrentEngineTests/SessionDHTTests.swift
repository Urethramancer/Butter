import Foundation
import Testing
import ButterTorrentMetadata
@testable import ButterTorrentNetworking
@testable import ButterTorrentEngine

extension NativeSessionTests { @Suite struct SessionDHTTests {
	@Test(arguments: [false, true]) func deliversPeersBeforeStalledReferralsOrAnnouncements(_ stallAnnouncement: Bool) async throws {
		let fixture = try TransferFixture(), clock = EngineClock(), probe = DiscoveryConnectionProbe()
		let silent = try DatagramSocket(bind: NetworkEndpoint("127.0.0.1", port: 0))
		let peer = try NetworkEndpoint("127.0.0.1", port: 7000)
		let router = try await SessionDHTRouter.open(host: "127.0.0.1", metadata: nil,
			replies: [fixture.metadata.hashes.v1!: [peer]], referral: stallAnnouncement ? nil : silent.localEndpoint,
			announceToken: stallAnnouncement ? Data([1]) : nil)
		let udp = UDPDispatcher(transport: try DatagramSocket(bind: NetworkEndpoint("127.0.0.1", port: 0)), clock: clock)
		let discovery = try SessionDHT(dispatchers: [udp], port: 6881, bootstrap: [router.endpoint], filter: .init(), clock: clock) { _, endpoint in
			#expect(endpoint == peer); await probe.connect()
		}
		do {
			let owner = try await ManagedTransfer.open(metadata: fixture.metadata, destination: fixture.root.appendingPathComponent("download"), stateDirectory: fixture.root.appendingPathComponent("state"), configuration: plainTransferConfiguration())
			do {
				try await discovery.update([SessionDHTTarget(id: "transfer", metadata: fixture.metadata, owner: owner)], metadata: [fixture.metadata])
				try await eventually { await probe.active == 1 }
				try await eventually { await udp.pendingCount == 1 }
				#expect(await discovery.snapshot().searches == 1)
				// The manual clock never advances: referral/announce timeouts cannot hide late delivery.
				try await discovery.update([], metadata: [fixture.metadata])
				#expect(await probe.active == 0)
				#expect(await probe.cancelled == 1)
				#expect(await udp.pendingCount == 0)
				try await owner.close()
			} catch { try? await owner.close(); throw error }
		} catch { await discovery.shutdown(); try? await udp.shutdown(); try? await silent.shutdown(); await router.close(); await fixture.clean(); throw error }
		await discovery.shutdown(); try await udp.shutdown(); try await silent.shutdown(); await router.close(); await fixture.clean()
	}
	@Test func privateArrivalDrainsUnresolvedDiscoveryAndItsPeerDelivery() async throws {
		let fixture = try V2Fixture(version: 3, isPrivate: true), clock = EngineClock(), receiver = MagnetPeerDelivery()
		let peer = try NetworkEndpoint("127.0.0.1", port: 7000)
		let hashes = [fixture.metadata.hashes.v1!, Data(fixture.metadata.hashes.v2!.prefix(20))]
		let router = try await SessionDHTRouter.open(host: "127.0.0.1", metadata: nil, replies: Dictionary(uniqueKeysWithValues: hashes.map { ($0, [peer]) }))
		var settings = SessionPeerSettings(); settings.dht = true
		let network = try await SessionPeerNetwork.open(settings: settings, budget: TCPPeerBudget(limit: 4), encryption: .disabled, filter: .init(), loopbackOnly: true, clock: clock, bootstrap: [router.endpoint]) { _, _ in Issue.record("Unresolved discovery attempted a payload connection") }
		let pending = SessionMagnetTarget(id: "pending", magnet: Magnet(hashes: fixture.metadata.hashes), revision: UUID()) { await receiver.deliver($0) }
		do {
			await network.updateDiscovery([], metadata: [], magnets: [pending])
			try await eventually { await receiver.active == 1 }
			#expect(await receiver.peers == [peer])
			await network.updateDiscovery([], metadata: [fixture.metadata], magnets: [pending])
			#expect(await receiver.active == 0)
			#expect(await receiver.cancelled == 1)
			#expect(await network.listener.udp4.pendingCount == 0)
			#expect(await network.snapshot().discovery.searches == 0)
			clock.advance(600)
			let packets = await router.packets
			#expect(packets.count == 2 && packets.allSatisfy { (try? BencodeDocument($0.payload).root["q"]?.text) == "get_peers" })
		} catch { await network.shutdown(); await router.close(); await fixture.close(); throw error }
		await network.shutdown(); await router.close(); await fixture.close()
	}
	@Test func failedDiscoveryRegistrationLeavesTheSharedUDPPortUsable() async throws {
		let fixture = try TransferFixture(), clock = ContinuousTransportClock()
		var settings = SessionPeerSettings(); settings.dht = true
		let network = try await SessionPeerNetwork.open(settings: settings, budget: TCPPeerBudget(limit: 4), encryption: .disabled, filter: .init(), loopbackOnly: true, clock: clock, bootstrap: []) { _, _ in Issue.record("Unregistered discovery connected a peer") }
		let receiver = try DatagramSocket(bind: NetworkEndpoint("127.0.0.1", port: 0))
		do {
			await network.updateDiscovery([], metadata: Array(repeating: fixture.metadata, count: 10_001))
			let snapshot = await network.snapshot()
			#expect(snapshot.udp && snapshot.port > 0 && !snapshot.discovery.enabled && !snapshot.discovery.error.isEmpty)
			try await network.listener.udp4.send(Data([42]), to: receiver.localEndpoint)
			let packet = try await engineDeadline { for await packet in receiver.datagrams { return packet }; throw NetworkFailure.closed }
			#expect(packet.payload == Data([42]) && packet.source.port == snapshot.port)
		} catch { await network.shutdown(); try? await receiver.shutdown(); await fixture.clean(); throw error }; await network.shutdown(); try await receiver.shutdown(); await fixture.clean()
	}
	@Test func searchesStayBoundedAndRepeatedRunCommandsDoNotRestartThem() async throws {
		let fixture = try TransferFixture(), v4 = try await SessionDHTRouter.open(host: "127.0.0.1", metadata: nil), v6 = try await SessionDHTRouter.open(host: "::1", metadata: nil)
		let clock = EngineClock(), session = TorrentSession(storage: fixture.root.appendingPathComponent("library"), configuration: plainTransferConfiguration(), loopbackOnly: true, clock: clock, dhtBootstrap: [v4.endpoint, v6.endpoint])
		do {
			var settings = SessionPeerSettings()
			settings.port = try await session.configurePeers(settings)
			for index in 0..<3 {
				var fields = fixture.metadata.document.root.dictionary!, info = fixture.metadata.document.root["info"]!.dictionary!
				info[Data("name".utf8)] = .bytes(Data("bundle\(index)".utf8)); fields[Data("info".utf8)] = .dictionary(info)
				let source = fixture.root.appendingPathComponent("\(index).torrent"); try BencodeValue.dictionary(fields).encoded().write(to: source)
				_ = try await session.add(id: "transfer\(index)", source: source, destination: fixture.root.appendingPathComponent("download\(index)"))
			}
			for index in 0..<3 { try await session.run(id: "transfer\(index)", running: true) }
			settings.dht = true; _ = try await session.configurePeers(settings)
			try await eventually { try await session.snapshot().network.discovery.searches == 4 }
			// All four queries must have reached the routers before taking the baseline.
			try await eventually { let a = await v4.packets.count, b = await v6.packets.count; return a == 2 && b == 2 }
			for _ in 0..<5 { for index in 0..<3 { try await session.run(id: "transfer\(index)", running: true) } }
			_ = try await session.configurePeers(settings)
			#expect(try await session.snapshot().network.discovery.searches == 4)
			#expect(await v4.packets.count == 2); #expect(await v6.packets.count == 2)
			settings.dht = false; _ = try await session.configurePeers(settings)
			#expect(try await !session.snapshot().network.discovery.enabled)
			try await session.close()
		} catch { try? await session.close(); await v4.close(); await v6.close(); await fixture.clean(); throw error }; await v4.close(); await v6.close(); await fixture.clean()
	}
	@Test func pausedPrivateIdentitiesRemainForbiddenBesideRunningPublicTransfers() async throws {
		let fixture = try TransferFixture(), router = try await SessionDHTRouter.open(host: "127.0.0.1", metadata: nil)
		let clock = EngineClock(), session = TorrentSession(storage: fixture.root.appendingPathComponent("library"), configuration: plainTransferConfiguration(), loopbackOnly: true, clock: clock, dhtBootstrap: [router.endpoint])
		let probe = UDPDispatcher(transport: try DatagramSocket(bind: NetworkEndpoint("127.0.0.1", port: 0)))
		do {
			var settings = SessionPeerSettings(); settings.dht = true
			let port = try await session.configurePeers(settings)
			let source = fixture.root.appendingPathComponent("public.torrent"); try fixture.metadata.document.original.write(to: source)
			_ = try await session.add(id: "public", source: source, destination: fixture.root.appendingPathComponent("download")); try await session.run(id: "public", running: true)
			var info = fixture.metadata.document.root["info"]!.dictionary!; info[Data("private".utf8)] = .integer(1)
			let secret = try TorrentMetadata(BencodeValue.dictionary([Data("info".utf8): .dictionary(info)]).encoded())
			let secretURL = fixture.root.appendingPathComponent("private.torrent"); try secret.document.original.write(to: secretURL)
			_ = try await session.add(id: "private", source: secretURL, destination: fixture.root.appendingPathComponent("private-download"))
			for (hash, kind) in [(fixture.metadata.hashes.v1!, "r"), (secret.hashes.v1!, "e")] {
				let transaction = Data(hash.prefix(4))
				let query = try DHTWire.encode(["t": .bytes(transaction), "y": .bytes(Data("q".utf8)), "q": .bytes(Data("get_peers".utf8)), "a": DHTWire.dictionary(["id": .bytes(Data(repeating: 0, count: 20)), "info_hash": .bytes(hash)])])
				let reply = try await probe.exchange(query, with: NetworkEndpoint("127.0.0.1", port: port), reply: .dht(transaction), timeout: 1)
				#expect(try DHTWire.decode(reply.payload)["y"]?.text == kind)
			}
			try await session.close()
			#expect(await router.packets.allSatisfy { (try? BencodeDocument($0.payload).root["a"]?["info_hash"]?.bytes) != secret.hashes.v1 })
		} catch { try? await session.close(); try? await probe.shutdown(); await router.close(); await fixture.clean(); throw error }; try await probe.shutdown(); await router.close(); await fixture.clean()
	}
	@Test(arguments: [1, 2, 3], [false, true]) func sharedPortDiscoveryTransfersWithoutExplicitPeerConnections(_ version: Int, _ utp: Bool) async throws {
		let fixture = try V2Fixture(version: version), host = version == 2 ? "::1" : "127.0.0.1"
		let router = try await SessionDHTRouter.open(host: host, metadata: fixture.metadata)
		let seed = TorrentSession(storage: fixture.root.appendingPathComponent("seed-library"), configuration: plainTransferConfiguration(), loopbackOnly: true, dhtBootstrap: [router.endpoint])
		let down = TorrentSession(storage: fixture.root.appendingPathComponent("down-library"), configuration: plainTransferConfiguration(), loopbackOnly: true, dhtBootstrap: [router.endpoint])
		var phase = "seed setup"
		do {
			var settings = SessionPeerSettings(); settings.dht = true; settings.pex = false; settings.utp = utp; settings.tcp = !utp
			let source = fixture.root.appendingPathComponent("input.torrent"); try fixture.metadata.document.original.write(to: source)
			let seedPort = try await seed.configurePeers(settings)
			_ = try await seed.add(id: "transfer", source: source, destination: fixture.root.appendingPathComponent("source")); try await seed.run(id: "transfer", running: true)
			phase = "seed announcement"
			try await eventually { await router.announces.contains { $0.port == seedPort && $0.source.port == seedPort } }
			let downPort = try await down.configurePeers(settings)
			_ = try await down.add(id: "transfer", source: source, destination: fixture.root.appendingPathComponent("download")); try await down.run(id: "transfer", running: true)
			phase = "download completion"
			try await eventually { try await down.snapshot().transfers[0].state.transfer?.complete == true }
			let snapshot = try await down.snapshot()
			#expect(snapshot.network.discovery.enabled && snapshot.network.discovery.contacts > 0 && snapshot.network.discovery.error.isEmpty)
			#expect(snapshot.transfers[0].state.transfer?.peers.contains { $0.peerID != nil && $0.transport == (utp ? .utp : .tcp) } == true)
			phase = "download announcement"
			try await eventually { await router.announces.contains { $0.port == downPort && $0.source.port == downPort } }
			try await down.shutdown(); #expect(try await down.snapshot().network.discovery.searches == 0)
			try await down.close(); try await seed.close()
			for file in fixture.metadata.inspection.files where !file.pad {
				#expect(try Data(contentsOf: fixture.root.appendingPathComponent("download/" + file.path)) == Data(contentsOf: fixture.root.appendingPathComponent("source/" + file.path)))
			}
		} catch {
			let seedState = try? await seed.snapshot(), downState = try? await down.snapshot()
			let packets = await router.packets
			let queries = packets.compactMap { try? BencodeDocument($0.payload).root["q"]?.text }
			let detail = "DHT v\(version) utp=\(utp) phase=\(phase): \(error); queries=\(queries); seed discovery=\(String(describing: seedState?.network.discovery)) transfer=\(String(describing: seedState?.transfers.first?.state.transfer)); down discovery=\(String(describing: downState?.network.discovery)) transfer=\(String(describing: downState?.transfers.first?.state.transfer))"
			try? await down.close(); try? await seed.close(); await router.close(); await fixture.close()
			throw PeerFailure.invalid(detail)
		}
		await router.close(); await fixture.close()
	}
	@Test func privateMetadataAndEmptySessionsNeverSendDiscoveryTraffic() async throws {
		let fixture = try V2Fixture(version: 3, isPrivate: true), router = try await SessionDHTRouter.open(host: "127.0.0.1", metadata: fixture.metadata)
		let clock = EngineClock(), session = TorrentSession(storage: fixture.root.appendingPathComponent("library"), configuration: plainTransferConfiguration(), loopbackOnly: true, clock: clock, dhtBootstrap: [router.endpoint])
		do {
			var settings = SessionPeerSettings(); settings.dht = true
			_ = try await session.configurePeers(settings)
			#expect(try await session.snapshot().network.discovery.searches == 0)
			let source = fixture.root.appendingPathComponent("private.torrent"); try fixture.metadata.withTrackerTiers([]).write(to: source)
			_ = try await session.add(id: "transfer", source: source, destination: fixture.root.appendingPathComponent("source")); try await session.run(id: "transfer", running: true)
			clock.advance(1800)
			#expect(try await session.snapshot().network.discovery.searches == 0)
			try await session.close(); #expect(await router.packets.isEmpty)
		} catch { try? await session.close(); await router.close(); await fixture.close(); throw error }; await router.close(); await fixture.close()
	}
	@Test func pauseDrainsStalledSearchesAndBlocklistsPreventBootstrapTraffic() async throws {
		let fixture = try TransferFixture(), router = try await SessionDHTRouter.open(host: "127.0.0.1", metadata: nil)
		let clock = EngineClock(), session = TorrentSession(storage: fixture.root.appendingPathComponent("library"), configuration: plainTransferConfiguration(), loopbackOnly: true, clock: clock, dhtBootstrap: [router.endpoint])
		do {
			var settings = SessionPeerSettings(); settings.dht = true
			_ = try await session.configurePeers(settings)
			let source = fixture.root.appendingPathComponent("input.torrent"); try fixture.metadata.document.original.write(to: source)
			_ = try await session.add(id: "transfer", source: source, destination: fixture.root.appendingPathComponent("download")); try await session.run(id: "transfer", running: true)
			try await eventually { await router.packets.count == 1 }
			try await engineDeadline { try await session.pause(id: "transfer") }
			#expect(try await session.snapshot().network.discovery.searches == 0)
			let address = try IPAddress("127.0.0.1")
			try await session.setBlocklist([PeerAddressRange(first: address, last: address)])
			try await session.run(id: "transfer", running: true)
			try await eventually { try await !session.snapshot().network.discovery.error.isEmpty }
			clock.advance(300); try await session.pause(id: "transfer")
			#expect(await router.packets.count == 1)
			try await session.setBlocklist([]); try await session.run(id: "transfer", running: true)
			try await eventually { await router.packets.count == 2 }
			try await engineDeadline { try await session.shutdown() }
			#expect(try await session.snapshot().network.discovery.searches == 0)
			try await engineDeadline { try await session.close() }
		} catch { try? await session.close(); await router.close(); await fixture.clean(); throw error }; await router.close(); await fixture.clean()
	}
}

}

private actor MagnetPeerDelivery {
	var active = 0, cancelled = 0
	var peers: [NetworkEndpoint] = []
	func deliver(_ peers: [NetworkEndpoint]) async {
		self.peers = peers; active += 1; defer { active -= 1 }
		do { try await Task.sleep(for: .seconds(60)) } catch { cancelled += 1 }
	}
}

actor SessionDHTRouter {
	struct Announce { let port: UInt16; let source: NetworkEndpoint }
	let endpoint: NetworkEndpoint
	let udp: UDPDispatcher
	let node: DHTNode?
	let replies: [Data: [NetworkEndpoint]]
	let referral: NetworkEndpoint?
	let announceToken: Data?
	var packets: [NetworkDatagram] = []
	var announces: [Announce] = []
	var pump: Task<Void, Never>?
	init(endpoint: NetworkEndpoint, udp: UDPDispatcher, node: DHTNode?, replies: [Data: [NetworkEndpoint]], referral: NetworkEndpoint?, announceToken: Data?) { self.endpoint = endpoint; self.udp = udp; self.node = node; self.replies = replies; self.referral = referral; self.announceToken = announceToken }
	static func open(host: String, metadata: TorrentMetadata?, replies: [Data: [NetworkEndpoint]] = [:], referral: NetworkEndpoint? = nil, announceToken: Data? = nil) async throws -> SessionDHTRouter {
		let socket = try DatagramSocket(bind: NetworkEndpoint(host, port: 0)), udp = UDPDispatcher(transport: socket)
		let node = try metadata.map { _ in try DHTNode(dispatcher: udp, bootstrap: []) }
		do {
			if let metadata { try await node?.setTorrents([metadata]) }
			let router = SessionDHTRouter(endpoint: socket.localEndpoint, udp: udp, node: node, replies: replies, referral: referral, announceToken: announceToken), incoming = try await udp.subscribe(.raw)
			await router.start(incoming); return router
		} catch { await node?.shutdown(); try? await udp.shutdown(); throw error }
	}
	func start(_ incoming: AsyncStream<NetworkDatagram>) { pump = Task { [weak self] in for await packet in incoming { await self?.receive(packet) } } }
	func receive(_ packet: NetworkDatagram) async {
		packets.append(packet)
		if let root = try? BencodeDocument(packet.payload).root, root["q"]?.text == "announce_peer", let port = root["a"]?["port"]?.integer, let number = UInt16(exactly: port) { announces.append(Announce(port: number, source: packet.source)) }
		guard !replies.isEmpty, let root = try? BencodeDocument(packet.payload).root, root["q"]?.text == "get_peers",
			let hash = root["a"]?["info_hash"]?.bytes, let peers = replies[hash], let transaction = root["t"]?.bytes else { return }
		let values = peers.map { BencodeValue.bytes(DHTWire.compact($0)) }
		var response: [String: BencodeValue] = ["id": .bytes(Data(repeating: 41, count: 20)), "values": .list(values)]
		if let referral { response["nodes"] = .bytes(Data(repeating: 42, count: 20) + DHTWire.compact(referral)) }
		if let announceToken { response["token"] = .bytes(announceToken) }
		if let reply = try? DHTWire.encode(["t": .bytes(transaction), "y": .bytes(Data("r".utf8)), "r": DHTWire.dictionary(response)]) {
			try? await udp.send(reply, to: packet.source)
		}
	}
	func close() async { pump?.cancel(); await pump?.value; pump = nil; await node?.shutdown(); try? await udp.shutdown() }
}
