import Foundation
import ButterTorrentStorage

struct PiecePicker {
	struct Active {
		var received: Set<Int> = []
		var writing: Set<Int> = []
		var owners: [Int: [UUID: TimeInterval]] = [:]
		var contributors: Set<UUID> = []
		var verifying = false
	}
	let layout: StorageLayout
	let wanted: Set<Int>
	let maximumActive: Int
	let lengths: [Int: Int]
	private(set) var completed: Set<Int>
	private(set) var staged: Set<Int> = []
	private(set) var active: [Int: Active] = [:]
	private var peers: [UUID: PieceBitfield] = [:]
	private(set) var availability: [Int]
	init(layout: StorageLayout, wanted: Set<Int>, completed: Set<Int>, maximumActive: Int = 8, lengths: [Int: Int] = [:]) {
		self.layout = layout; self.wanted = wanted; self.completed = completed; self.maximumActive = maximumActive
		availability = Array(repeating: 0, count: layout.pieceCount)
		self.lengths = lengths
	}
	var complete: Bool { wanted.isSubset(of: completed) }
	mutating func update(_ peer: UUID, bits: PieceBitfield) {
		if let previous = peers[peer] { for piece in previous.pieces { availability[piece] -= 1 } }
		peers[peer] = bits; for piece in bits.pieces { availability[piece] += 1 }
	}
	mutating func have(_ peer: UUID, piece: Int) throws {
		guard (0..<layout.pieceCount).contains(piece), var bits = peers[peer] else { throw PeerFailure.invalid("have index or peer") }
		if !bits.contains(piece) { bits.insert(piece); peers[peer] = bits; availability[piece] += 1 }
	}
	mutating func remove(_ peer: UUID) {
		if let bits = peers.removeValue(forKey: peer) { for piece in bits.pieces { availability[piece] -= 1 } }
		release(peer)
		for piece in active.keys where availability[piece] == 0 && active[piece]!.writing.isEmpty && !active[piece]!.verifying { active[piece] = nil }
	}
	mutating func release(_ peer: UUID) {
		for piece in active.keys { for block in active[piece]!.owners.keys { active[piece]!.owners[block]![peer] = nil } }
	}
	func interested(_ peer: UUID) -> Bool { peers[peer]?.pieces.contains(where: { wanted.contains($0) && !completed.contains($0) && !staged.contains($0) }) == true }
	func has(_ peer: UUID, piece: Int) -> Bool { peers[peer]?.contains(piece) == true }
	func blocks(_ piece: Int) -> [PeerBlock] {
		let length = lengths[piece] ?? ((try? layout.length(of: piece)) ?? 0)
		return stride(from: 0, to: length, by: 16384).map { PeerBlock(piece: piece, offset: $0, length: min(16384, length - $0)) }
	}
	mutating func allocate(_ peer: UUID, limit: Int, now: TimeInterval, eligible: Set<Int>? = nil, allowed: Set<Int>? = nil, suggestions: Set<Int> = []) -> [PeerBlock] {
		guard let bits = peers[peer], limit > 0 else { return [] }
		var result: [PeerBlock] = []
		let remaining = wanted.subtracting(completed).subtracting(staged)
		let candidates = remaining.filter { bits.contains($0) && (eligible?.contains($0) ?? true) && (allowed?.contains($0) ?? true) }.sorted {
			let a = active[$0] != nil, b = active[$1] != nil
			if a != b { return a }
			if availability[$0] != availability[$1] { return availability[$0] < availability[$1] }
			if suggestions.contains($0) != suggestions.contains($1) { return suggestions.contains($0) }; return $0 < $1
		}
		for piece in candidates {
			if active[piece] == nil {
				if active.count >= maximumActive { continue }; active[piece] = Active()
			}
			guard !active[piece]!.verifying else { continue }
			for block in blocks(piece) where !active[piece]!.received.contains(block.offset) && !active[piece]!.writing.contains(block.offset) {
				if active[piece]!.owners[block.offset, default: [:]].isEmpty {
					active[piece]!.owners[block.offset] = [peer: now]; result.append(block)
					if result.count == limit { return result }
				}
			}
		}
		// Duplicate the final bounded tail, or rescue a saturated active-piece budget
		// when a stalled owner otherwise prevents a newly available peer making progress.
		let tail = remaining.allSatisfy({ active[$0] != nil }) && remaining.reduce(0, { $0 + blocks($1).count - active[$1]!.received.count }) <= 32
		if tail || (result.isEmpty && active.count >= maximumActive) {
			for piece in candidates where active[piece]?.verifying == false {
				for block in blocks(piece) where !active[piece]!.received.contains(block.offset) && !active[piece]!.writing.contains(block.offset) {
					let owners = active[piece]!.owners[block.offset, default: [:]]
					if owners.count == 1 && owners[peer] == nil {
						active[piece]!.owners[block.offset]![peer] = now; result.append(block)
						if result.count == limit { return result }
					}
				}
			}
		}
		return result
	}
	mutating func begin(_ peer: UUID, block: PeerBlock) -> [UUID]? {
		guard var item = active[block.piece], !item.received.contains(block.offset), !item.writing.contains(block.offset), item.owners[block.offset]?[peer] != nil else { return nil }
		let cancel = item.owners[block.offset]!.keys.filter { $0 != peer }
		item.owners[block.offset] = nil; item.writing.insert(block.offset); item.contributors.insert(peer); active[block.piece] = item
		return Array(cancel)
	}
	mutating func written(_ block: PeerBlock) -> Bool {
		guard var item = active[block.piece] else { return false }
		item.writing.remove(block.offset); item.received.insert(block.offset)
		let ready = item.received.count == blocks(block.piece).count && item.writing.isEmpty
		if ready { item.verifying = true }; active[block.piece] = item; return ready
	}
	mutating func abortedWrite(_ block: PeerBlock) {
		guard var item = active[block.piece] else { return }
		item.writing.remove(block.offset); item.owners[block.offset] = nil
		if availability[block.piece] == 0 && item.writing.isEmpty { active[block.piece] = nil } else { active[block.piece] = item }
	}
	mutating func rejected(_ peer: UUID, block: PeerBlock) { active[block.piece]?.owners[block.offset]?[peer] = nil }
	mutating func verified(_ piece: Int, valid: Bool) -> Set<UUID> {
		let contributors = active.removeValue(forKey: piece)?.contributors ?? []
		if valid { completed.insert(piece) }; return contributors
	}
	mutating func stage(_ piece: Int) -> Set<UUID> {
		staged.insert(piece)
		return active.removeValue(forKey: piece)?.contributors ?? []
	}
	mutating func settleStaged(_ piece: Int, valid: Bool) -> Bool {
		guard staged.remove(piece) != nil else { return false }
		if valid { completed.insert(piece) }
		return true
	}
	mutating func expired(now: TimeInterval, timeout: TimeInterval) -> [(UUID, PeerBlock)] {
		var expired: [(UUID, PeerBlock)] = []
		for piece in active.keys {
			for block in blocks(piece) {
				for (peer, sent) in active[piece]!.owners[block.offset, default: [:]] where now - sent >= timeout {
					active[piece]!.owners[block.offset]![peer] = nil; expired.append((peer, block))
				}
			}
		}
		return expired
	}
}
