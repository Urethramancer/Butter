import Foundation

struct PieceBitfield: Sendable {
	private(set) var bytes: Data
	let count: Int
	init(count: Int, pieces: Set<Int> = []) throws {
		guard (0...400_000).contains(count), pieces.allSatisfy({ (0..<count).contains($0) }) else { throw PeerFailure.invalid("piece bitfield") }
		self.count = count; bytes = Data(repeating: 0, count: (count + 7) / 8)
		for piece in pieces { insert(piece) }
	}
	init(count: Int, bytes: Data) throws {
		guard (0...400_000).contains(count), bytes.count == (count + 7) / 8 else { throw PeerFailure.invalid("bitfield size") }
		if count % 8 != 0, let last = bytes.last, last & UInt8((1 << (8 - count % 8)) - 1) != 0 { throw PeerFailure.invalid("bitfield spare bits") }
		self.count = count; self.bytes = Data(bytes)
	}
	func contains(_ piece: Int) -> Bool { (0..<count).contains(piece) && bytes[piece / 8] & (128 >> (piece % 8)) != 0 }
	mutating func insert(_ piece: Int) { bytes[piece / 8] |= UInt8(128 >> (piece % 8)) }
	var pieces: [Int] { (0..<count).filter(contains) }
}
