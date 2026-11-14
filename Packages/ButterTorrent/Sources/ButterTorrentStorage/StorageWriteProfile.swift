import Foundation
import Darwin

// Confined to one synchronous disk job. No thread-local state or per-block locks.
final class StorageWriteProfile {
	enum Phase: String { case setup, targetInspection, progressInvalidation, packing, descriptorAcquisition, prewriteChecks, fullScan, payloadSyscall, postwriteStamping, cleanup }
	struct Tick {
		let elapsed: Int64
		let cpu: Int64
		static func read() -> Tick {
			Tick(elapsed: Int64(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)), cpu: Int64(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)))
		}
	}
	static let timings = StorageDiagnostics.enabled && ProcessInfo.processInfo.environment["BUTTER_STORAGE_WRITE_TIMINGS"] == "1"
	private let timed: Bool
	private let clock: () -> Tick
	private let started: Tick?
	private var previous: Tick?
	private(set) var values: [String: Int64] = [:]
	private var phase: Phase?
	private var finished = false
	init(timed: Bool, clock: @escaping () -> Tick = Tick.read) {
		let saved = errno; defer { errno = saved }
		self.timed = timed; self.clock = clock
		started = timed ? clock() : nil; previous = started
	}
	static func make() -> StorageWriteProfile? {
		let saved = errno; defer { errno = saved }
		guard StorageDiagnostics.enabled else { return nil }
		return StorageWriteProfile(timed: timings)
	}
	func count(_ key: String, _ amount: Int = 1) {
		let saved = errno; defer { errno = saved }
		values[key, default: 0] += Int64(amount)
	}
	func histogram(_ name: String, _ value: Int) {
		let saved = errno; defer { errno = saved }
		let bucket = value <= 1 ? 0 : Int.bitWidth - (value - 1).leadingZeroBitCount
		count(name + "Power2_" + String(bucket)); count(name + "Sum", value); count(name + "Count")
	}
	@discardableResult func enter(_ next: Phase?) -> Phase? {
		let saved = errno; defer { errno = saved }
		let old = phase
		if timed, let previous {
			let now = clock()
			if let old {
				values["phase.\(old.rawValue).elapsedNs", default: 0] += now.elapsed - previous.elapsed
				values["phase.\(old.rawValue).cpuNs", default: 0] += now.cpu - previous.cpu
			}
		}
		phase = next
		if let next { count("phase.\(next.rawValue).calls") }
		previous = timed ? clock() : nil
		return old
	}
	func valuesForScan(_ origin: String, suffix: String, before: (cpu: Int64, elapsed: Int64)) {
		guard timed else { return }
		let saved = errno; defer { errno = saved }
		let key = "phase.fullScan.\(suffix)"
		values["scan.\(origin).\(suffix)", default: 0] += values[key, default: 0] - (suffix == "cpuNs" ? before.cpu : before.elapsed)
	}
	func finishScan() {
		let saved = errno; defer { errno = saved }
		StorageDiagnostics.mergeWriteProfile(values.filter { $0.key.hasPrefix("scan.") })
	}
	static func calibration() -> [String: Int64] {
		let saved = errno; defer { errno = saved }
		var result: [String: Int64] = [:]
		for (name, clock) in [("elapsed", CLOCK_MONOTONIC_RAW), ("cpu", CLOCK_THREAD_CPUTIME_ID)] {
			var resolution = timespec(); clock_getres(clock, &resolution)
			result["clock.\(name).resolutionNs"] = Int64(resolution.tv_sec) * 1_000_000_000 + Int64(resolution.tv_nsec)
			let start = Tick.read()
			for _ in 0..<10_000 { _ = clock_gettime_nsec_np(clock) }
			let end = Tick.read()
			result["clock.\(name).calibrationReads"] = 10_000
			result["clock.\(name).readElapsedNs"] = end.elapsed - start.elapsed
			result["clock.\(name).readCpuNs"] = end.cpu - start.cpu
		}
		return result
	}
	func finish(outcome: String) {
		guard !finished else { return }; finished = true
		let saved = errno; defer { errno = saved }
		enter(nil); count("jobs"); count(outcome)
		if let started {
			let end = clock(), elapsed = end.elapsed - started.elapsed, cpu = end.cpu - started.cpu
			values["job.elapsedNs"] = elapsed; values["job.cpuNs"] = cpu
			values["remainder.elapsedNs"] = elapsed - values.filter { $0.key.hasPrefix("phase.") && $0.key.hasSuffix(".elapsedNs") }.values.reduce(0, +)
			values["remainder.cpuNs"] = cpu - values.filter { $0.key.hasPrefix("phase.") && $0.key.hasSuffix(".cpuNs") }.values.reduce(0, +)
			histogram("jobDurationNs", Int(elapsed))
		}
		StorageDiagnostics.mergeWriteProfile(values)
	}
}
