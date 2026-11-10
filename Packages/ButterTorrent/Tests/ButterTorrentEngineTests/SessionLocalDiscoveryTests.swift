import Foundation
import Testing
import ButterTorrentMetadata
import ButterTorrentNetworking
@testable import ButterTorrentEngine

extension NativeSessionTests { @Suite struct SessionLocalDiscoveryTests {
	@Test func withdrawingATorrentCancelsItsDiscoveredConnectionBeforeReturning() async throws {
		let fixture = try V2Fixture(version: 3), bus = LocalDiscoveryBus(), clock = EngineClock(), probe = LocalConnectionProbe()
		let services = try bus.service(port: 6881, clock: clock)
		let discovery = SessionLocalDiscovery(services: services, clock: clock) { _, _ in await probe.connect() }
		do {
			let owner = try await ManagedTransfer.open(metadata: fixture.metadata, destination: fixture.root.appendingPathComponent("download"), stateDirectory: fixture.root.appendingPathComponent("state"), configuration: plainTransferConfiguration())
			do {
				try await discovery.update([SessionDHTTarget(id: "transfer", metadata: fixture.metadata, owner: owner)])
				try await eventually { !bus.messages.isEmpty }
				let bytes = Data("BT-SEARCH * HTTP/1.1\r\nHost: 239.192.152.143:6771\r\nPort: 7000\r\nInfohash: \(fixture.metadata.hashes.hex[0])\r\ncookie: remote\r\n\r\n\r\n".utf8)
				bus.send(bytes, from: try NetworkEndpoint("127.0.0.1", port: 6771))
				try await eventually { await probe.active == 1 }
				try await discovery.update([])
				#expect(await probe.active == 0)
				#expect(await probe.cancelled == 1)
				try await owner.close()
			} catch { try? await owner.close(); throw error }
			await discovery.shutdown(); #expect(bus.active == 0)
		} catch { await discovery.shutdown(); await fixture.close(); throw error }
		await fixture.close()
	}
	@Test(arguments: [1, 2, 3], [false, true]) func multicastIsTheOnlyPeerSource(_ version: Int, _ utp: Bool) async throws {
		let fixture = try V2Fixture(version: version), bus = LocalDiscoveryBus()
		let factory: LocalDiscoveryFactory = { try bus.service(port: $0, clock: $1) }
		let seed = TorrentSession(storage: fixture.root.appendingPathComponent("seed-library"), configuration: plainTransferConfiguration(), loopbackOnly: true, localDiscoveryFactory: factory)
		let down = TorrentSession(storage: fixture.root.appendingPathComponent("down-library"), configuration: plainTransferConfiguration(), loopbackOnly: true, localDiscoveryFactory: factory)
		do {
			var settings = SessionPeerSettings(); settings.lsd = true; settings.pex = false; settings.utp = utp; settings.tcp = !utp
			let source = fixture.root.appendingPathComponent("input.torrent"); try fixture.metadata.document.original.write(to: source)
			let seedPort = try await seed.configurePeers(settings)
			_ = try await seed.add(id: "transfer", source: source, destination: fixture.root.appendingPathComponent("source")); try await seed.run(id: "transfer", running: true)
			try await eventually { bus.messages.contains { $0.contains("Port: \(seedPort)\r\n") } }
			let downPort = try await down.configurePeers(settings)
			_ = try await down.add(id: "transfer", source: source, destination: fixture.root.appendingPathComponent("download")); try await down.run(id: "transfer", running: true)
			try await eventually { try await down.snapshot().transfers[0].state.transfer?.complete == true }
			let snapshot = try await down.snapshot()
			#expect(snapshot.network.localDiscovery && !snapshot.network.discovery.enabled && snapshot.network.error.isEmpty)
			#expect(snapshot.transfers[0].state.transfer?.peers.contains { $0.transport == (utp ? .utp : .tcp) } == true)
			#expect(bus.messages.contains { $0.contains("Port: \(downPort)\r\n") })
			for hash in fixture.metadata.hashes.hex { #expect(bus.messages.contains { $0.contains(String(hash.prefix(40))) }) }
			try await down.shutdown(); try await down.close(); try await seed.close()
			#expect(bus.active == 0)
			for file in fixture.metadata.inspection.files where !file.pad {
				#expect(try Data(contentsOf: fixture.root.appendingPathComponent("download/" + file.path)) == Data(contentsOf: fixture.root.appendingPathComponent("source/" + file.path)))
			}
		} catch { try? await down.close(); try? await seed.close(); await fixture.close(); throw error }
		await fixture.close()
	}
	@Test func pauseRemovalAndSettingsDrainServicesWithoutPrivateAdvertisements() async throws {
		let fixture = try V2Fixture(version: 3, isPrivate: true), bus = LocalDiscoveryBus(), clock = EngineClock()
		let session = TorrentSession(storage: fixture.root.appendingPathComponent("library"), configuration: plainTransferConfiguration(), loopbackOnly: true, clock: clock, localDiscoveryFactory: { try bus.service(port: $0, clock: $1) })
		do {
			var settings = SessionPeerSettings(); settings.lsd = true
			settings.port = try await session.configurePeers(settings)
			let source = fixture.root.appendingPathComponent("private.torrent"); try fixture.metadata.withTrackerTiers([]).write(to: source)
			_ = try await session.add(id: "private", source: source, destination: fixture.root.appendingPathComponent("download")); try await session.run(id: "private", running: true)
			clock.advance(300)
			#expect(bus.messages.isEmpty)
			#expect(try await session.snapshot().network.localDiscovery)
			_ = try await session.configurePeers(settings); #expect(bus.active == 1)
			try await session.pause(id: "private"); clock.advance(300)
			_ = try await session.remove(id: "private"); #expect(bus.messages.isEmpty)
			settings.lsd = false; _ = try await session.configurePeers(settings)
			#expect(bus.active == 0)
			#expect(try await !session.snapshot().network.localDiscovery)
			try await session.close()
		} catch { try? await session.close(); await fixture.close(); throw error }
		await fixture.close()
	}
	@Test func pausingPublicTorrentsStopsAnnouncementsUntilResumed() async throws {
		let fixture = try V2Fixture(version: 3), bus = LocalDiscoveryBus(), clock = EngineClock()
		let session = TorrentSession(storage: fixture.root.appendingPathComponent("library"), configuration: plainTransferConfiguration(), loopbackOnly: true, clock: clock, localDiscoveryFactory: { try bus.service(port: $0, clock: $1) })
		do {
			var settings = SessionPeerSettings(); settings.lsd = true
			_ = try await session.configurePeers(settings)
			let source = fixture.root.appendingPathComponent("public.torrent"); try fixture.metadata.document.original.write(to: source)
			_ = try await session.add(id: "public", source: source, destination: fixture.root.appendingPathComponent("download")); try await session.run(id: "public", running: true)
			try await eventually { bus.messages.count == 1 }
			try await session.pause(id: "public"); clock.advance(600)
			#expect(bus.messages.count == 1)
			try await session.run(id: "public", running: true)
			try await eventually { bus.messages.count == 2 }
			_ = try await session.remove(id: "public"); clock.advance(600)
			#expect(bus.messages.count == 2)
			try await session.close(); #expect(bus.active == 0)
		} catch { try? await session.close(); await fixture.close(); throw error }
		await fixture.close()
	}
	@Test func unavailableLocalDiscoveryKeepsPeerTransportOperational() async throws {
		let fixture = try TransferFixture()
		let session = TorrentSession(storage: fixture.root.appendingPathComponent("library"), configuration: plainTransferConfiguration(), loopbackOnly: true, localDiscoveryFactory: { _, _ in throw NetworkFailure.system(19) })
		do {
			var settings = SessionPeerSettings(); settings.lsd = true
			let port = try await session.configurePeers(settings), snapshot = try await session.snapshot()
			#expect(port > 0 && snapshot.network.udp && !snapshot.network.localDiscovery && !snapshot.network.error.isEmpty)
			try await session.close()
		} catch { try? await session.close(); await fixture.clean(); throw error }
		await fixture.clean()
	}
} }

private actor LocalConnectionProbe {
	var active = 0, cancelled = 0
	func connect() async {
		active += 1; defer { active -= 1 }
		do { try await Task.sleep(for: .seconds(60)) }
		catch { cancelled += 1 }
	}
}

private final class LocalDiscoveryBus: @unchecked Sendable {
	private let lock = NSLock()
	private var ports: [UUID: LocalDiscoveryPort] = [:]
	private var sent: [String] = []
	var messages: [String] { lock.withLock { sent } }
	var active: Int { lock.withLock { ports.count } }
	func service(port: UInt16, clock: any TransportClock) throws -> [LocalDiscovery] {
		let transport = try LocalDiscoveryPort(bus: self)
		lock.withLock { ports[transport.id] = transport }
		return [try LocalDiscovery(dispatcher: UDPDispatcher(transport: transport, clock: clock), peerPort: port, clock: clock, ownsTransport: true)]
	}
	func send(_ bytes: Data, from source: NetworkEndpoint) {
		let receivers = lock.withLock { sent.append(String(decoding: bytes, as: UTF8.self)); return Array(ports.values) }
		for port in receivers { port.deliver(NetworkDatagram(source: source, payload: bytes)) }
	}
	func remove(_ id: UUID) { _ = lock.withLock { ports.removeValue(forKey: id) } }
}

private final class LocalDiscoveryPort: DatagramTransport, @unchecked Sendable {
	let id = UUID()
	let localEndpoint: NetworkEndpoint
	let datagrams: AsyncStream<NetworkDatagram>
	private let continuation: AsyncStream<NetworkDatagram>.Continuation
	private let bus: LocalDiscoveryBus
	init(bus: LocalDiscoveryBus) throws {
		self.bus = bus; localEndpoint = try NetworkEndpoint("127.0.0.1", port: 6771)
		let pair = AsyncStream<NetworkDatagram>.makeStream(bufferingPolicy: .bufferingNewest(64)); datagrams = pair.stream; continuation = pair.continuation
	}
	func send(_ data: Data, to endpoint: NetworkEndpoint) async throws { try Task.checkCancellation(); bus.send(data, from: localEndpoint) }
	func deliver(_ packet: NetworkDatagram) { continuation.yield(packet) }
	func shutdown() async throws { bus.remove(id); continuation.finish() }
}
