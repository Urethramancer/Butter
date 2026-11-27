import Foundation
import ButterTorrentMetadata

public struct PeerFeatures: Sendable {
	public var fast = false
	public var extended = false
	public var v2 = false
	public var dht = false
	public init() {}
}

public enum PeerFailure: Error, LocalizedError, Equatable, Sendable {
	case invalid(String), limit(String), closed, corruptPiece(Int)
	public var errorDescription: String? {
		switch self {
		case .invalid(let text): "Invalid peer protocol: \(text)."
		case .limit(let text): "Peer exceeded the \(text) limit."
		case .closed: "The transfer is closed."
		case .corruptPiece(let piece): "A peer supplied corrupt piece \(piece)."
		}
	}
}

public struct PeerBlock: Hashable, Sendable {
	public let piece: Int
	public let offset: Int
	public let length: Int
	public init(piece: Int, offset: Int, length: Int) { self.piece = piece; self.offset = offset; self.length = length }
}
public struct PeerHandshake: Equatable, Sendable {
	public let reserved: Data
	public let infoHash: Data
	public let peerID: Data
	public init(infoHash: Data, peerID: Data, reserved: Data = Data(repeating: 0, count: 8)) throws {
		guard infoHash.count == 20, peerID.count == 20, reserved.count == 8 else { throw PeerFailure.invalid("handshake fields") }
		self.infoHash = infoHash; self.peerID = peerID; self.reserved = reserved
	}
	public var encoded: Data { Data([19]) + Data("BitTorrent protocol".utf8) + reserved + infoHash + peerID }
}
public enum PeerMessage: Equatable, Sendable {
	case keepAlive, choke, unchoke, interested, notInterested
	case have(Int), bitfield(Data), request(PeerBlock), cancel(PeerBlock), piece(Int, Int, Data)
	case haveAll, haveNone, suggest(Int), allowedFast(Int), reject(PeerBlock), port(Int)
	case extended(Int, Data), hashRequest(MerkleHashRequest), hashes(MerkleHashRequest, Data), hashReject(MerkleHashRequest)
	public func encoded() throws -> Data {
		var body = Data()
		switch self {
		case .keepAlive: break
		case .choke: body.append(0)
		case .unchoke: body.append(1)
		case .interested: body.append(2)
		case .notInterested: body.append(3)
		case .have(let index): body.append(4); try PeerBytes.append(index, to: &body)
		case .bitfield(let bits):
			guard bits.count <= 50_000 else { throw PeerFailure.limit("bitfield bytes") }; body.append(5); body.append(bits)
		case .request(let block), .cancel(let block), .reject(let block):
			guard (1...16384).contains(block.length) else { throw PeerFailure.invalid("request length") }
			if case .request = self { body.append(6) } else if case .cancel = self { body.append(8) } else { body.append(16) }
			for value in [block.piece, block.offset, block.length] { try PeerBytes.append(value, to: &body) }
		case .piece(let index, let offset, let bytes):
			guard (1...16384).contains(bytes.count) else { throw PeerFailure.invalid("piece block size") }
			var result = Data(capacity: bytes.count + 13)
			try Self.appendPiece(index, offset, bytes, to: &result); return result
		case .haveAll: body.append(14)
		case .haveNone: body.append(15)
		case .suggest(let index), .allowedFast(let index):
			if case .suggest = self { body.append(13) } else { body.append(17) }; try PeerBytes.append(index, to: &body)
		case .port(let port):
			guard (1...65535).contains(port) else { throw PeerFailure.invalid("DHT port") }; body.append(9); body.append(UInt8(port >> 8)); body.append(UInt8(port & 255))
		case .extended(let id, let bytes):
			guard (0...255).contains(id), bytes.count <= 65_534 else { throw PeerFailure.limit("extension payload") }; body.append(20); body.append(UInt8(id)); body.append(bytes)
		case .hashRequest(let request), .hashReject(let request), .hashes(let request, _):
			guard request.root.count == 32, (0...40).contains(request.base), (0...40).contains(request.proofLayers),
				(2...512).contains(request.count), request.count.nonzeroBitCount == 1, request.index >= 0, request.index % request.count == 0 else { throw PeerFailure.invalid("hash request fields") }
			if case .hashRequest = self { body.append(21) } else if case .hashReject = self { body.append(23) } else { body.append(22) }
			body.append(request.root); for value in [request.base, request.index, request.count, request.proofLayers] { try PeerBytes.append(value, to: &body) }
			if case .hashes(_, let hashes) = self {
				guard hashes.count == (request.count + request.proofCount) * 32 else { throw PeerFailure.invalid("hash response length") }; body.append(hashes)
			}
		}
		var result = Data(); try PeerBytes.append(body.count, to: &result); result.append(body); return result
	}
	static func appendRequest(_ block: PeerBlock, to result: inout Data) throws {
		guard (1...16384).contains(block.length) else { throw PeerFailure.invalid("request length") }
		try PeerBytes.append(13, to: &result); result.append(6)
		try PeerBytes.append(block.piece, to: &result); try PeerBytes.append(block.offset, to: &result)
		try PeerBytes.append(block.length, to: &result)
	}
	static func appendPiece(_ index: Int, _ offset: Int, _ bytes: Data, to result: inout Data) throws {
		guard (1...16384).contains(bytes.count) else { throw PeerFailure.invalid("piece block size") }
		try PeerBytes.append(bytes.count + 9, to: &result); result.append(7)
		try PeerBytes.append(index, to: &result); try PeerBytes.append(offset, to: &result)
		result.append(bytes)
	}
}

