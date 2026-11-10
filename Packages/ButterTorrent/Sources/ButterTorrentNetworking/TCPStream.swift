import Foundation
@preconcurrency import Network
import Security

/// TCPStream is a bounded Network-framework stream. Cancelling I/O closes the stream.
public final class TCPStream: @unchecked Sendable {
	private let connection: NWConnection
	private let queue = DispatchQueue(label: "Butter.TCP")
	private let lock = NSLock()
	private let clock: any TransportClock
	private let onClose: @Sendable () -> Void
	private var closed: Error?
	private var reading = false
	private var writing = false
	private var eof = false
	private var ready = false
	private var callbacks: [UUID: @Sendable (Error) -> Void] = [:]
	private let opened = NetworkWaiter<Void>()
	public var isClosed: Bool { lock.withLock { closed != nil } }
	public var remoteEndpoint: NetworkEndpoint? {
		guard case .hostPort(let host, let port) = connection.endpoint else { return nil }
		return try? NetworkEndpoint(String(describing: host), port: port.rawValue)
	}
	private init(_ connection: NWConnection, clock: any TransportClock, onClose: @escaping @Sendable () -> Void = {}) {
		self.connection = connection; self.clock = clock; self.onClose = onClose
		connection.stateUpdateHandler = { [weak self] state in
			guard let self else { return }
			switch state {
			case .ready: self.lock.withLock { self.ready = true }; self.opened.resolve(.success(()))
			case .failed(let error): self.close(error)
			case .waiting(let error): self.close(error)
			case .cancelled: self.close()
			default: break
			}
		}
	}
	public static func connect(to endpoint: NetworkEndpoint, tlsServerName: String? = nil, timeout: TimeInterval = 10,
		clock: any TransportClock = ContinuousTransportClock(), budget: TCPPeerBudget? = nil) async throws -> TCPStream {
		try Task.checkCancellation()
		guard endpoint.port > 0, !endpoint.address.isUnspecified, !endpoint.address.isMulticast else { throw NetworkFailure.invalid("TCP destination") }
		let tls: NWProtocolTLS.Options?
		if let name = tlsServerName {
			guard !name.isEmpty, name.utf8.count <= 253, !name.utf8.contains(0) else { throw NetworkFailure.invalid("TLS server name") }
			let options = NWProtocolTLS.Options()
			sec_protocol_options_set_tls_server_name(options.securityProtocolOptions, name)
			sec_protocol_options_set_peer_authentication_required(options.securityProtocolOptions, true)
			tls = options
		} else { tls = nil }
		let lease = budget?.acquire()
		guard budget == nil || lease != nil else { throw NetworkFailure.limit("peer connections") }
		let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
		let connection = NWConnection(host: NWEndpoint.Host(endpoint.address.description), port: NWEndpoint.Port(rawValue: endpoint.port)!, using: parameters)
		let stream = TCPStream(connection, clock: clock) { lease?.release() }
		try await stream.start(timeout: timeout)
		return stream
	}
	static func accept(_ connection: NWConnection, clock: any TransportClock, onClose: @escaping @Sendable () -> Void) async throws -> TCPStream {
		let stream = TCPStream(connection, clock: clock, onClose: onClose)
		try await stream.start(timeout: 10)
		return stream
	}
	private func start(timeout: TimeInterval) async throws {
		connection.start(queue: queue)
		do { try await opened.value(timeout: timeout, clock: clock) }
		catch { close(error); throw error }
	}
	public func read(maximumBytes: Int = 65_536, timeout: TimeInterval = 30) async throws -> Data {
		try Task.checkCancellation()
		guard (1...1_048_576).contains(maximumBytes) else { throw NetworkFailure.invalid("TCP read size") }
		let id = UUID(), waiter = NetworkWaiter<Data>()
		let ended = try lock.withLock {
			if let closed { throw closed }
			guard ready, !reading else { throw NetworkFailure.busy }
			if eof { return true }
			reading = true; callbacks[id] = { waiter.resolve(.failure($0)) }
			return false
		}
		if ended { return Data() }
		connection.receive(minimumIncompleteLength: 1, maximumLength: maximumBytes) { [weak self] data, _, complete, error in
			guard let self else { return }
			self.lock.withLock { self.reading = false; self.eof = complete; self.callbacks[id] = nil }
			if let error { waiter.resolve(.failure(error)); self.close(error) }
			else if let data, !data.isEmpty { waiter.resolve(.success(data)) }
			else if complete { waiter.resolve(.success(Data())) }
			else { waiter.resolve(.failure(NetworkFailure.invalid("empty TCP receive"))); self.close() }
		}
		do { return try await waiter.value(timeout: timeout, clock: clock) }
		catch { close(error); throw error }
	}
	public func write(_ data: Data, timeout: TimeInterval = 30) async throws {
		try Task.checkCancellation()
		guard !data.isEmpty, data.count <= 1_048_576 else { throw NetworkFailure.invalid("TCP write size") }
		let id = UUID(), waiter = NetworkWaiter<Void>()
		try lock.withLock {
			if let closed { throw closed }
			guard ready, !writing else { throw NetworkFailure.busy }
			writing = true; callbacks[id] = { waiter.resolve(.failure($0)) }
		}
		connection.send(content: data, completion: .contentProcessed { [weak self] error in
			guard let self else { return }
			self.lock.withLock { self.writing = false; self.callbacks[id] = nil }
			if let error { waiter.resolve(.failure(error)); self.close(error) }
			else { waiter.resolve(.success(())) }
		})
		do { try await waiter.value(timeout: timeout, clock: clock) }
		catch { close(error); throw error }
	}
	public func close() { close(NetworkFailure.closed) }
	private func close(_ error: Error) {
		let pending = lock.withLock { () -> [@Sendable (Error) -> Void]? in
			guard closed == nil else { return nil }
			closed = error
			let pending = Array(callbacks.values); callbacks.removeAll()
			return pending
		}
		guard let pending else { return }
		opened.resolve(.failure(error)); connection.cancel()
		for callback in pending { callback(error) }
		onClose()
	}
	deinit { connection.cancel() }
}
