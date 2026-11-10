import Foundation

/// TCPPeerBudget enforces one hard limit across incoming and outgoing connections.
public final class TCPPeerBudget: @unchecked Sendable {
	private var capacity: Int
	private let lock = NSLock()
	private var leases: Set<UUID> = []
	public init(limit: Int) { capacity = max(1, min(limit, 10_000)) }
	public var limit: Int { lock.withLock { capacity } }
	public var count: Int { lock.withLock { leases.count } }
	public func setLimit(_ limit: Int) throws {
		guard (1...10_000).contains(limit) else { throw NetworkFailure.invalid("peer limit") }
		try lock.withLock { guard leases.count <= limit else { throw NetworkFailure.busy }; capacity = limit }
	}
	func acquire() -> TCPPeerLease? {
		lock.withLock {
			guard leases.count < capacity else { return nil }
			let id = UUID(); leases.insert(id)
			return TCPPeerLease { self.lock.withLock { _ = self.leases.remove(id) } }
		}
	}
}

final class TCPPeerLease: @unchecked Sendable {
	private let lock = NSLock()
	private var releaseBody: (@Sendable () -> Void)?
	init(_ release: @escaping @Sendable () -> Void) { releaseBody = release }
	func release() {
		let body = lock.withLock { let body = releaseBody; releaseBody = nil; return body }
		body?()
	}
	deinit { releaseBody?() }
}
