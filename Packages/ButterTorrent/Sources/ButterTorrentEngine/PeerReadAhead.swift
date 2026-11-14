import Foundation

// One reader owns take/prefetch; cancellation may arrive from another executor.
// Raw bytes held by that reader plus its one pending read stay within 256 KiB.
final class PeerReadAhead: @unchecked Sendable {
	static let maximumBytes = 262144
	private let lock = NSLock()
	private var pending: Task<Data, Error>?
	private var cancelled = false
	func prefetch(retainedBytes: Int, read: @escaping @Sendable (Int) async throws -> Data) -> Int? {
		guard retainedBytes > 0, retainedBytes < Self.maximumBytes else { return nil }
		return lock.withLock {
			guard !cancelled, pending == nil else { return nil }
			let capacity = Self.maximumBytes - retainedBytes
			pending = Task { try await read(capacity) }
			return capacity
		}
	}
	func take() -> Task<Data, Error>? {
		lock.withLock { let task = pending; pending = nil; return task }
	}
	func cancel() {
		let task = lock.withLock { cancelled = true; return pending }
		task?.cancel()
	}
	func drain() async {
		cancel()
		if let task = take() { _ = try? await task.value }
	}
}
