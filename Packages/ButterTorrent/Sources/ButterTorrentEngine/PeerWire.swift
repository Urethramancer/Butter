import Foundation

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
		case .request(let block), .cancel(let block):
			guard (1...16384).contains(block.length) else { throw PeerFailure.invalid("request length") }
			if case .request = self { body.append(6) } else { body.append(8) }
			for value in [block.piece, block.offset, block.length] { try PeerBytes.append(value, to: &body) }
		case .piece(let index, let offset, let bytes):
			guard (1...16384).contains(bytes.count) else { throw PeerFailure.invalid("piece block size") }
			body.append(7); try PeerBytes.append(index, to: &body); try PeerBytes.append(offset, to: &body); body.append(bytes)
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
	public init() {}
	public mutating func feed(_ data: Data) throws {
		guard data.count <= 65_536, bytes.count - offset <= 131_072 - data.count else { throw PeerFailure.limit("wire buffer") }
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
		case 6, 8:
			guard size == 13 else { throw PeerFailure.invalid("request/cancel length") }
			let block = PeerBlock(piece: try PeerBytes.integer(data, at: 1), offset: try PeerBytes.integer(data, at: 5), length: try PeerBytes.integer(data, at: 9))
			guard (1...16384).contains(block.length) else { throw PeerFailure.invalid("request length") }
			return data[0] == 6 ? .request(block) : .cancel(block)
		case 7:
			guard (10...16393).contains(size) else { throw PeerFailure.invalid("piece length") }
			return .piece(try PeerBytes.integer(data, at: 1), try PeerBytes.integer(data, at: 5), Data(data.dropFirst(9)))
		default: throw PeerFailure.invalid("unnegotiated message ID")
		}
	}
	public func finish() throws {
		guard handshaken, bytes.count == offset else { throw PeerFailure.invalid("truncated peer stream") }
	}
}
