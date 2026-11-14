import Foundation
import Darwin
import ButterTorrentStorage

/// ReceivePipelineDiagnostics supplies aggregate receive-path diagnostics, never payload traces.
public enum ReceivePipelineDiagnostics {
	public static let enabled = StorageDiagnostics.enabled
	static let timed = enabled && ProcessInfo.processInfo.environment["BUTTER_RECEIVE_PIPELINE_TIMINGS"] == "1"
	private static let totals = Totals()
	public static func snapshot() -> [String: Int64] { totals.snapshot() }
	static func merge(_ values: [String: Int64]) { totals.merge(values) }
	static func now() -> UInt64 {
		let saved = errno; defer { errno = saved }
		return clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
	}
	static func tick() -> UInt64? { timed ? now() : nil }
	static func sample(_ kind: ReceivePipelineSample.Kind, started: UInt64? = nil) -> ReceivePipelineSample? {
		guard enabled else { return nil }
		return ReceivePipelineSample(kind: kind, timed: timed, started: started)
	}
	private final class Totals: @unchecked Sendable {
		private let lock = NSLock()
		private var values: [String: Int64] = [:]
		func merge(_ additions: [String: Int64]) { lock.withLock { for (key, amount) in additions { values[key, default: 0] += amount } } }
		func snapshot() -> [String: Int64] { lock.withLock { values } }
	}
}

// One receive cycle or payload dispatch. Stage intervals must not overlap within
// a sample. Separate reader/dispatch budgets intentionally describe nested work.
final class ReceivePipelineSample: @unchecked Sendable {
	enum Kind: String { case reader, dispatch, terminalRead }
	enum Stage: String { case readAdmission, streamRead, dispatch, controlDispatch, schedulerYield, actorEntry, rateAdmission, diskAdmission, storageWrite, verification, diskRelease }
	enum Flush: String { case readEnd, control, budget, yield, error }
	private let lock = NSLock()
	private let kind: Kind
	private let timed: Bool
	private let clock: @Sendable () -> UInt64
	private let sink: @Sendable ([String: Int64]) -> Void
	private let started: UInt64?
	private var values: [String: Int64] = [:]
	private var stageElapsed: Int64 = 0
	private var entered = false
	private var finished = false
	init(kind: Kind, timed: Bool, started: UInt64? = nil, clock: @escaping @Sendable () -> UInt64 = ReceivePipelineDiagnostics.now,
		sink: @escaping @Sendable ([String: Int64]) -> Void = ReceivePipelineDiagnostics.merge) {
		self.kind = kind; self.timed = timed; self.clock = clock; self.sink = sink
		self.started = timed ? (started ?? clock()) : nil
	}
	func tick() -> UInt64? { timed ? clock() : nil }
	func count(_ key: String, _ amount: Int = 1) { lock.withLock { values[key, default: 0] += Int64(amount) } }
	func histogram(_ name: String, _ amount: Int) {
		lock.withLock { histogramLocked(name, amount) }
	}
	private func histogramLocked(_ name: String, _ amount: Int) {
		let bucket = amount <= 1 ? 0 : Int.bitWidth - (amount - 1).leadingZeroBitCount
		values[name + ".count", default: 0] += 1; values[name + ".sum", default: 0] += Int64(amount)
		values[name + ".power2." + String(bucket), default: 0] += 1
	}
	func end(_ stage: Stage, since start: UInt64?, until suppliedEnd: UInt64? = nil) {
		let end = suppliedEnd ?? tick()
		lock.withLock {
			values["stage.\(stage.rawValue).calls", default: 0] += 1
			if let start, let end {
				let elapsed = Int64(end - start)
				values["stage.\(stage.rawValue).elapsedNs", default: 0] += elapsed; stageElapsed += elapsed
				histogramLocked("stage.\(stage.rawValue).durationNs", Int(elapsed))
			}
		}
	}
	func enteredEngine() {
		lock.withLock {
			guard !entered else { return }; entered = true
			values["stage.actorEntry.calls", default: 0] += 1
			if let started {
				let elapsed = Int64(clock() - started)
				values["stage.actorEntry.elapsedNs", default: 0] += elapsed; stageElapsed += elapsed
				histogramLocked("stage.actorEntry.durationNs", Int(elapsed))
			}
		}
	}
	func finish(_ outcome: String) {
		let result: [String: Int64]? = lock.withLock {
			guard !finished else { return nil }; finished = true
			values["samples", default: 0] += 1; values["outcome." + outcome, default: 0] += 1
			if kind == .reader { histogramLocked("blocksPerRead", Int(values["decodedBlocks", default: 0])) }
			if let started {
				let total = Int64(clock() - started)
				values["total.elapsedNs"] = total; values["other.elapsedNs"] = total - stageElapsed
				if stageElapsed > total { values["overlapErrors"] = 1 }
				histogramLocked("durationNs", Int(total))
			}
			return Dictionary(uniqueKeysWithValues: values.map { (kind.rawValue + "." + $0.key, $0.value) })
		}
		if let result { sink(result) }
	}
}
