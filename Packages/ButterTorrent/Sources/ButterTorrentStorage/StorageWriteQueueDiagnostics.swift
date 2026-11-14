import Foundation
import Darwin

// Captured before worker admission setup, then measured at worker entry. Includes
// submission setup, excludes transfer permits and the storage actor hop. Recorder
// setup stays outside the admission-to-enqueue window. Queued cancellations count.
struct StorageWriteQueueProfile: Sendable {
	let submitted: UInt64?
	private static let timed = StorageDiagnostics.enabled && ProcessInfo.processInfo.environment["BUTTER_RECEIVE_PIPELINE_TIMINGS"] == "1"
	static func make(forWrite: Bool) -> StorageWriteQueueProfile? {
		guard forWrite && StorageDiagnostics.enabled else { return nil }
		return StorageWriteQueueProfile(submitted: timed ? now() : nil)
	}
	private static func now() -> UInt64 {
		let saved = errno; defer { errno = saved }
		return clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
	}
	func began() -> UInt64? { submitted == nil ? nil : Self.now() }
	func values(started: UInt64?) -> [String: Int64] {
		var values: [String: Int64] = ["jobs": 1]
		if let submitted, let started { values["elapsedNs"] = Int64(started - submitted) }
		return values
	}
	func finish(started: UInt64?) { StorageDiagnostics.mergeWriteQueue(values(started: started)) }
}
