import Foundation

// One cancellable clock task serves a connection's open/read/write deadlines.
// Completing ordinary I/O removes an entry without cancelling/recreating its timer.
final class ConnectionDeadlines: @unchecked Sendable {
	private struct Entry { let time: TimeInterval; let fail: @Sendable (Error) -> Void }
	private let lock = NSLock()
	private let clock: any TransportClock
	private var entries: [UUID: Entry] = [:]
	private var timer: Task<Void, Never>?
	private var sleepingUntil: TimeInterval?
	private var generation: UInt64 = 0
	private var closed: Error?
	init(clock: any TransportClock) { self.clock = clock }
	func insert(_ id: UUID, timeout: TimeInterval, fail: @escaping @Sendable (Error) -> Void) throws {
		guard timeout.isFinite, timeout > 0, timeout <= 86400 else { throw NetworkFailure.invalid("deadline") }
		let until = try time() + timeout
		let previous: Task<Void, Never>? = try lock.withLock {
			if let closed { throw closed }
			guard entries[id] == nil, entries.count < 3 else { throw NetworkFailure.limit("connection deadlines") }
			entries[id] = Entry(time: until, fail: fail)
			guard sleepingUntil == nil || until < sleepingUntil! else { return nil }
			let previous = timer; generation &+= 1; let epoch = generation
			sleepingUntil = until
			timer = Task { [self] in await run(epoch) }
			return previous
		}
		previous?.cancel()
	}
	func remove(_ id: UUID) { _ = lock.withLock { entries.removeValue(forKey: id) } }
	func close(_ error: Error) {
		close(error, epoch: nil)
	}
	private func close(_ error: Error, epoch: UInt64?) {
		let pending = lock.withLock { () -> (Task<Void, Never>?, [Entry]) in
			guard closed == nil, epoch == nil || epoch == generation else { return (nil, []) }
			closed = error; generation &+= 1
			let pending = Array(entries.values), previous = timer
			entries.removeAll(); timer = nil; sleepingUntil = nil
			return (previous, pending)
		}
		pending.0?.cancel()
		for entry in pending.1 { entry.fail(error) }
	}
	private func run(_ epoch: UInt64) async {
		while !Task.isCancelled {
			let until: TimeInterval? = lock.withLock {
				guard closed == nil, generation == epoch else { return nil }
				guard let next = entries.values.map(\.time).min() else { timer = nil; sleepingUntil = nil; return nil }
				sleepingUntil = next; return next
			}
			guard let until else { return }
			do {
				let remaining = until - (try time())
				if remaining > 0 { try await clock.sleep(for: remaining) }
				let now = try time()
				let expired: [Entry] = lock.withLock {
					guard generation == epoch, closed == nil else { return [] }
					let expired = entries.filter { $0.value.time <= now }
					for id in expired.keys { entries[id] = nil }
					sleepingUntil = nil
					return Array(expired.values)
				}
				for entry in expired { entry.fail(NetworkFailure.timedOut) }
			} catch {
				// A superseded timer must never fail the replacement's operations.
				close(error, epoch: epoch); return
			}
		}
	}
	private func time() throws -> TimeInterval {
		let now = clock.now()
		guard now.isFinite else { throw NetworkFailure.invalid("deadline clock") }; return now
	}
}
