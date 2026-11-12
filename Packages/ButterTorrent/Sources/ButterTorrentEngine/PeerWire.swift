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
			try PeerBytes.append(bytes.count + 9, to: &result); result.append(7)
			try PeerBytes.append(index, to: &result); try PeerBytes.append(offset, to: &result)
			result.append(bytes); return result
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
}

enum PeerBytes {
	static func append(_ value: Int, to data: inout Data) throws {
		guard let number = UInt32(exactly: value) else { throw PeerFailure.invalid("wire integer") }
		var encoded = number.bigEndian; withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
	}
	static func integer(_ data: Data, at offset: Int) throws -> Int {
		guard offset >= 0, offset <= data.count - 4 else { throw PeerFailure.invalid("truncated integer") }
		return (offset..<offset + 4).reduce(0) { ($0 << 8) | Int(data[$1]) }
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
		guard data.count <= 65_536, bytes.count - offset <= 131_076 - data.count else { throw PeerFailure.limit("wire buffer") }
		if offset > 0 { bytes = Data(bytes.dropFirst(offset)); offset = 0 }; bytes.append(data)
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
		let data = bytes.subdata(in: offset..<(offset + size)); offset += size
		switch data[0] {
		case 0...3:
			guard size == 1 else { throw PeerFailure.invalid("control message length") }
			return [.choke, .unchoke, .interested, .notInterested][Int(data[0])]
		case 4:
			guard size == 5 else { throw PeerFailure.invalid("have length") }; return .have(try PeerBytes.integer(data, at: 1))
		case 5:
			guard size <= 50_001 else { throw PeerFailure.limit("bitfield bytes") }; return .bitfield(Data(data.dropFirst()))
		case 6, 8, 16:
			if data[0] == 16, !features.fast && !features.v2 { throw PeerFailure.invalid("unnegotiated rejection") }
			guard size == 13 else { throw PeerFailure.invalid("request/cancel length") }
			let block = PeerBlock(piece: try PeerBytes.integer(data, at: 1), offset: try PeerBytes.integer(data, at: 5), length: try PeerBytes.integer(data, at: 9))
			guard (1...16384).contains(block.length) else { throw PeerFailure.invalid("request length") }
			return data[0] == 6 ? .request(block) : data[0] == 8 ? .cancel(block) : .reject(block)
		case 7:
			guard (10...16393).contains(size) else { throw PeerFailure.invalid("piece length") }
			return .piece(try PeerBytes.integer(data, at: 1), try PeerBytes.integer(data, at: 5), Data(data.dropFirst(9)))
		case 9:
			guard features.dht, size == 3 else { throw PeerFailure.invalid("unnegotiated DHT port") }; return .port(Int(data[1]) * 256 + Int(data[2]))
		case 13...17:
			guard features.fast else { throw PeerFailure.invalid("unnegotiated Fast message") }
			if data[0] == 14 || data[0] == 15 { guard size == 1 else { throw PeerFailure.invalid("Fast availability length") }; return data[0] == 14 ? .haveAll : .haveNone }
			guard size == 5 else { throw PeerFailure.invalid("Fast index length") }
			return data[0] == 13 ? .suggest(try PeerBytes.integer(data, at: 1)) : .allowedFast(try PeerBytes.integer(data, at: 1))
		case 20:
			guard features.extended, size >= 2 else { throw PeerFailure.invalid("unnegotiated extension") }; return .extended(Int(data[1]), Data(data.dropFirst(2)))
		case 21...23:
			guard features.v2, size >= 49 else { throw PeerFailure.invalid("unnegotiated hash message") }
			let request = MerkleHashRequest(root: data.subdata(in: 1..<33), base: try PeerBytes.integer(data, at: 33), index: try PeerBytes.integer(data, at: 37), count: try PeerBytes.integer(data, at: 41), proofLayers: try PeerBytes.integer(data, at: 45))
			if data[0] == 21 { guard size == 49 else { throw PeerFailure.invalid("hash request length") }; return .hashRequest(request) }
			if data[0] == 23 { guard size == 49 else { throw PeerFailure.invalid("hash rejection length") }; return .hashReject(request) }
			guard (2...512).contains(request.count), request.count.nonzeroBitCount == 1, request.proofLayers <= 40,
				size == 49 + (request.count + request.proofCount) * 32 else { throw PeerFailure.invalid("hash response length") }
			return .hashes(request, Data(data.dropFirst(49)))
		default: throw PeerFailure.invalid("unnegotiated message ID")
		}
	}
	public func finish() throws {
		guard handshaken, bytes.count == offset else { throw PeerFailure.invalid("truncated peer stream") }
	}
}
