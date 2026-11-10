import Foundation
import ButterTorrentMetadata
import ButterTorrentNetworking

public struct SessionPeerSettings: Sendable, Equatable {
	public var port: UInt16 = 0
	public var tcp = true
	public var utp = true
	public var maximumPeers = 300
	public var torrentPeers = 80
	public var pex = true
	public var dht = false
	public var lsd = false
	public var mapping = false
	public var allowSameIP = false
	public init() {}
	func validate() throws {
		guard (1...5000).contains(maximumPeers), (1...1000).contains(torrentPeers) else { throw NetworkFailure.invalid("session peer limits") }
	}
}

public struct SessionNetworkSnapshot: Sendable {
	public let port: UInt16
	public let udp: Bool
	public let error: String
	public let pendingHandshakes: Int
	public let peers: Int
	public let discovery: SessionDHTSnapshot
	public let localDiscovery: Bool
	public let routerMapped: Bool
}

struct SessionPeerTarget: Sendable {
	enum Owner: Sendable {
		case transfer(ManagedTransfer)
		case magnet(SessionMagnetResolver, peerID: Data)

		func matches(_ other: Self) -> Bool {
			switch (self, other) {
			case (.transfer(let a), .transfer(let b)): a === b
			case (.magnet(let a, let first), .magnet(let b, let second)): a === b && first == second
			default: false
			}
		}
	}
	let id: String
	let hashes: [Data]
	let owner: Owner
}

