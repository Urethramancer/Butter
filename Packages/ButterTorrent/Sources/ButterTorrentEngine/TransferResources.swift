import Foundation
import ButterTorrentNetworking
import ButterTorrentStorage

actor TransferPermits {
	private var available: Int
	private var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []
	private var closed = false
	var waitingCount: Int { waiting.count }
	init(_ count: Int = 4) { available = count }
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
	func consume(_ bytes: Int) async throws {
		var remaining = Double(bytes)
		while remaining > 0 {
			try Task.checkCancellation()
			if rate == 0 { return }
			let now = clock.now(); tokens = min(Double(rate), tokens + max(0, now - updated) * Double(rate)); updated = now
			let count = min(remaining, tokens); remaining -= count; tokens -= count
			if remaining > 0 { try await clock.sleep(for: min(1, max(0.001, remaining / Double(rate)))) }
		}
	}
}

actor VerifiedPieceCache {
	private let storage: TorrentStorage
	private var values: [Int: (Data, UInt64)] = [:]
	private var loading: [Int: Task<Data, Error>] = [:]
	private var bytes = 0
	private var order: UInt64 = 0
	private var closed = false
	init(storage: TorrentStorage) { self.storage = storage }
	func piece(_ index: Int) async throws -> Data {
		guard !closed else { throw PeerFailure.closed }; order &+= 1
		if let value = values[index] { values[index] = (value.0, order); return value.0 }
		let task: Task<Data, Error>
		if let existing = loading[index] { task = existing }
		else {
			guard loading.count < 4 else { throw PeerFailure.limit("piece cache loads") }
			task = Task { try await storage.readVerifiedPiece(index) }; loading[index] = task
		}
		do {
			let data = try await task.value; loading[index] = nil
			guard !closed else { throw PeerFailure.closed }
			if values[index] == nil {
				while bytes + data.count > 32 * 1024 * 1024 || values.count >= 8 {
					guard let oldest = values.min(by: { $0.value.1 < $1.value.1 }) else { break }
					bytes -= oldest.value.0.count; values[oldest.key] = nil
				}
				order &+= 1; values[index] = (data, order); bytes += data.count
			}
			return data
		} catch { loading[index] = nil; throw error }
	}
	func close() async {
		closed = true
		let tasks = Array(loading.values); loading.removeAll(); values.removeAll(); bytes = 0
		for task in tasks { task.cancel() }; for task in tasks { _ = try? await task.value }
	}
}
