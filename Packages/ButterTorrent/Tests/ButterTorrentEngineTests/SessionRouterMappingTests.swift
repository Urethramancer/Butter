import Foundation
import Testing
import ButterTorrentMetadata
@testable import ButterTorrentNetworking
@testable import ButterTorrentEngine

extension NativeSessionTests { @Suite struct SessionRouterMappingTests {
	@Test(arguments: [false, true]) func mapsOwnedPortAndDrainsBeforeRebindBlocklistAndShutdown(_ fallback: Bool) async throws {
		let fixture = try V2Fixture(version: 1), router = try await MappingRouter.open(fallback: fallback)
		let session = TorrentSession(storage: fixture.root.appendingPathComponent("library"), loopbackOnly: true,
			routerMappingRoutes: { await [router.route()] })
		do {
			var settings = SessionPeerSettings(); settings.pex = false
			_ = try await session.configurePeers(settings)
			#expect(await router.routeReads == 0)
			settings.mapping = true
			let first = try await session.configurePeers(settings)
			try await eventually { try await session.snapshot().network.routerMapped }
			#expect(await router.requests == [Request(.tcp, first), Request(.udp, first)])
			#expect(await router.pcpAttempts == (fallback ? 1 : 2))

			settings.tcp = false
			let rebound = try await session.configurePeers(settings)
			try await eventually { try await session.snapshot().network.routerMapped }
			let afterRebind = [Request(.tcp, first), Request(.udp, first), Request(.tcp, first, removing: true), Request(.udp, first, removing: true), Request(.udp, rebound)]
			#expect(await router.requests == afterRebind)

			let address = router.endpoint.address
			try await session.setBlocklist([PeerAddressRange(first: address, last: address)])
			try await eventually { try await !session.snapshot().network.error.isEmpty }
			let afterBlock = afterRebind + [Request(.udp, rebound, removing: true)]
			#expect(await router.requests == afterBlock)
			#expect(try await session.snapshot().network.port == rebound)
			try await session.setBlocklist([])
			try await eventually { try await session.snapshot().network.routerMapped }
			try await session.shutdown()
			#expect(await router.requests == afterBlock + [Request(.udp, rebound), Request(.udp, rebound, removing: true)])
			#expect(try await !session.snapshot().network.routerMapped)
			#expect(await router.failure == nil)
			try await session.close()
		} catch { try? await session.close(); await router.close(); await fixture.close(); throw error }
		await router.close(); await fixture.close()
	}

	@Test func routeChangeRetiresTheOldGatewayBeforeMappingTheNewOne() async throws {
		let fixture = try V2Fixture(version: 1), clock = EngineClock()
		let first = try await MappingRouter.open(fallback: false), second = try await MappingRouter.open(fallback: true)
		let routes = MappingRoutes(await first.route())
		let session = TorrentSession(storage: fixture.root.appendingPathComponent("library"), loopbackOnly: true, clock: clock, routerMappingRoutes: { await routes.current })
		do {
			var settings = SessionPeerSettings(); settings.mapping = true; settings.tcp = false
			let port = try await session.configurePeers(settings)
			try await eventually { try await session.snapshot().network.routerMapped }
			try await engineDeadline { while try await clock.nextSleep() != 30 {} }
			await routes.set(second.route())
			clock.advance(30)
			try await eventually {
				let mapped = try await session.snapshot().network.routerMapped
				return await second.requests == [Request(.udp, port)] && mapped
			}
			#expect(await first.requests == [Request(.udp, port), Request(.udp, port, removing: true)])
			try await session.close()
			#expect(await second.requests == [Request(.udp, port), Request(.udp, port, removing: true)])
		} catch { try? await session.close(); await first.close(); await second.close(); await fixture.close(); throw error }
		await first.close(); await second.close(); await fixture.close()
	}
} }

private actor MappingRoutes {
	private(set) var current: [RouterMappingRoute]
	init(_ route: RouterMappingRoute) { current = [route] }
	func set(_ route: RouterMappingRoute) { current = [route] }
}

private struct Request: Equatable {
	let kind: MappedTransport
	let port: UInt16
	let removing: Bool
	init(_ kind: MappedTransport, _ port: UInt16, removing: Bool = false) { self.kind = kind; self.port = port; self.removing = removing }
}

private actor MappingRouter {
	let socket: DatagramSocket
	nonisolated let endpoint: NetworkEndpoint
	let fallback: Bool
	private var pump: Task<Void, Never>?
	private(set) var routeReads = 0, pcpAttempts = 0
	private(set) var requests: [Request] = []
	private(set) var failure: String?
	init(socket: DatagramSocket, fallback: Bool) { self.socket = socket; endpoint = socket.localEndpoint; self.fallback = fallback }
	static func open(fallback: Bool) async throws -> MappingRouter {
		let router = MappingRouter(socket: try DatagramSocket(bind: NetworkEndpoint("127.0.0.1", port: 0)), fallback: fallback)
		await router.start(); return router
	}
	func route() -> RouterMappingRoute {
		routeReads += 1
		return RouterMappingRoute(gateway: endpoint, source: endpoint.address)
	}
	private func start() {
		pump = Task { [weak self, socket] in for await packet in socket.datagrams { await self?.reply(to: packet) } }
	}
	private func reply(to packet: NetworkDatagram) async {
		do {
			let bytes = packet.payload
			if bytes.count == 60, bytes.prefix(2) == Data([2, 1]) {
				pcpAttempts += 1
				if fallback { try await socket.send(Data([0, 129, 0, 1, 0, 0, 0, 0]), to: packet.source); return }
				let port = try PacketBytes.uint16(bytes, at: 40), lifetime = try PacketBytes.uint32(bytes, at: 4)
				let kind: MappedTransport = bytes[36] == 6 ? .tcp : .udp
				guard try IPAddress(bytes: bytes.subdata(in: 8..<24)) == packet.source.address else { throw NetworkFailure.invalid("fixture PCP source address") }
				requests.append(Request(kind, port, removing: lifetime == 0))
				var response = Data([2, 129, 0, 0]); PacketBytes.append(lifetime, to: &response); PacketBytes.append(UInt32(100), to: &response)
				response.append(Data(repeating: 0, count: 12)); response.append(bytes[24..<42]); PacketBytes.append(port, to: &response)
				response.append(Data(repeating: 0, count: 10) + Data([255, 255, 198, 51, 100, 2]))
				try await socket.send(response, to: packet.source)
			} else if fallback, bytes.count == 12, bytes[0] == 0, (1...2).contains(bytes[1]) {
				let port = try PacketBytes.uint16(bytes, at: 4), lifetime = try PacketBytes.uint32(bytes, at: 8)
				requests.append(Request(bytes[1] == 2 ? .tcp : .udp, port, removing: lifetime == 0))
				var response = Data([0, bytes[1] | 128, 0, 0]); PacketBytes.append(UInt32(100), to: &response)
				PacketBytes.append(port, to: &response); PacketBytes.append(lifetime == 0 ? 0 : port, to: &response); PacketBytes.append(lifetime, to: &response)
				try await socket.send(response, to: packet.source)
			} else { throw NetworkFailure.invalid("fixture mapping request") }
		} catch { failure = error.localizedDescription }
	}
	func close() async { pump?.cancel(); socket.close(); await pump?.value }
}
