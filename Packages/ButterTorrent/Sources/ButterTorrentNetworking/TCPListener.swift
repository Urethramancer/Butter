import Foundation
@preconcurrency import Network

/// TCPListener owns its listening port and bounds accepted and queued peer connections.
public final class TCPListener: @unchecked Sendable {
	private let listener: NWListener
	private let queue = DispatchQueue(label: "Butter.TCPListener")
	private let lock = NSLock()
	private let clock: any TransportClock
	private let maximumPeers: Int
	private let budget: TCPPeerBudget
	private let opened = NetworkWaiter<UInt16>()
	private let ended = NetworkWaiter<Void>()
	private var stopped = false
	private var peers: [UUID: TCPStream] = [:]
	private var openingPeers: [UUID: (NWConnection, TCPPeerLease)] = [:]
	private var pending: [TCPStream] = []
	private var accepting: (UUID, NetworkWaiter<TCPStream>)?
	public var port: UInt16 { listener.port?.rawValue ?? 0 }
	public var peerCount: Int { lock.withLock { peers.count + openingPeers.count } }
	private init(port: UInt16, address: IPAddress?, maximumPeers: Int, clock: any TransportClock, budget: TCPPeerBudget?, loopbackOnly: Bool) throws {
		guard (1...10_000).contains(maximumPeers) else { throw NetworkFailure.invalid("peer limit") }
		let parameters = NWParameters.tcp
		parameters.allowLocalEndpointReuse = false
		if loopbackOnly { parameters.requiredInterfaceType = .loopback }
		if let address { parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address.description), port: NWEndpoint.Port(rawValue: port)!) }
		listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
		self.maximumPeers = maximumPeers; self.clock = clock
		self.budget = budget ?? TCPPeerBudget(limit: maximumPeers)
	}
	public static func listen(port: UInt16 = 0, address: IPAddress? = nil, maximumPeers: Int = 200,
		clock: any TransportClock = ContinuousTransportClock(), budget: TCPPeerBudget? = nil, loopbackOnly: Bool = false) async throws -> TCPListener {
		let owner = try TCPListener(port: port, address: address, maximumPeers: maximumPeers, clock: clock, budget: budget, loopbackOnly: loopbackOnly)
		owner.listener.stateUpdateHandler = { [weak owner] state in
			guard let owner else { return }
			switch state {
			case .ready: owner.opened.resolve(.success(owner.port))
			case .failed(let error): owner.opened.resolve(.failure(error)); owner.close()
			case .cancelled: owner.ended.resolve(.success(()))
			default: break
			}
		}
		owner.listener.newConnectionHandler = { [weak owner] connection in owner?.receive(connection) }
		owner.listener.start(queue: owner.queue)
		do { _ = try await owner.opened.value(timeout: 10, clock: clock) }
		catch { owner.close(); throw error }
		return owner
	}
	public func accept(timeout: TimeInterval = 30) async throws -> TCPStream {
		try Task.checkCancellation()
		let id = UUID(), waiter = NetworkWaiter<TCPStream>()
		if let stream = try lock.withLock({ () -> TCPStream? in
			guard !stopped else { throw NetworkFailure.closed }
			guard accepting == nil else { throw NetworkFailure.busy }
			if !pending.isEmpty { return pending.removeFirst() }
			accepting = (id, waiter); return nil
		}) { return stream }
		do { return try await waiter.value(timeout: timeout, clock: clock) }
		catch {
			lock.withLock { if accepting?.0 == id { accepting = nil } }
			throw error
		}
	}
	private func receive(_ connection: NWConnection) {
		let id = UUID()
		let admitted = lock.withLock { () -> TCPPeerLease? in
			guard !stopped, peers.count + openingPeers.count < maximumPeers, let lease = budget.acquire() else { return nil }
			openingPeers[id] = (connection, lease); return lease
		}
		guard let lease = admitted else { connection.cancel(); return }
		Task { [weak self] in
			guard let self else { connection.cancel(); return }
			do {
				let stream = try await TCPStream.accept(connection, clock: clock) { [weak self] in lease.release(); self?.remove(id) }
				let retained = lock.withLock {
					openingPeers[id] = nil
					guard !stopped, !stream.isClosed else { return false }
					peers[id] = stream
					if let (_, waiter) = accepting {
						accepting = nil
						if waiter.resolve(.success(stream)) { return true }
					}
					pending.append(stream); return true
				}
				if !retained { stream.close() }
			} catch { remove(id) }
		}
	}
	private func remove(_ id: UUID) { lock.withLock { peers[id] = nil; openingPeers[id] = nil; pending.removeAll { $0.isClosed } } }
	public func close() {
		let state = lock.withLock { () -> ([TCPStream], NetworkWaiter<TCPStream>?, [(NWConnection, TCPPeerLease)]) in
			stopped = true
			let state = (Array(peers.values), accepting?.1, Array(openingPeers.values))
			accepting = nil; peers.removeAll(); pending.removeAll()
			openingPeers.removeAll()
			return state
		}
		listener.cancel(); opened.resolve(.failure(NetworkFailure.closed)); state.1?.resolve(.failure(NetworkFailure.closed))
		for peer in state.0 { peer.close() }
		for (connection, lease) in state.2 { connection.cancel(); lease.release() }
	}
	public func shutdown() async throws { close(); try await ended.value(timeout: 10, clock: clock) }
	deinit { listener.cancel(); for peer in peers.values { peer.close() } }
}
