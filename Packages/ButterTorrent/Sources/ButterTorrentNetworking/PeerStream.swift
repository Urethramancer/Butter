import Foundation

/// PeerStream applies negotiated MSE beneath peer framing, with one reader and one writer.
public final class PeerStream: @unchecked Sendable {
	public let raw: TCPStream
	public let mode: PeerEncryptionMode
	private let sendCipher: MSECipher?
	private let receiveCipher: MSECipher?
	private let lock = NSLock()
	private var prefix: Data
	private var reading = false, writing = false
	init(raw: TCPStream, mode: PeerEncryptionMode = .plaintext, prefix: Data = Data(), send: MSECipher? = nil, receive: MSECipher? = nil) {
		self.raw = raw; self.mode = mode; self.prefix = prefix; sendCipher = send; receiveCipher = receive
	}
	public static func connect(to endpoint: NetworkEndpoint, hash: Data, configuration: PeerEncryptionConfiguration = .init(), timeout: TimeInterval = 10,
		clock: any TransportClock = ContinuousTransportClock(), budget: TCPPeerBudget? = nil) async throws -> PeerStream {
		guard timeout.isFinite, (0.1...120).contains(timeout), hash.count == 20 else { throw NetworkFailure.invalid("peer connection configuration") }
		let deadline = clock.now() + timeout
		let raw = try await TCPStream.connect(to: endpoint, timeout: timeout, clock: clock, budget: budget)
		if configuration.outgoing == .disabled { return PeerStream(raw: raw) }
		do {
			var handshake = MSEHandshake(stream: raw, clock: clock, deadline: deadline, configuration: configuration)
			return try await handshake.initiate(hash: hash)
		} catch {
			raw.close(); try Task.checkCancellation()
			guard configuration.outgoing == .enabled, clock.now() < deadline,
				error as? NetworkFailure != .limit("MSE arithmetic workers") else { throw error }
			// One fresh connection may fall back; required encryption never downgrades.
			let fallback = try await TCPStream.connect(to: endpoint, timeout: max(0.1, deadline - clock.now()), clock: clock, budget: budget)
			return PeerStream(raw: fallback)
		}
	}
	public static func accept(_ raw: TCPStream, hashes: [Data], configuration: PeerEncryptionConfiguration = .init(), timeout: TimeInterval = 10,
		clock: any TransportClock = ContinuousTransportClock()) async throws -> PeerStream {
		guard timeout.isFinite, (0.1...120).contains(timeout) else { raw.close(); throw NetworkFailure.invalid("peer handshake timeout") }
		do { var handshake = MSEHandshake(stream: raw, clock: clock, deadline: clock.now() + timeout, configuration: configuration); return try await handshake.accept(hashes: hashes) }
		catch { raw.close(); throw error }
	}
	public func read(maximumBytes: Int = 65_536, timeout: TimeInterval = 30) async throws -> Data {
		try Task.checkCancellation(); guard (1...1_048_576).contains(maximumBytes) else { throw NetworkFailure.invalid("peer read size") }
		let buffered = try lock.withLock {
			guard !reading else { throw NetworkFailure.busy }; reading = true
			let result = Data(prefix.prefix(maximumBytes)); prefix = Data(prefix.dropFirst(result.count)); return result
		}
		defer { lock.withLock { reading = false } }
		if !buffered.isEmpty { return buffered }
		do { let bytes = try await raw.read(maximumBytes: maximumBytes, timeout: timeout); return try receiveCipher?.apply(bytes) ?? bytes }
		catch { close(); throw error }
	}
	public func write(_ data: Data, timeout: TimeInterval = 30) async throws {
		try Task.checkCancellation()
		guard !data.isEmpty, data.count <= 1_048_576 else { throw NetworkFailure.invalid("peer write size") }
		try lock.withLock { guard !writing else { throw NetworkFailure.busy }; writing = true }
		defer { lock.withLock { writing = false } }
		do { try await raw.write(sendCipher?.apply(data) ?? data, timeout: timeout) } catch { close(); throw error }
	}
	public func close() { raw.close(); lock.withLock { prefix.removeAll() } }
}
