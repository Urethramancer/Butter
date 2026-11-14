import Foundation
import Darwin

/// StorageDiagnostics supplies opt-in aggregate counters for diagnostic runs.
/// Timing acceptance runs must leave BUTTER_STORAGE_DIAGNOSTICS unset.
public enum StorageDiagnostics {
	public static let enabled = ProcessInfo.processInfo.environment["BUTTER_STORAGE_DIAGNOSTICS"] == "1"
	public enum Counter: String, Sendable {
		case scans, filesInspected, descriptorOpens, diskJobs, bytesRead, bytesWritten
		case bytesHashed, sha1Bytes, sha256Bytes, cacheHits, verificationInvalidations
		case cacheLoads, cacheLoadJoins, cacheEvictions, cacheLoadedBytes, cacheEvictedBytes
		case descriptorDuplicates, writeBatches, writeBlocks, writeDescriptorCacheHits
		case fileDescriptorInspections
		case contiguousWriteRanges
		case pathValidationCacheHits, pathValidationCacheMisses
	}
	enum OpenKind: String { case directoryOpens, fileOpens, atomicStateOpens }
	private static let totals = Totals()
	static func mergeWriteProfile(_ values: [String: Int64]) { totals.merge(values, prefix: "writeProfile.") }
	static func opened(_ kind: OpenKind) {
		guard enabled else { return }; totals.opened(kind.rawValue)
	}
	public static func count(_ counter: Counter, _ amount: Int = 1) {
		guard enabled else { return }; totals.add(counter.rawValue, Int64(amount))
	}
	static func io(read: Bool, bytes: Int) {
		guard enabled else { return }
		let bucket = bytes <= 1 ? 0 : Int.bitWidth - (bytes - 1).leadingZeroBitCount
		totals.add((read ? "readSizePower2_" : "writeSizePower2_") + String(bucket), 1)
		count(read ? .bytesRead : .bytesWritten, bytes)
	}
	private static let clockCalibration = StorageWriteProfile.timings ? StorageWriteProfile.calibration() : [:]
	public static func snapshot() -> [String: Int64] { totals.snapshot().merging(clockCalibration) { first, _ in first } }
	private final class Totals: @unchecked Sendable {
		private let lock = NSLock()
		private var values: [String: Int64] = [:]
		func opened(_ kind: String) {
			lock.withLock { values["descriptorOpens", default: 0] += 1; values[kind, default: 0] += 1 }
		}
		func add(_ key: String, _ amount: Int64) { lock.withLock { values[key, default: 0] += amount } }
		func merge(_ additions: [String: Int64], prefix: String) { lock.withLock { for (key, value) in additions { values[prefix + key, default: 0] += value } } }
		func snapshot() -> [String: Int64] { lock.withLock { values } }
	}
}
