import Foundation

// Transfer commands may overlap across IDs; settings and shutdown acquire a barrier.
actor SessionCommandGate {
	private struct Lease { let transfer: String? }
	private struct Waiter { let token: UUID; let lease: Lease; let continuation: CheckedContinuation<UUID, Error> }
	private var active: [UUID: Lease] = [:]
	private var waiting: [Waiter] = []
	var waitingCount: Int { waiting.count }
	func acquire(_ transfer: String? = nil) async throws -> UUID {
		try Task.checkCancellation()
		if let token = tryAcquire(transfer) { return token }
		guard waiting.count < 256 else { throw PeerFailure.limit("session command waiters") }
		let token = UUID()
		return try await withTaskCancellationHandler {
			try Task.checkCancellation()
			return try await withCheckedThrowingContinuation { continuation in
				waiting.append(Waiter(token: token, lease: Lease(transfer: transfer), continuation: continuation))
			}
		} onCancel: { Task { await self.cancel(token) } }
	}
	func tryAcquire(_ transfer: String? = nil) -> UUID? {
		let lease = Lease(transfer: transfer)
		guard !active.values.contains(where: { conflicts(lease, $0) }), !waiting.contains(where: { conflicts(lease, $0.lease) }) else { return nil }
		let token = UUID(); active[token] = lease; return token
	}
	func release(_ token: UUID) {
		guard active.removeValue(forKey: token) != nil else { return }; schedule()
	}
	private func conflicts(_ a: Lease, _ b: Lease) -> Bool { a.transfer == nil || b.transfer == nil || a.transfer == b.transfer }
	private func cancel(_ token: UUID) {
		guard let index = waiting.firstIndex(where: { $0.token == token }) else { return }
		waiting.remove(at: index).continuation.resume(throwing: CancellationError()); schedule()
	}
	private func schedule() {
		var blocked: [Lease] = [], index = 0
		while index < waiting.count {
			let item = waiting[index]
			if active.values.contains(where: { conflicts(item.lease, $0) }) || blocked.contains(where: { conflicts(item.lease, $0) }) {
				blocked.append(item.lease); index += 1; continue
			}
			waiting.remove(at: index); active[item.token] = item.lease; item.continuation.resume(returning: item.token)
		}
	}
}
