import Foundation
import ButterTorrentStorage

public struct TransferResourceSnapshot: Sendable {
	public let diskOperations: Int
	public let waitingDiskOperations: Int
	public let cachedBytes: Int
	public let loadingBytes: Int
}

/// TransferResources bounds disk admission and immutable upload caches across transfers.
public final class TransferResources: Sendable {
	public static let shared = try! TransferResources()
	let disk: TransferPermits
	let web = TransferPermits(3)
	let pieces: SharedPieceCache
	public init(maximumDiskOperations: Int = 8, maximumCachedBytes: Int = 64 * 1024 * 1024) throws {
		guard (1...64).contains(maximumDiskOperations), (16 * 1024 * 1024...256 * 1024 * 1024).contains(maximumCachedBytes) else { throw PeerFailure.invalid("session resource limits") }
		disk = TransferPermits(maximumDiskOperations); pieces = SharedPieceCache(limit: maximumCachedBytes)
	}
	public func snapshot() async -> TransferResourceSnapshot {
		let active = await disk.activeCount, waiting = await disk.waitingCount
		let (cached, loading) = await pieces.usage
		return TransferResourceSnapshot(diskOperations: active, waitingDiskOperations: waiting, cachedBytes: cached, loadingBytes: loading)
	}
}

// Closing one transfer must cancel its own admission without closing the session budget.
actor TransferDiskScope {
	private let local = TransferPermits()
	private let shared: TransferPermits
	private var closed = false
	init(resources: TransferResources) { shared = resources.disk }
	func acquire() async throws {
		try await local.acquire()
		do {
			try await shared.acquire()
			if closed || Task.isCancelled {
				await shared.release()
				if Task.isCancelled { throw CancellationError() }; throw PeerFailure.closed
			}
		} catch { await local.release(); throw error }
	}
	func release() async { await shared.release(); await local.release() }
	func close() async { closed = true; await local.close() }
}

final class PieceCacheOwner: @unchecked Sendable {
	let id = UUID()
	private let lock = NSLock()
	private var stopped = false
	var closed: Bool { lock.withLock { stopped } }
	func close() { lock.withLock { stopped = true } }
}

actor SharedPieceCache {
	private struct Key: Hashable { let owner: UUID; let piece: Int }
	private struct Load { let id: UUID; let bytes: Int; let task: Task<Data, Error> }
	private let limit: Int
	private let read: @Sendable (TorrentStorage, Int) async throws -> Data
	private var values: [Key: (Data, UInt64)] = [:]
	private var loading: [Key: Load] = [:]
	private var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []
	private var bytes = 0
	private var reserved = 0
	private var order: UInt64 = 0
	var usage: (Int, Int) { (bytes, reserved) }
	var waitingCount: Int { waiting.count }
	init(limit: Int, read: @escaping @Sendable (TorrentStorage, Int) async throws -> Data = { try await $0.readVerifiedPiece($1) }) { self.limit = limit; self.read = read }
	func piece(_ index: Int, storage: TorrentStorage, owner: PieceCacheOwner) async throws -> Data {
		let key = Key(owner: owner.id, piece: index), length = try storage.layout.length(of: index)
		guard length <= limit else { throw PeerFailure.limit("session piece cache bytes") }
		let load: Load
		while true {
			try Task.checkCancellation(); guard !owner.closed else { throw PeerFailure.closed }; order &+= 1
			if let value = values[key] { values[key] = (value.0, order); return value.0 }
			if let current = loading[key] { load = current; break }
			if loading.count >= 64 || loading.keys.filter({ $0.owner == owner.id }).count >= 4 || length > limit - reserved {
				try await waitForCapacity(); continue
			}
			while bytes + reserved + length > limit || values.keys.filter({ $0.owner == owner.id }).count >= 8 {
				let candidates = values.keys.filter({ $0.owner == owner.id }).count >= 8 ? values.filter({ $0.key.owner == owner.id }) : values
				guard let oldest = candidates.min(by: { $0.value.1 < $1.value.1 }) else { break }
				bytes -= oldest.value.0.count; values[oldest.key] = nil
			}
			let read = read
			load = Load(id: UUID(), bytes: length, task: Task { try await read(storage, index) })
			loading[key] = load; reserved += length; break
		}
		do {
			let data = try await load.task.value
			guard !owner.closed else { throw PeerFailure.closed }
			if loading[key]?.id == load.id {
				loading[key] = nil; reserved -= load.bytes
				order &+= 1; values[key] = (data, order); bytes += data.count
				wake()
			}
			try Task.checkCancellation(); return data
		} catch {
			if loading[key]?.id == load.id { loading[key] = nil; reserved -= load.bytes; wake() }
			throw error
		}
	}
	func close(_ owner: PieceCacheOwner) async {
		owner.close(); wake()
		let tasks = loading.filter { $0.key.owner == owner.id }
		for load in tasks.values { load.task.cancel() }
		for load in tasks.values { _ = try? await load.task.value }
		for (key, load) in tasks where loading[key]?.id == load.id { loading[key] = nil; reserved -= load.bytes }
		for key in values.keys.filter({ $0.owner == owner.id }) { bytes -= values.removeValue(forKey: key)!.0.count }
		wake()
	}
	private func waitForCapacity() async throws {
		guard waiting.count < 256 else { throw PeerFailure.limit("session cache waiters") }
		let id = UUID()
		try await withTaskCancellationHandler {
			try Task.checkCancellation()
			try await withCheckedThrowingContinuation { continuation in waiting.append((id, continuation)) }
		} onCancel: { Task { await self.cancel(id) } }
	}
	private func cancel(_ id: UUID) {
		if let index = waiting.firstIndex(where: { $0.0 == id }) { waiting.remove(at: index).1.resume(throwing: CancellationError()) }
	}
	private func wake() {
		let pending = waiting; waiting.removeAll()
		for (_, continuation) in pending { continuation.resume() }
	}
}