enum PeerBytes {
	static func append(_ value: Int, to data: inout Data) throws {
		guard let number = UInt32(exactly: value) else { throw PeerFailure.invalid("wire integer") }
		var encoded = number.bigEndian; withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
	}
	static func write(_ value: Int, to base: UnsafeMutablePointer<UInt8>) throws {
		guard let number = UInt32(exactly: value) else { throw PeerFailure.invalid("wire integer") }
		let encoded = number.bigEndian
		base[0] = UInt8(truncatingIfNeeded: encoded)
		base[1] = UInt8(truncatingIfNeeded: encoded >> 8)
		base[2] = UInt8(truncatingIfNeeded: encoded >> 16)
		base[3] = UInt8(truncatingIfNeeded: encoded >> 24)
	}
	static func integer(_ data: Data, at offset: Int) throws -> Int {
		guard offset >= 0, offset <= data.count - 4 else { throw PeerFailure.invalid("truncated integer") }
		return data.withUnsafeBytes { raw in
			let b0 = UInt32(raw[offset]) << 24
			let b1 = UInt32(raw[offset + 1]) << 16
			let b2 = UInt32(raw[offset + 2]) << 8
			let b3 = UInt32(raw[offset + 3])
			return Int(b0 | b1 | b2 | b3)
		}
	}
}

