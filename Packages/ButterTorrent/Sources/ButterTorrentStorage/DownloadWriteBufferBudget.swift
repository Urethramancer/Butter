import Foundation

/// DownloadWriteBufferBudget bounds additional contiguous write buffers per session.
public final class DownloadWriteBufferBudget: @unchecked Sendable {
	private let lock = NSLock()
	private var bytes = 0
	public init() {}
	var usage: Int { lock.withLock { bytes } }
	func reserve(_ count: Int) -> Bool {
		lock.withLock {
			guard count >= 0, count <= 1_048_576 - bytes else { return false }
			bytes += count; return true
		}
	}
	func release(_ count: Int) { lock.withLock { bytes -= count } }
}
