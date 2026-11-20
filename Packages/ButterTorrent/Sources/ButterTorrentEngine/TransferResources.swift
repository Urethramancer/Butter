import Foundation
import os
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

/// Shares payload bandwidth across every transfer using the same limits.
public struct SessionBandwidthLimits: Sendable {
	let download: TransferRateLimiter
	let upload: TransferRateLimiter

	public init(clock: any TransportClock = ContinuousTransportClock()) {
		download = TransferRateLimiter(rate: 0, clock: clock)
		upload = TransferRateLimiter(rate: 0, clock: clock)
	}

	public func set(download: Int, upload: Int) async throws {
		guard (0...Int(Int32.max)).contains(download), (0...Int(Int32.max)).contains(upload) else { throw PeerFailure.invalid("session bandwidth limit") }
		await self.download.set(download)
		await self.upload.set(upload)
	}
}

/// Bounds payload bytes with a one-second burst and cancellable waits.
actor TransferRateLimiter {
	private var rate: Int
	private var tokens: Double
	private var updated: TimeInterval
	private let clock: any TransportClock
	private let shared: TransferRateLimiter?
	private let configuredRate: OSAllocatedUnfairLock<Int>
	nonisolated var isLimited: Bool { configuredRate.withLock { $0 > 0 } }
	init(rate: Int, clock: any TransportClock, shared: TransferRateLimiter? = nil) {
		self.rate = rate; tokens = Double(rate); self.clock = clock; updated = clock.now()
		self.shared = shared; configuredRate = OSAllocatedUnfairLock(initialState: rate)
	}
	func set(_ rate: Int) {
		guard self.rate != rate else { return }
		self.rate = rate; tokens = min(tokens, Double(rate)); updated = clock.now()
		configuredRate.withLock { $0 = rate }
	}
	// TCP readers can amortise disk admission over 50 ms of payload. Writers and
	// other transports use 20 ms. An oversized frame can still proceed on its own.
	func pacedBatchBytes(forTCPDownload: Bool = false) -> Int? {
		let aggregate = shared?.configuredRate.withLock { $0 } ?? 0
		if rate == 0 && aggregate == 0 { return nil }
		let limit = rate == 0 || aggregate == 0 ? max(rate, aggregate) : min(rate, aggregate)
		return min(262144, limit / (forTCPDownload ? 20 : 50))
	}
	enum DownloadAdmission { case unrestricted, paced, individual }
	func downloadAdmission(bytes: Int, tcp: Bool) -> DownloadAdmission {
		guard let maximum = pacedBatchBytes(forTCPDownload: tcp) else { return .unrestricted }
		return bytes <= maximum ? .paced : .individual
	}
	func consume(_ bytes: Int, livePayload: (@Sendable () -> Int)? = nil) async throws {
		var paid = 0.0
		while paid < Double(bytes) {
			try Task.checkCancellation()
			let remaining = Double(livePayload?() ?? bytes) - paid
			if remaining <= 0 || rate == 0 { break }
			let now = clock.now(); tokens = min(Double(rate), tokens + max(0, now - updated) * Double(rate)); updated = now
			let count = min(remaining, tokens); paid += count; tokens -= count
			let deficit = remaining - count
			if deficit > 0 {
				// Let credit accumulate across several frames when a fast peer hits
				// the cap. Charge actual elapsed time on waking.
				try await clock.sleep(for: min(1, max(0.016, deficit / Double(rate))))
			}
		}
		if let shared, shared.isLimited { try await shared.consume(bytes, livePayload: livePayload) }
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