/// PeerWireDecoder accepts fragmented/coalesced messages with a fixed buffering bound.
public struct PeerWireDecoder: Sendable {
	private var bytes = Data()
	private var offset = 0
	private var handshaken = false
	private var features = PeerFeatures()
	public init() {}
	public mutating func negotiate(_ features: PeerFeatures) { self.features = features }
	public mutating func feed(_ data: Data) throws {
		// Retain one maximum frame, including its four-byte prefix, plus one read.
		let remaining = bytes.count - offset
		guard data.count <= 65_536, remaining <= 131_076 - data.count else { throw PeerFailure.limit("wire buffer") }
		if offset > 0 {
			if remaining == 0 {
				bytes.removeAll(keepingCapacity: true)
			} else {
				bytes.withUnsafeMutableBytes { raw in
					if let base = raw.baseAddress { memmove(base, base.advanced(by: offset), remaining) }
				}
				bytes.count = remaining
			}
			offset = 0
		}
		bytes.append(data)
	}
	public mutating func handshake() throws -> PeerHandshake? {
		guard !handshaken else { throw PeerFailure.invalid("repeated handshake") }
		if bytes.count > offset, bytes[offset] != 19 { throw PeerFailure.invalid("protocol name length") }
		guard bytes.count - offset >= 68 else { return nil }
		let data = bytes.subdata(in: offset..<(offset + 68))
		guard data[1..<20] == Data("BitTorrent protocol".utf8) else { throw PeerFailure.invalid("protocol name") }
		offset += 68; handshaken = true
		return try PeerHandshake(infoHash: data.subdata(in: 28..<48), peerID: data.subdata(in: 48..<68), reserved: data.subdata(in: 20..<28))
	}
	public mutating func next() throws -> PeerMessage? {
		guard handshaken else { throw PeerFailure.invalid("message before handshake") }
		guard bytes.count - offset >= 4 else { return nil }
		let size = try PeerBytes.integer(bytes, at: offset)
		guard size <= 65_536 else { throw PeerFailure.limit("message length") }
		guard bytes.count - offset - 4 >= size else { return nil }
		offset += 4
		if size == 0 { return .keepAlive }
		let base = offset
		offset += size
		let id = bytes[base]
		switch id {
		case 0...3:
			guard size == 1 else { throw PeerFailure.invalid("control message length") }
			switch id {
			case 0: return .choke
			case 1: return .unchoke
			case 2: return .interested
			default: return .notInterested
			}
		case 4:
			guard size == 5 else { throw PeerFailure.invalid("have length") }; return .have(try PeerBytes.integer(bytes, at: base + 1))
		case 5:
			guard size <= 50_001 else { throw PeerFailure.limit("bitfield bytes") }; return .bitfield(bytes.subdata(in: (base + 1)..<(base + size)))
		case 6, 8, 16:
			if id == 16, !features.fast && !features.v2 { throw PeerFailure.invalid("unnegotiated rejection") }
			guard size == 13 else { throw PeerFailure.invalid("request/cancel length") }
			let block = PeerBlock(piece: try PeerBytes.integer(bytes, at: base + 1), offset: try PeerBytes.integer(bytes, at: base + 5), length: try PeerBytes.integer(bytes, at: base + 9))
			guard (1...16384).contains(block.length) else { throw PeerFailure.invalid("request length") }
			return id == 6 ? .request(block) : id == 8 ? .cancel(block) : .reject(block)
		case 7:
			guard (10...16393).contains(size) else { throw PeerFailure.invalid("piece length") }
			return .piece(try PeerBytes.integer(bytes, at: base + 1), try PeerBytes.integer(bytes, at: base + 5), bytes.subdata(in: (base + 9)..<(base + size)))
		case 9:
			guard features.dht, size == 3 else { throw PeerFailure.invalid("unnegotiated DHT port") }; return .port(Int(bytes[base + 1]) * 256 + Int(bytes[base + 2]))
		case 13...17:
			guard features.fast else { throw PeerFailure.invalid("unnegotiated Fast message") }
			if id == 14 || id == 15 { guard size == 1 else { throw PeerFailure.invalid("Fast availability length") }; return id == 14 ? .haveAll : .haveNone }
			guard size == 5 else { throw PeerFailure.invalid("Fast index length") }
			return id == 13 ? .suggest(try PeerBytes.integer(bytes, at: base + 1)) : .allowedFast(try PeerBytes.integer(bytes, at: base + 1))
		case 20:
			guard features.extended, size >= 2 else { throw PeerFailure.invalid("unnegotiated extension") }; return .extended(Int(bytes[base + 1]), bytes.subdata(in: (base + 2)..<(base + size)))
		case 21...23:
			guard features.v2, size >= 49 else { throw PeerFailure.invalid("unnegotiated hash message") }
			let request = MerkleHashRequest(root: bytes.subdata(in: (base + 1)..<(base + 33)), base: try PeerBytes.integer(bytes, at: base + 33), index: try PeerBytes.integer(bytes, at: base + 37), count: try PeerBytes.integer(bytes, at: base + 41), proofLayers: try PeerBytes.integer(bytes, at: base + 45))
			if id == 21 { guard size == 49 else { throw PeerFailure.invalid("hash request length") }; return .hashRequest(request) }
			if id == 23 { guard size == 49 else { throw PeerFailure.invalid("hash rejection length") }; return .hashReject(request) }
			guard (2...512).contains(request.count), request.count.nonzeroBitCount == 1, request.proofLayers <= 40,
				size == 49 + (request.count + request.proofCount) * 32 else { throw PeerFailure.invalid("hash response length") }
			return .hashes(request, bytes.subdata(in: (base + 49)..<(base + size)))
		default: throw PeerFailure.invalid("unnegotiated message ID")
		}
	}
	public func finish() throws {
		guard handshaken, bytes.count == offset else { throw PeerFailure.invalid("truncated peer stream") }
	}
}