// Listeners and routing jobs share the same hard budget as outgoing transfers.
actor SessionPeerNetwork {
	let listener: ListeningPort
	let utp4: UTPTransport?
	let utp6: UTPTransport?
	private let encryption: PeerEncryptionConfiguration
	private let clock: any TransportClock
	private var filter: PeerAddressFilter
	private var routes: [Data: SessionPeerTarget] = [:]
	private var catalog: PeerSwarmCatalog?
	private var revision = UUID()
	private var pumps: [Task<Void, Never>] = []
	private var opening: [UUID: (any PeerByteStream, Task<Void, Never>)] = [:]
	private var updating = false
	private var closed = false
	private var failure = ""
	private var stopping: Task<Void, Never>?
	private var dht: SessionDHT?
	private var discoveryFailure = ""
	private var localDiscovery: SessionLocalDiscovery?
	private var localDiscoveryFailure = ""
	private var routerMapping: SessionRouterMapping?
	private var mappingRoutes: SessionRouterMapping.Routes?
	private var mappingTCP = false
	private init(listener: ListeningPort, utp4: UTPTransport?, utp6: UTPTransport?, encryption: PeerEncryptionConfiguration, filter: PeerAddressFilter, clock: any TransportClock) {
		self.listener = listener; self.utp4 = utp4; self.utp6 = utp6; self.encryption = encryption; self.clock = clock
		self.filter = filter
	}
	static func open(settings: SessionPeerSettings, budget: TCPPeerBudget, encryption: PeerEncryptionConfiguration, filter: PeerAddressFilter, loopbackOnly: Bool, clock: any TransportClock,
		bootstrap: [NetworkEndpoint]?, localDiscoveryFactory: LocalDiscoveryFactory? = nil, mappingRoutes: SessionRouterMapping.Routes? = nil, connect: @escaping @Sendable (SessionDHTTarget, NetworkEndpoint) async -> Void) async throws -> SessionPeerNetwork {
		try settings.validate()
		let listener = try await ListeningPort.bind(port: settings.port, maximumPeers: settings.maximumPeers, loopbackOnly: loopbackOnly, clock: clock, budget: budget, incomingTCP: settings.tcp)
		var v4: UTPTransport?, v6: UTPTransport?
		do {
			if settings.utp {
				v4 = try await UTPTransport.open(dispatcher: listener.udp4, maximumConnections: min(200, settings.maximumPeers), budget: budget, clock: clock)
				v6 = try await UTPTransport.open(dispatcher: listener.udp6, maximumConnections: min(200, settings.maximumPeers), budget: budget, clock: clock)
			}
			let owner = SessionPeerNetwork(listener: listener, utp4: v4, utp6: v6, encryption: encryption, filter: filter, clock: clock)
			if settings.dht { try await owner.enableDHT(bootstrap: bootstrap ?? (loopbackOnly ? [] : nil), connect: connect) }
			if settings.lsd { await owner.enableLocalDiscovery(factory: localDiscoveryFactory, loopbackOnly: loopbackOnly, connect: connect) }
			if settings.mapping, !loopbackOnly || mappingRoutes != nil {
				await owner.enableMapping(tcp: settings.tcp, routes: mappingRoutes ?? RouterMappingRoute.systemRoutes)
			}
			await owner.start(tcp: settings.tcp); return owner
		} catch { await v4?.shutdown(); await v6?.shutdown(); try? await listener.shutdown(); throw error }
	}
	private func enableMapping(tcp: Bool, routes: @escaping SessionRouterMapping.Routes) async {
		mappingTCP = tcp; mappingRoutes = routes
		await resumeMapping()
	}
	func resumeMapping() async {
		guard !closed, routerMapping == nil, let mappingRoutes else { return }
		let owner = SessionRouterMapping(listener: listener, tcp: mappingTCP, clock: clock, routes: mappingRoutes, filter: filter)
		routerMapping = owner; await owner.start()
	}
	func suspendMapping() async {
		await routerMapping?.shutdown(); routerMapping = nil
	}
	private func enableLocalDiscovery(factory: LocalDiscoveryFactory?, loopbackOnly: Bool, connect: @escaping @Sendable (SessionDHTTarget, NetworkEndpoint) async -> Void) {
		do {
			let services = try factory?(listener.port, clock) ?? SessionLocalDiscovery.interfaces(port: listener.port, clock: clock, loopbackOnly: loopbackOnly)
			guard !services.isEmpty else { throw NetworkFailure.invalid("no multicast interface is available for local discovery") }
			localDiscovery = SessionLocalDiscovery(services: services, clock: clock, connect: connect)
		} catch { localDiscoveryFailure = error.localizedDescription }
	}
	private func enableDHT(bootstrap: [NetworkEndpoint]?, connect: @escaping @Sendable (SessionDHTTarget, NetworkEndpoint) async -> Void) throws {
		dht = try SessionDHT(dispatchers: [listener.udp4, listener.udp6], port: listener.port, bootstrap: bootstrap, filter: filter, clock: clock, connect: connect)
	}
	func updateDiscovery(_ targets: [SessionDHTTarget], metadata: [TorrentMetadata], magnets: [SessionMagnetTarget] = []) async {
		guard !closed else { return }
		if let dht {
			do { try await dht.update(targets, metadata: metadata, magnets: magnets) }
			catch { discoveryFailure = error.localizedDescription; await dht.shutdown(); self.dht = nil }
		}
		if let localDiscovery {
			do { try await localDiscovery.update(targets) }
			catch { localDiscoveryFailure = error.localizedDescription; await localDiscovery.shutdown(); self.localDiscovery = nil }
		}
	}
	func suspendDiscovery() async { await updateDiscovery([], metadata: []) }
	func learnNode(_ endpoint: NetworkEndpoint, for target: SessionDHTTarget) async throws { try await dht?.learnNode(endpoint, for: target) }
	private func start(tcp: Bool) {
		if tcp {
			let listener = listener.tcp
			pumps.append(Task { [weak self] in
				while !Task.isCancelled {
					do { let raw = try await listener.accept(); guard let self else { raw.close(); return }; await self.admit(raw) }
					catch NetworkFailure.timedOut { continue }
					catch { await self?.failed(error); return }
				}
			})
		}
		for owner in [utp4, utp6].compactMap({ $0 }) {
			pumps.append(Task { [weak self] in
				while !Task.isCancelled {
					do { let raw = try await owner.accept(); guard let self else { raw.close(); return }; await self.admit(raw) }
					catch NetworkFailure.timedOut { continue }
					catch { await self?.failed(error); return }
				}
			})
		}
	}
	func setTargets(_ targets: [SessionPeerTarget]) async throws {
		guard !closed else { throw NetworkFailure.closed }
		var next: [Data: SessionPeerTarget] = [:]
		for target in targets {
			for hash in target.hashes {
				guard next[hash] == nil || next[hash]?.id == target.id else { throw PeerFailure.invalid("ambiguous routed swarm") }; next[hash] = target
			}
		}
		if next.count == routes.count, next.allSatisfy({ hash, target in routes[hash]?.id == target.id && routes[hash]?.owner.matches(target.owner) == true }) { return }
		let catalog = next.isEmpty ? nil : try PeerSwarmCatalog(hashes: Array(next.keys))
		updating = true; revision = UUID()
		await drainOpening()
		guard !closed else { updating = false; throw NetworkFailure.closed }
		routes = next; self.catalog = catalog; updating = false
	}
	private func admit(_ raw: any PeerByteStream) {
		guard !closed, !updating, opening.count < 64, let catalog else { raw.close(); return }
		if let address = raw.remoteEndpoint?.address, !filter.allows(address) { raw.close(); return }
		let id = UUID(), revision = revision
		let task = Task { [weak self] in
			guard let self else { raw.close(); return }; await self.route(raw, id: id, catalog: catalog, revision: revision)
		}
		opening[id] = (raw, task)
	}
	private func route(_ raw: any PeerByteStream, id: UUID, catalog: PeerSwarmCatalog, revision: UUID) async {
		defer { opening[id] = nil }
		do {
			let deadline = clock.now() + 10
			let channel = try await PeerStream.accept(raw, catalog: catalog, configuration: encryption, timeout: 10, clock: clock)
			let remaining = deadline - clock.now(); guard remaining > 0 else { throw NetworkFailure.timedOut }
			let bytes = try await channel.peek(count: 68, timeout: remaining, clock: clock)
			var decoder = PeerWireDecoder(); try decoder.feed(bytes)
			guard let hello = try decoder.handshake(), !closed, !updating, revision == self.revision, let target = routes[hello.infoHash] else { throw PeerFailure.invalid("unregistered incoming swarm") }
			if let negotiated = channel.negotiatedInfoHash { guard routes[negotiated]?.id == target.id else { throw PeerFailure.invalid("MSE and peer swarm differ") } }
			try Task.checkCancellation()
			switch target.owner {
			case .transfer(let owner): _ = try await owner.attach(channel)
			case .magnet(let resolver, let peerID): try await resolver.attach(channel, hello: hello, peerID: peerID)
			}
		} catch { try? await raw.shutdown() }
	}
	func transport(for endpoint: NetworkEndpoint) throws -> UTPTransport {
		guard !closed, let transport = endpoint.address.isIPv6 ? utp6 : utp4 else { throw NetworkFailure.closed }; return transport
	}
	func setFilter(_ filter: PeerAddressFilter) async {
		let mapped = routerMapping != nil
		if mapped { await suspendMapping() }
		self.filter = filter; await dht?.setFilter(filter)
		if mapped { await resumeMapping() }
	}
	func trackers(http: any TrackerAnnouncing) throws -> TrackerClient {
		guard !closed else { throw NetworkFailure.closed }
		return TrackerClient(http: http, udp: try UDPTrackerClient(dispatchers: [listener.udp4, listener.udp6], clock: clock, timeout: 10))
	}
	func snapshot() async -> SessionNetworkSnapshot {
		let localError = await localDiscovery?.failure ?? localDiscoveryFailure
		let mappingError = await routerMapping?.error ?? ""
		return SessionNetworkSnapshot(port: closed ? 0 : listener.port, udp: !closed, error: [failure, localError, mappingError].first { !$0.isEmpty } ?? "", pendingHandshakes: opening.count, peers: listener.peers.count,
			discovery: await dht?.snapshot() ?? SessionDHTSnapshot(enabled: false, contacts: 0, searches: 0, error: discoveryFailure), localDiscovery: !closed && localDiscovery != nil,
			routerMapped: await routerMapping?.mapped ?? false)
	}
	private func failed(_ error: Error) {
		guard !closed, !(error is CancellationError) else { return }
		failure = error.localizedDescription; Task { await self.shutdown() }
	}
	private func drainOpening() async {
		let jobs = Array(opening.values)
		for (stream, task) in jobs { task.cancel(); stream.close() }
		for (_, task) in jobs { await task.value }
	}
	func shutdown() async {
		if let stopping { await stopping.value; return }
		let task = Task { await self.finish() }; stopping = task; await task.value
	}
	private func finish() async {
		closed = true; for task in pumps { task.cancel() }
		await drainOpening(); await suspendMapping(); await dht?.shutdown(); await localDiscovery?.shutdown(); await utp4?.shutdown(); await utp6?.shutdown(); try? await listener.shutdown()
		for task in pumps { await task.value }; pumps.removeAll(); routes.removeAll(); catalog = nil
	}
}
