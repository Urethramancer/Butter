import Foundation
import ButterTorrentNetworking

public struct SessionPeerSettings: Sendable, Equatable {
	public var port: UInt16 = 0
	public var tcp = true
	public var utp = true
	public var maximumPeers = 300
	public var torrentPeers = 80
	public var pex = true
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
}

struct SessionPeerTarget: Sendable {
	let id: String
	let hashes: [Data]
	let owner: ManagedTransfer
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
	private init(listener: ListeningPort, utp4: UTPTransport?, utp6: UTPTransport?, encryption: PeerEncryptionConfiguration, filter: PeerAddressFilter, clock: any TransportClock) {
		self.listener = listener; self.utp4 = utp4; self.utp6 = utp6; self.encryption = encryption; self.clock = clock
		self.filter = filter
	}
	static func open(settings: SessionPeerSettings, budget: TCPPeerBudget, encryption: PeerEncryptionConfiguration, filter: PeerAddressFilter, loopbackOnly: Bool, clock: any TransportClock) async throws -> SessionPeerNetwork {
		try settings.validate()
		let listener = try await ListeningPort.bind(port: settings.port, maximumPeers: settings.maximumPeers, loopbackOnly: loopbackOnly, clock: clock, budget: budget, incomingTCP: settings.tcp)
		var v4: UTPTransport?, v6: UTPTransport?
		do {
			if settings.utp {
				v4 = try await UTPTransport.open(dispatcher: listener.udp4, maximumConnections: min(200, settings.maximumPeers), budget: budget, clock: clock)
				v6 = try await UTPTransport.open(dispatcher: listener.udp6, maximumConnections: min(200, settings.maximumPeers), budget: budget, clock: clock)
			}
			let owner = SessionPeerNetwork(listener: listener, utp4: v4, utp6: v6, encryption: encryption, filter: filter, clock: clock)
			await owner.start(tcp: settings.tcp); return owner
		} catch { await v4?.shutdown(); await v6?.shutdown(); try? await listener.shutdown(); throw error }
	}
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
		if next.count == routes.count, next.allSatisfy({ hash, target in routes[hash]?.id == target.id && routes[hash]?.owner === target.owner }) { return }
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
			try Task.checkCancellation(); _ = try await target.owner.attach(channel)
		} catch { try? await raw.shutdown() }
	}
	func transport(for endpoint: NetworkEndpoint) throws -> UTPTransport {
		guard !closed, let transport = endpoint.address.isIPv6 ? utp6 : utp4 else { throw NetworkFailure.closed }; return transport
	}
	func setFilter(_ filter: PeerAddressFilter) { self.filter = filter }
	func snapshot() -> SessionNetworkSnapshot {
		SessionNetworkSnapshot(port: closed ? 0 : listener.port, udp: !closed, error: failure, pendingHandshakes: opening.count, peers: listener.peers.count)
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
		await drainOpening(); await utp4?.shutdown(); await utp6?.shutdown(); try? await listener.shutdown()
		for task in pumps { await task.value }; pumps.removeAll(); routes.removeAll(); catalog = nil
	}
}
