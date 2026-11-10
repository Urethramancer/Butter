import Foundation
import Darwin

final class StorageLease: @unchecked Sendable {
	private let lock = NSLock()
	private var descriptor: Int32?
	init(directory: StorageDirectory) throws {
		let fd = try directory.openFile("storage.lock", write: true)
		guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw StorageFailure.shared("checkpoint directory") }
		descriptor = fd
	}
	func release() { lock.withLock { if let descriptor { close(descriptor); self.descriptor = nil } } }
	deinit { release() }
}

final class DiskCancellation: @unchecked Sendable {
	private let lock = NSLock()
	private var cancelled = false
	func cancel() { lock.withLock { cancelled = true } }
	func check() throws { if lock.withLock({ cancelled }) { throw CancellationError() } }
}

// A serial worker bounds both outstanding commands and simultaneous disk/hash work.
final class StorageWorker: @unchecked Sendable {
	private static let queue = DispatchQueue(label: "Butter.Storage")
	private static let budget = DiskWorkBudget()
	private let lock = NSLock()
	private var pending = 0
	func run<T: Sendable>(_ operation: @escaping @Sendable (DiskCancellation) throws -> T) async throws -> T {
		try Task.checkCancellation()
		let admitted = lock.withLock { if pending >= 8 { return false }; pending += 1; return true }
		guard admitted else { throw StorageFailure.limit("queued disk commands") }
		guard Self.budget.acquire() else { lock.withLock { pending -= 1 }; throw StorageFailure.limit("global disk commands") }
		let cancellation = DiskCancellation()
		return try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { continuation in
				Self.queue.async {
					let result = Result { try cancellation.check(); return try operation(cancellation) }
					self.lock.withLock { self.pending -= 1 }
					Self.budget.release()
					continuation.resume(with: result)
				}
			}
		} onCancel: { cancellation.cancel() }
	}
}

private final class DiskWorkBudget: @unchecked Sendable {
	private let lock = NSLock()
	private var pending = 0
	func acquire() -> Bool { lock.withLock { guard pending < 64 else { return false }; pending += 1; return true } }
	func release() { lock.withLock { pending -= 1 } }
}

/// StorageCoordinator protects paths shared by live native transfers in one process.
public final class StorageCoordinator: @unchecked Sendable {
	public static let shared = StorageCoordinator()
	private let lock = NSLock()
	private var claims: [UUID: Set<String>] = [:]
	public init() {}
	func claim(_ owner: UUID, paths: [URL]) throws {
		try lock.withLock {
			let wanted = Set(paths.map { StorageLayout.pathKey($0.standardizedFileURL.resolvingSymlinksInPath().path) })
			let others = claims.filter { $0.key != owner }.flatMap { entry in entry.value.map { ($0, false) } }
			let sorted = (others + wanted.map { ($0, true) }).sorted { $0.0 < $1.0 }
			var ancestors: [(String, Bool)] = []
			for entry in sorted {
				while let last = ancestors.last, entry.0 != last.0 && !entry.0.hasPrefix(last.0 + "/") { ancestors.removeLast() }
				if ancestors.contains(where: { $0.1 != entry.1 }) { throw StorageFailure.shared(entry.0) }
				ancestors.append(entry)
			}
			claims[owner] = wanted
		}
	}
	func release(_ owner: UUID) { lock.withLock { claims[owner] = nil } }
}
