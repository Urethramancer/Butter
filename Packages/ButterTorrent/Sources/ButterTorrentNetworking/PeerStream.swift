import Foundation
@preconcurrency import Network
import Darwin

/// PeerStream applies negotiated MSE beneath peer framing, with one reader and one writer.
public final class PeerStream: @unchecked Sendable {
	package static func allowsIdentityRetry(after error: Error) -> Bool {
		let resets: [Int32] = [ECONNRESET, ECONNABORTED, EPIPE, ETIMEDOUT]
		if let failure = error as? NetworkFailure {
			switch failure {
			case .closed, .timedOut: return true
			case .system(let code): return resets.contains(code)
			default: return false
			}
		}
		if let failure = error as? NWError, case .posix(let code) = failure { return resets.contains(code.rawValue) }
		return false
	}
	public let raw: any PeerByteStream
	public let mode: PeerEncryptionMode
	public let negotiatedInfoHash: Data?
	private let sendCipher: MSECipher?
	private let receiveCipher: MSECipher?
	private let lock = NSLock()
	private var prefix: Data
	private var reading = false, writing = false
	init(raw: any PeerByteStream, mode: PeerEncryptionMode = .plaintext, prefix: Data = Data(), send: MSECipher? = nil, receive: MSECipher? = nil, negotiatedInfoHash: Data? = nil) {
		self.raw = raw; self.mode = mode; self.prefix = prefix; sendCipher = send; receiveCipher = receive
		self.negotiatedInfoHash = negotiatedInfoHash
	}
	public static func connect(to endpoint: NetworkEndpoint, hash: Data, configuration: PeerEncryptionConfiguration = .init(), timeout: TimeInterval = 10,
		clock: any TransportClock = ContinuousTransportClock(), budget: TCPPeerBudget? = nil, utp: UTPTransport? = nil) async throws -> PeerStream {
		guard timeout.isFinite, (0.1...120).contains(timeout), hash.count == 20 else { throw NetworkFailure.invalid("peer connection configuration") }
		let deadline = clock.now() + timeout
		let open: @Sendable (TimeInterval) async throws -> any PeerByteStream = { remaining in
			if let utp { return try await utp.connect(to: endpoint, timeout: remaining, budget: budget) }
			return try await TCPStream.connect(to: endpoint, timeout: remaining, clock: clock, budget: budget)
		}
		let raw = try await open(timeout)
		if configuration.outgoing == .disabled { return PeerStream(raw: raw) }
		do {
			let remaining = deadline - clock.now(); guard remaining > 0 else { throw NetworkFailure.timedOut }
			let negotiationDeadline = configuration.outgoing == .enabled ? clock.now() + remaining / 2 : deadline
			var handshake = MSEHandshake(stream: raw, clock: clock, deadline: negotiationDeadline, configuration: configuration)
			return try await handshake.initiate(hash: hash)
		} catch {
			try? await raw.shutdown(); try Task.checkCancellation()
			guard configuration.outgoing == .enabled, clock.now() < deadline,
				error as? NetworkFailure != .limit("MSE arithmetic workers") else { throw error }
			// One fresh connection may fall back; required encryption never downgrades.
			let fallback = try await open(deadline - clock.now())
			return PeerStream(raw: fallback)
		}
	}
	public static func accept(_ raw: any PeerByteStream, hashes: [Data], configuration: PeerEncryptionConfiguration = .init(), timeout: TimeInterval = 10,
		clock: any TransportClock = ContinuousTransportClock()) async throws -> PeerStream {
		do { return try await accept(raw, catalog: PeerSwarmCatalog(hashes: hashes), configuration: configuration, timeout: timeout, clock: clock) }
		catch { raw.close(); throw error }
	}
	public static func accept(_ raw: any PeerByteStream, catalog: PeerSwarmCatalog, configuration: PeerEncryptionConfiguration = .init(), timeout: TimeInterval = 10,
		clock: any TransportClock = ContinuousTransportClock()) async throws -> PeerStream {
		guard timeout.isFinite, (0.1...120).contains(timeout) else { raw.close(); throw NetworkFailure.invalid("peer handshake timeout") }
		do { var handshake = MSEHandshake(stream: raw, clock: clock, deadline: clock.now() + timeout, configuration: configuration); return try await handshake.accept(catalog: catalog) }
		catch { raw.close(); throw error }
	}
	/// Peeks a bounded decrypted prefix without consuming framing or advancing the cipher twice.
	public func peek(count: Int, timeout: TimeInterval = 10, clock: any TransportClock = ContinuousTransportClock()) async throws -> Data {
		try Task.checkCancellation()
		guard (1...4096).contains(count), timeout.isFinite, (0.001...120).contains(timeout) else { throw NetworkFailure.invalid("peer prefix") }
		try lock.withLock { guard !reading else { throw NetworkFailure.busy }; reading = true }
		defer { lock.withLock { reading = false } }
		let deadline = clock.now() + timeout
		do {
			while true {
				let buffered = lock.withLock { prefix.count }
				if buffered >= count { return lock.withLock { Data(prefix.prefix(count)) } }
				let remaining = deadline - clock.now(); guard remaining > 0 else { throw NetworkFailure.timedOut }
				let bytes = try await raw.read(maximumBytes: count - buffered, timeout: remaining)
				guard !bytes.isEmpty else { throw NetworkFailure.closed }
				let clear = try receiveCipher?.apply(bytes) ?? bytes; lock.withLock { prefix.append(clear) }
			}
		} catch { close(); throw error }
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
