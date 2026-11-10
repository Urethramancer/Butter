import Foundation

/// TCPPeerBudget enforces one hard limit across incoming and outgoing connections.
public final class TCPPeerBudget: @unchecked Sendable {
	public let limit: Int
	private let lock = NSLock()
	private var leases: Set<UUID> = []
	public init(limit: Int) { self.limit = max(1, min(limit, 10_000)) }
	public var count: Int { lock.withLock { leases.count } }
	func acquire() -> TCPPeerLease? {
		lock.withLock {
			guard leases.count < limit else { return nil }
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
