import Foundation
import ButterTorrentNetworking
import ButterTorrentStorage

actor TransferPermits {
	private var available: Int
	nonisolated let capacity: Int
	private var waiting: [(id: UUID, units: Int, continuation: CheckedContinuation<Void, Error>)] = []
	private var closed = false
	var waitingCount: Int { waiting.count }
	var activeCount: Int { capacity - available }
	init(_ count: Int = 4) { available = count; capacity = count }
	func acquire(_ units: Int = 1) async throws {
		try Task.checkCancellation(); guard !closed else { throw PeerFailure.closed }
		guard units > 0, units <= capacity else { throw PeerFailure.limit("disk batch permits") }
		if waiting.isEmpty, available >= units { available -= units; return }
		guard waiting.count < 256 else { throw PeerFailure.limit("disk waiters") }
		let id = UUID()
		try await withTaskCancellationHandler {
			try Task.checkCancellation()
			try await withCheckedThrowingContinuation { continuation in waiting.append((id, units, continuation)); drain() }
		} onCancel: { Task { await self.cancel(id) } }
	}
	private func cancel(_ id: UUID) {
		if let index = waiting.firstIndex(where: { $0.id == id }) { waiting.remove(at: index).continuation.resume(throwing: CancellationError()); drain() }
	}
	func release(_ units: Int = 1) {
		precondition(units > 0 && units <= capacity - available)
		available += units; drain()
	}
	private func drain() {
		while let first = waiting.first, first.units <= available {
			available -= first.units; waiting.removeFirst().continuation.resume()
		}
	}
	func close() {
		closed = true; let pending = waiting; waiting.removeAll()
		for entry in pending { entry.continuation.resume(throwing: PeerFailure.closed) }
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
	// Grant only currently unrestricted work; later limit changes apply to the next batch.
	func consumeUnrestrictedBatch() -> Bool { rate == 0 }
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

// Mutable cache state belongs to SharedPieceCache; owner closure is lock-protected.
// Keep this immutable wrapper on its caller's executor instead of adding a hop
// for every upload block, including cache hits.
final class VerifiedPieceCache: Sendable {
	private let storage: TorrentStorage
	private let owner = PieceCacheOwner()
	private let pool: SharedPieceCache
	private let read: SharedPieceCache.Reader
	init(storage: TorrentStorage, resources: TransferResources = .shared, disk: TransferDiskScope? = nil) {
		self.storage = storage; pool = resources.pieces
		let disk = disk ?? TransferDiskScope(resources: resources)
		read = { storage, index in
			try await disk.acquire()
			do {
				let bytes = try await storage.readVerifiedPiece(index)
				await disk.release(); return bytes
			} catch { await disk.release(); throw error }
		}
	}
	func piece(_ index: Int, isolation: isolated (any Actor)? = #isolation) async throws -> Data {
		try await pool.piece(index, storage: storage, owner: owner, load: read)
	}
	func close() async { owner.close(); await pool.close(owner) }
}
