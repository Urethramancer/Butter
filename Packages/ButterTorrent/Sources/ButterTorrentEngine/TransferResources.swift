import Foundation
import ButterTorrentNetworking
import ButterTorrentStorage

actor TransferPermits {
	private var available: Int
	private let capacity: Int
	private var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []
	private var closed = false
	var waitingCount: Int { waiting.count }
	var activeCount: Int { capacity - available }
	init(_ count: Int = 4) { available = count; capacity = count }
	func acquire() async throws {
		try Task.checkCancellation(); guard !closed else { throw PeerFailure.closed }
		if available > 0 { available -= 1; return }
		guard waiting.count < 256 else { throw PeerFailure.limit("disk waiters") }
		let id = UUID()
		try await withTaskCancellationHandler {
			try Task.checkCancellation()
			try await withCheckedThrowingContinuation { continuation in waiting.append((id, continuation)) }
		} onCancel: { Task { await self.cancel(id) } }
	}
	private func cancel(_ id: UUID) {
		if let index = waiting.firstIndex(where: { $0.0 == id }) { waiting.remove(at: index).1.resume(throwing: CancellationError()) }
	}
	func release() {
		if !waiting.isEmpty { waiting.removeFirst().1.resume() } else { available += 1 }
	}
	func close() {
		closed = true; let pending = waiting; waiting.removeAll()
		for (_, continuation) in pending { continuation.resume(throwing: PeerFailure.closed) }
	}
}

/// TransferRateLimiter bounds payload bytes with a one-second burst and cancellable waits.
actor TransferRateLimiter {
	private var rate: Int
	private var tokens: Double
	private var updated: TimeInterval
	private let clock: any TransportClock
	init(rate: Int, clock: any TransportClock) { self.rate = rate; tokens = Double(rate); self.clock = clock; updated = clock.now() }
	func set(_ rate: Int) { self.rate = rate; tokens = min(tokens, Double(rate)); updated = clock.now() }
	func consume(_ bytes: Int, isCancelled: @Sendable () -> Bool = { false }) async throws {
		var remaining = Double(bytes)
		while remaining > 0 {
			try Task.checkCancellation()
			if isCancelled() { throw CancellationError() }
			if rate == 0 { return }
			let now = clock.now(); tokens = min(Double(rate), tokens + max(0, now - updated) * Double(rate)); updated = now
			let count = min(remaining, tokens); remaining -= count; tokens -= count
			if remaining > 0 { try await clock.sleep(for: min(1, max(0.001, remaining / Double(rate)))) }
		}
	}
}

actor VerifiedPieceCache {
	private let storage: TorrentStorage
	private let owner = PieceCacheOwner()
	private let pool: SharedPieceCache
	init(storage: TorrentStorage, resources: TransferResources = .shared) { self.storage = storage; pool = resources.pieces }
	func piece(_ index: Int) async throws -> Data {
		try await pool.piece(index, storage: storage, owner: owner)
	}
	func close() async { owner.close(); await pool.close(owner) }
}
