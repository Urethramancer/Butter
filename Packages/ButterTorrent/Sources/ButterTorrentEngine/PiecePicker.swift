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
	private var missingWanted: Int
	private let allPiecesWanted: Bool
	private var completedPrefix = 0
	private(set) var staged: Set<Int> = []
	private(set) var active: [Int: Active] = [:]
	private var peers: [UUID: PieceBitfield] = [:]
	private(set) var availability: [Int]
	init(layout: StorageLayout, wanted: Set<Int>, completed: Set<Int>, maximumActive: Int = 8, lengths: [Int: Int] = [:]) {
		self.layout = layout; self.wanted = wanted; self.completed = completed; self.maximumActive = maximumActive
		missingWanted = wanted.reduce(0) { $0 + (completed.contains($1) ? 0 : 1) }
		availability = Array(repeating: 0, count: layout.pieceCount)
		self.lengths = lengths
		allPiecesWanted = wanted.count == layout.pieceCount && wanted.allSatisfy { (0..<layout.pieceCount).contains($0) }
		if allPiecesWanted { advanceCompletedPrefix() }
	}
	var complete: Bool { missingWanted == 0 }
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
	func interested(_ peer: UUID) -> Bool {
		guard missingWanted > 0, let bits = peers[peer] else { return false }
		return wanted.contains { !completed.contains($0) && !staged.contains($0) && bits.contains($0) }
	}
	func has(_ peer: UUID, piece: Int) -> Bool { peers[peer]?.contains(piece) == true }
	func blocks(_ piece: Int) -> [PeerBlock] {
		let length = lengths[piece] ?? ((try? layout.length(of: piece)) ?? 0)
		return stride(from: 0, to: length, by: 16384).map { PeerBlock(piece: piece, offset: $0, length: min(16384, length - $0)) }
	}
	mutating func allocate(_ peer: UUID, limit: Int, now: TimeInterval, eligible: Set<Int>? = nil, allowed: Set<Int>? = nil, suggestions: Set<Int> = [], excluding: Set<Int> = []) -> [PeerBlock] {
		guard let bits = peers[peer], limit > 0 else { return [] }
		let permitted: (Int) -> Bool = { !excluding.contains($0) && bits.contains($0) && (eligible?.contains($0) ?? true) && (allowed?.contains($0) ?? true) }
		let order: (Int, Int) -> Bool = { [availability] in
			if availability[$0] != availability[$1] { return availability[$0] < availability[$1] }
			if suggestions.contains($0) != suggestions.contains($1) { return suggestions.contains($0) }; return $0 < $1
		}
		let candidates = active.keys.filter(permitted).sorted(by: order)
		var result = reserve(peer, candidates: candidates, limit: limit, now: now)
		if result.count == limit { return result }
		if active.count < maximumActive {
			// Only this bounded prefix can be admitted. Avoid sorting the whole torrent
			// again for each received block while preserving rarest/suggested/index order.
			let capacity = min(maximumActive - active.count, limit - result.count)
			let fresh = allPiecesWanted
				? freshCandidates(completedPrefix..<layout.pieceCount, capacity: capacity, ascending: true, suggestions: suggestions, permitted: permitted, order: order)
				: freshCandidates(wanted, capacity: capacity, ascending: false, suggestions: suggestions, permitted: permitted, order: order)
			result += reserve(peer, candidates: fresh, limit: limit - result.count, now: now)
			if result.count == limit { return result }
		}
		// Duplicate the final bounded tail, or rescue a saturated active-piece budget
		// when a stalled owner otherwise prevents a newly available peer making progress.
		let remaining = wanted.subtracting(completed).subtracting(staged)
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
	private func freshCandidates<S: Sequence>(_ pieces: S, capacity: Int, ascending: Bool, suggestions: Set<Int>, permitted: (Int) -> Bool, order: (Int, Int) -> Bool) -> [Int] where S.Element == Int {
		var fresh: [Int] = []; fresh.reserveCapacity(capacity)
		for piece in pieces where !completed.contains(piece) && !staged.contains(piece) && active[piece] == nil && permitted(piece) {
			if fresh.count == capacity, !order(piece, fresh.last!) { continue }
			let position = fresh.firstIndex { order(piece, $0) } ?? fresh.endIndex
			fresh.insert(piece, at: position)
			if fresh.count > capacity { fresh.removeLast() }
			// The requesting peer supplies availability >= 1. In ascending index order,
			// no later unsuggested piece can beat a full prefix at that minimum rarity.
			if ascending && suggestions.isEmpty && fresh.count == capacity && availability[fresh.last!] == 1 { break }
		}
		return fresh
	}
	private mutating func reserve(_ peer: UUID, candidates: [Int], limit: Int, now: TimeInterval) -> [PeerBlock] {
		var result: [PeerBlock] = []
		for piece in candidates {
			if active[piece] == nil {
				guard active.count < maximumActive else { break }; active[piece] = Active()
			}
			guard !active[piece]!.verifying else { continue }
			for block in blocks(piece) where !active[piece]!.received.contains(block.offset) && !active[piece]!.writing.contains(block.offset) {
				if active[piece]!.owners[block.offset, default: [:]].isEmpty {
					active[piece]!.owners[block.offset] = [peer: now]; result.append(block)
					if result.count == limit { return result }
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
	// Predict only from accepted, staged blocks; do not advance picker state before
	// their disk job succeeds. Other in-flight writes must finish separately.
	func firstCompletedPiece(afterWriting blocks: [PeerBlock]) -> Int? {
		var written: [Int: Set<Int>] = [:]
		for block in blocks {
			guard let item = active[block.piece], item.writing.contains(block.offset) else { continue }
			written[block.piece, default: []].insert(block.offset)
			let offsets = written[block.piece]!
			let length = lengths[block.piece] ?? ((try? layout.length(of: block.piece)) ?? 0)
			if offsets == item.writing, item.received.count + offsets.count == (length + 16383) / 16384 { return block.piece }
		}
		return nil
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
		if valid { recordCompletion(piece) }; return contributors
	}
	mutating func stage(_ piece: Int) -> Set<UUID> {
		staged.insert(piece)
		return active.removeValue(forKey: piece)?.contributors ?? []
	}
	mutating func settleStaged(_ piece: Int, valid: Bool) -> Bool {
		guard staged.remove(piece) != nil else { return false }
		if valid { recordCompletion(piece) }
		return true
	}
	private mutating func recordCompletion(_ piece: Int) {
		if completed.insert(piece).inserted && wanted.contains(piece) { missingWanted -= 1 }
		if allPiecesWanted && piece == completedPrefix { advanceCompletedPrefix() }
	}
	private mutating func advanceCompletedPrefix() {
		while completedPrefix < layout.pieceCount && completed.contains(completedPrefix) { completedPrefix += 1 }
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
