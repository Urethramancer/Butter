import Foundation
import Darwin

final class StorageLease: @unchecked Sendable {
	private let lock = NSLock()
	private var descriptor: Int32?
	init(directory: StorageDirectory, path: String = "storage.lock") throws {
		let fd = try directory.openFile(path, write: true)
		guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw StorageFailure.shared(path == "storage.lock" ? "checkpoint directory" : "native session repository") }
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

// Each owner remains serial; four shared workers permit independent disk/hash work.
final class StorageWorker: @unchecked Sendable {
	private static let pool = DiskWorkPool()
	private static let budget = DiskWorkBudget()
	private let owner = UUID()
	private let lock = NSLock()
	private var pending = 0
	var pendingCount: Int { lock.withLock { pending } }
	func run<T: Sendable>(bulk: Bool = false, units: Int = 1, _ operation: @escaping @Sendable (DiskCancellation) throws -> T) async throws -> T {
		try Task.checkCancellation()
		guard (1...8).contains(units) else { throw StorageFailure.limit("disk command units") }
		let admitted = lock.withLock { if units > 8 - pending { return false }; pending += units; return true }
		guard admitted else { throw StorageFailure.limit("queued disk commands") }
		guard Self.budget.acquire(units) else { lock.withLock { pending -= units }; throw StorageFailure.limit("global disk commands") }
		let cancellation = DiskCancellation()
		return try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { continuation in
				Self.pool.submit(owner: self.owner, bulk: bulk) {
					let result = Result { try cancellation.check(); return try operation(cancellation) }
					self.lock.withLock { self.pending -= units }
					Self.budget.release(units)
					continuation.resume(with: result)
				}
			}
		} onCancel: { cancellation.cancel() }
	}
}

// Ready work never blocks a thread waiting for another owner's turn.
final class DiskWorkPool: @unchecked Sendable {
	private struct Job: Sendable { let owner: UUID; let bulk: Bool; let run: @Sendable () -> Void }
	private let lock = NSLock()
	private let queue = DispatchQueue(label: "Butter.Storage", attributes: .concurrent)
	private let maximum: Int
	private var busy: Set<UUID> = []
	private var bulkOwners: Set<UUID> = []
	private var pending: [Job] = []
	init(maximum: Int = 4) { precondition(maximum > 0); self.maximum = maximum }
	func submit(owner: UUID, bulk: Bool = false, run: @escaping @Sendable () -> Void) {
		let ready = lock.withLock { pending.append(Job(owner: owner, bulk: bulk, run: run)); return takeReady() }
		dispatch(ready)
	}
	private func takeReady() -> [Job] {
		var ready: [Job] = []
		while busy.count < maximum {
			var seen: Set<UUID> = []
			guard let index = pending.firstIndex(where: { job in
				guard seen.insert(job.owner).inserted, !busy.contains(job.owner) else { return false }
				return !job.bulk || bulkOwners.count < max(1, maximum - 1)
			}) else { break }
			let job = pending.remove(at: index); busy.insert(job.owner)
			if job.bulk { bulkOwners.insert(job.owner) }; ready.append(job)
		}
		return ready
	}
	private func dispatch(_ ready: [Job]) {
		for job in ready {
			queue.async {
				job.run()
				let next = self.lock.withLock { self.busy.remove(job.owner); self.bulkOwners.remove(job.owner); return self.takeReady() }
				self.dispatch(next)
			}
		}
	}
}

private final class DiskWorkBudget: @unchecked Sendable {
	private let lock = NSLock()
	private var pending = 0
	func acquire(_ units: Int) -> Bool { lock.withLock { guard units <= 64 - pending else { return false }; pending += units; return true } }
	func release(_ units: Int) { lock.withLock { pending -= units } }
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
