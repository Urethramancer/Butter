import Foundation

public enum PeerEncryptionPolicy: Sendable { case disabled, enabled, required }
public enum PeerEncryptionLevel: UInt32, Sendable { case plaintext = 1, rc4 = 2, both = 3 }
public enum PeerEncryptionMode: Sendable { case plaintext, negotiatedPlaintext, rc4 }
public struct PeerEncryptionConfiguration: Sendable {
	public var incoming: PeerEncryptionPolicy
	public var outgoing: PeerEncryptionPolicy
	public var levels: PeerEncryptionLevel
	public var preferRC4: Bool
	public init(incoming: PeerEncryptionPolicy = .enabled, outgoing: PeerEncryptionPolicy = .enabled,
		levels: PeerEncryptionLevel = .both, preferRC4: Bool = false) {
		self.incoming = incoming; self.outgoing = outgoing; self.levels = levels; self.preferRC4 = preferRC4
	}
	public static let disabled = Self(incoming: .disabled, outgoing: .disabled)
}

struct MSEHandshake {
	let stream: TCPStream
	let clock: any TransportClock
	let deadline: TimeInterval
	let configuration: PeerEncryptionConfiguration
	var buffer = Data()
	// Tests can force all four padding fields to their maximum without changing production entropy.
	var paddingLength: Int?
	var fragmentBytes: Int?
	func write(_ data: Data) async throws {
		let size = fragmentBytes ?? data.count
		for start in stride(from: 0, to: data.count, by: size) { try await stream.write(data.subdata(in: start..<min(start + size, data.count)), timeout: remaining()) }
	}
	func padding() throws -> Data { try mseRandom(paddingLength ?? Int.random(in: 0...512)) }
	func remaining() throws -> TimeInterval {
		try Task.checkCancellation(); let value = deadline - clock.now(); guard value > 0 else { throw NetworkFailure.timedOut }; return value
	}
	mutating func take(_ count: Int) async throws -> Data {
		guard (0...65_535).contains(count) else { throw NetworkFailure.limit("MSE field") }
		while buffer.count < count {
			let data = try await stream.read(maximumBytes: min(65_536, max(64, count - buffer.count)), timeout: remaining())
			guard !data.isEmpty else { throw NetworkFailure.closed }; buffer.append(data)
		}
		let data = Data(buffer.prefix(count)); buffer = Data(buffer.dropFirst(count)); return data
	}
	mutating func synchronise(_ pattern: Data) async throws {
		while true {
			if let range = buffer.range(of: pattern) {
				guard range.lowerBound <= 512 else { throw NetworkFailure.invalid("MSE padding limit") }
				buffer = Data(buffer[range.upperBound...]); return
			}
			guard buffer.count < 512 + pattern.count else { throw NetworkFailure.invalid("MSE synchronisation") }
			let data = try await stream.read(maximumBytes: min(64, 512 + pattern.count - buffer.count), timeout: remaining())
			guard !data.isEmpty else { throw NetworkFailure.closed }; buffer.append(data)
		}
	}
	func keyPair() async throws -> MSEKeyPair {
		let secret = try mseRandom(20)
		return try await MSEWorkers.shared.run { try MSEKeyPair(secret: secret) }
	}
	func shared(_ pair: MSEKeyPair, remote: Data) async throws -> Data {
		try await MSEWorkers.shared.run { try pair.shared(remote) }
	}
	func ciphers(secret: Data, hash: Data, outgoing: Bool) throws -> (MSECipher, MSECipher) {
		let a = try MSECipher(key: mseHash("keyA", secret, hash)), b = try MSECipher(key: mseHash("keyB", secret, hash))
		return outgoing ? (a, b) : (b, a)
	}
	func control(_ method: UInt32, padding: Data, initial: Data? = nil) -> Data {
		var data = Data(repeating: 0, count: 8); PacketBytes.append(method, to: &data); PacketBytes.append(UInt16(padding.count), to: &data); data.append(padding)
		if let initial { PacketBytes.append(UInt16(initial.count), to: &data); data.append(initial) }; return data
	}
	mutating func initiate(hash: Data, initial: Data = Data()) async throws -> PeerStream {
		guard hash.count == 20, initial.count <= 65_535 else { throw NetworkFailure.invalid("MSE swarm or initial payload") }
		let pair = try await keyPair()
		try await write(pair.publicKey + padding())
		let remote = try await take(96), secret = try await shared(pair, remote: remote)
		let (send, receive) = try ciphers(secret: secret, hash: hash, outgoing: true)
		let keyHash = mseHash("req2", hash), mask = mseHash("req3", secret)
		let request = mseHash("req1", secret) + Data(zip(keyHash, mask).map { $0 ^ $1 })
		try await write(request + send.apply(control(configuration.levels.rawValue, padding: padding(), initial: initial)))
		let verification = try receive.apply(Data(repeating: 0, count: 8))
		try await synchronise(verification)
		let header = try receive.apply(await take(6)), method = try PacketBytes.uint32(header, at: 0), length = Int(try PacketBytes.uint16(header, at: 4))
		guard (method == 1 || method == 2), method & configuration.levels.rawValue != 0, length <= 512 else { throw NetworkFailure.invalid("MSE selection or padding") }
		_ = try receive.apply(await take(length))
		return try finish(method: method, send: send, receive: receive)
	}
	mutating func accept(hashes: [Data]) async throws -> PeerStream {
		guard (1...2).contains(hashes.count), hashes.allSatisfy({ $0.count == 20 }) else { throw NetworkFailure.invalid("MSE swarm candidates") }
		let prefix = try await take(20)
		if prefix == Data([19]) + Data("BitTorrent protocol".utf8) {
			guard configuration.incoming != .required else { throw NetworkFailure.invalid("encryption required") }
			return PeerStream(raw: stream, prefix: prefix + buffer)
		}
		guard configuration.incoming != .disabled else { throw NetworkFailure.invalid("encryption disabled") }
		let remote = try await prefix + take(76)
		let value = MSEInteger(remote)
		guard !value.less(MSEInteger(2)), value.less(MSEInteger.prime.subtract(MSEInteger(1))) else { throw NetworkFailure.invalid("MSE public key range") }
		let pair = try await keyPair(), secret = try await shared(pair, remote: remote)
		try await write(pair.publicKey + padding())
		try await synchronise(mseHash("req1", secret))
		let obfuscated = try await take(20), mask = mseHash("req3", secret), requested = Data(zip(obfuscated, mask).map { $0 ^ $1 })
		guard let hash = hashes.first(where: { mseHash("req2", $0) == requested }) else { throw NetworkFailure.invalid("MSE unknown swarm") }
		let (send, receive) = try ciphers(secret: secret, hash: hash, outgoing: false)
		let header = try receive.apply(await take(14))
		guard header.prefix(8).allSatisfy({ $0 == 0 }) else { throw NetworkFailure.invalid("MSE verification constant") }
		let offered = try PacketBytes.uint32(header, at: 8) & configuration.levels.rawValue, length = Int(try PacketBytes.uint16(header, at: 12))
		guard offered != 0, length <= 512 else { throw NetworkFailure.invalid("MSE methods or padding") }
		let method: UInt32 = configuration.preferRC4 && offered & 2 != 0 ? 2 : offered & 1 != 0 ? 1 : 2
		let padding = try receive.apply(await take(length + 2)), initialLength = Int(try PacketBytes.uint16(padding, at: length))
		let initial = try receive.apply(await take(initialLength))
		try await write(send.apply(control(method, padding: self.padding())))
		return try finish(method: method, send: send, receive: receive, initial: initial)
	}
	func finish(method: UInt32, send: MSECipher, receive: MSECipher, initial: Data = Data()) throws -> PeerStream {
		let encrypted = method == 2
		let tail = encrypted ? try receive.apply(buffer) : buffer
		return PeerStream(raw: stream, mode: encrypted ? .rc4 : .negotiatedPlaintext, prefix: initial + tail, send: encrypted ? send : nil, receive: encrypted ? receive : nil)
	}
}
