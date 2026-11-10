import Foundation

final class UTPReadEnd: @unchecked Sendable {
	private let lock = NSLock()
	private var ended = false
	var isEOF: Bool { lock.withLock { ended } }
	func finish() { lock.withLock { ended = true } }
}

/// UTPStream carries an ordered stream through its shared UDP owner.
public final class UTPStream: PeerByteStream, @unchecked Sendable {
	public let remoteEndpoint: NetworkEndpoint?
	public let localEndpoint: NetworkEndpoint
	public let kind = PeerTransportKind.utp
	let id: UUID
	private let owner: UTPTransport
	private let leases: [TCPPeerLease]
	private let end: UTPReadEnd
	private let lock = NSLock()
	private var closed = false, reading = false, writing = false, readEOF = false
	init(owner: UTPTransport, id: UUID, endpoint: NetworkEndpoint, leases: [TCPPeerLease], end: UTPReadEnd) { self.owner = owner; self.id = id; remoteEndpoint = endpoint; localEndpoint = owner.localEndpoint; self.leases = leases; self.end = end }
	public var isClosed: Bool { lock.withLock { closed } }
	public func read(maximumBytes: Int = 65_536, timeout: TimeInterval = 30) async throws -> Data {
		try Task.checkCancellation()
		let eof = try lock.withLock {
			guard !closed else { throw NetworkFailure.closed }; guard !reading else { throw NetworkFailure.busy }; reading = true; return readEOF
		}
		defer { lock.withLock { reading = false } }
		if eof || end.isEOF { return Data() }
		do { let bytes = try await owner.read(id, maximum: maximumBytes, timeout: timeout); if bytes.isEmpty { lock.withLock { readEOF = true } }; return bytes }
		catch { close(); throw error }
	}
	public func write(_ data: Data, timeout: TimeInterval = 30) async throws {
		try Task.checkCancellation()
		try lock.withLock { guard !closed else { throw NetworkFailure.closed }; guard !writing else { throw NetworkFailure.busy }; writing = true }
		defer { lock.withLock { writing = false } }
		do { try await owner.write(id, bytes: data, timeout: timeout) } catch { close(); throw error }
	}
	/// Finishes the send direction after all queued bytes have been acknowledged.
	public func finish(timeout: TimeInterval = 10) async throws { try await owner.finish(id, timeout: timeout) }
	public func close() {
		let first = lock.withLock { if closed { return false }; closed = true; return true }; guard first else { return }
		for lease in leases { lease.release() }; let owner = owner, id = id
		Task { await owner.abort(id) }
	}
	public func shutdown() async throws { close(); await owner.abort(id) }
	deinit { close() }
}
