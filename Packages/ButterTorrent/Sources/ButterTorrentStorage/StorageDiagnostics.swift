import Foundation

/// StorageDiagnostics supplies opt-in aggregate counters for diagnostic runs.
/// Timing acceptance runs must leave BUTTER_STORAGE_DIAGNOSTICS unset.
public enum StorageDiagnostics {
	public static let enabled = ProcessInfo.processInfo.environment["BUTTER_STORAGE_DIAGNOSTICS"] == "1"
	public enum Counter: String, Sendable {
		case scans, filesInspected, descriptorOpens, diskJobs, bytesRead, bytesWritten
		case bytesHashed, sha1Bytes, sha256Bytes, cacheHits, verificationInvalidations
	}
	private static let totals = Totals()
	public static func count(_ counter: Counter, _ amount: Int = 1) {
		guard enabled else { return }; totals.add(counter.rawValue, Int64(amount))
	}
	static func io(read: Bool, bytes: Int) {
		guard enabled else { return }
		let bucket = bytes <= 1 ? 0 : Int.bitWidth - (bytes - 1).leadingZeroBitCount
		totals.add((read ? "readSizePower2_" : "writeSizePower2_") + String(bucket), 1)
		count(read ? .bytesRead : .bytesWritten, bytes)
	}
	public static func snapshot() -> [String: Int64] { totals.snapshot() }
	private final class Totals: @unchecked Sendable {
		private let lock = NSLock()
		private var values: [String: Int64] = [:]
		func add(_ key: String, _ amount: Int64) { lock.withLock { values[key, default: 0] += amount } }
		func snapshot() -> [String: Int64] { lock.withLock { values } }
	}
}
