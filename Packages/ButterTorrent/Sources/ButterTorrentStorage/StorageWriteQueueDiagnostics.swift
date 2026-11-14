import Foundation
import Darwin

// Captured before worker admission setup, then measured at worker entry. Includes
// submission setup, excludes transfer permits and the storage actor hop. Recorder
// setup stays outside the admission-to-enqueue window. Queued cancellations count.
struct StorageWriteQueueProfile: Sendable {
	let submitted: UInt64?
	static let timed = StorageDiagnostics.enabled && ProcessInfo.processInfo.environment["BUTTER_RECEIVE_PIPELINE_TIMINGS"] == "1"
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

// These scopes never cross an await: thread CPU is meaningful alongside elapsed
// time. Verification includes nested checkpoints; report them as nested budgets.
struct StorageSynchronousProfile {
	enum Kind: String { case verification, verificationInWrite, checkpointInVerification, checkpointOther }
	let kind: Kind
	let started: StorageWriteProfile.Tick?
	static func make(_ kind: Kind) -> StorageSynchronousProfile? {
		let saved = errno; defer { errno = saved }
		guard StorageDiagnostics.enabled else { return nil }
		return StorageSynchronousProfile(kind: kind, started: StorageWriteQueueProfile.timed ? .read() : nil)
	}
	func values(ended: StorageWriteProfile.Tick?) -> [String: Int64] {
		var values: [String: Int64] = ["calls": 1]
		if let started, let ended {
			let elapsed = ended.elapsed - started.elapsed
			values["elapsedNs"] = elapsed; values["cpuNs"] = ended.cpu - started.cpu
			let bucket = elapsed <= 1 ? 0 : Int64.bitWidth - (elapsed - 1).leadingZeroBitCount
			values["durationNsPower2_" + String(bucket)] = 1
		}
		return values
	}
	func finish() {
		let saved = errno; defer { errno = saved }
		StorageDiagnostics.mergeSynchronous(values(ended: started == nil ? nil : .read()), kind: kind.rawValue)
	}
}

extension StorageState {
	func beginVerificationProfile(_ kind: StorageSynchronousProfile.Kind = .verification) -> StorageSynchronousProfile? {
		guard diagnosticVerificationDepth == 0 else { return nil }
		let profile = StorageSynchronousProfile.make(kind)
		if profile != nil { diagnosticVerificationDepth += 1 }
		return profile
	}
	func finishVerificationProfile(_ profile: StorageSynchronousProfile?) {
		guard let profile else { return }
		diagnosticVerificationDepth -= 1; profile.finish()
	}
}
