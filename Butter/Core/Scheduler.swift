import Foundation

// A single coordinator owns admission and bandwidth decisions. libtorrent auto-management is disabled.
struct TransferObservation {
	var id: String
	var order: Int
	var priority: TransferPriority
	var wanted: Bool
	var force: Bool
	var complete: Bool
	var blocked: Bool
	var downloadRate: Int
	var uploadRate: Int
	var downloadDemand: Bool
	var uploadDemand: Bool
}
struct ScheduleDecision: Equatable {
	var running: Bool
	// Zero means unrestricted to libtorrent; a blocked direction receives a small allowance.
	var downloadLimit: Int = 0
	var uploadLimit: Int = 0
}
struct CapacityEstimator {
	private var observations: [(TimeInterval, Double)] = []
	private var started: TimeInterval?
	private(set) var estimate: Double = 0
	mutating func observe(rate: Int, demand: Bool, now: TimeInterval) -> Bool {
		if started == nil { started = now }
		observations.removeAll { now - $0.0 > 120 }
		if rate > 0 && demand { observations.append((now, Double(rate))) }
		let peak = observations.map(\.1).max() ?? 0
		if peak > 0 { estimate = max(16_384, peak * 1.15) }
		// Five unrestricted seconds every thirty seconds allow recovery from underestimation.
		return Int(max(0, now - (started ?? now))) % 30 < 5 || estimate == 0
	}
}
struct TransferScheduler {
	var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
	private var downloadCapacity = CapacityEstimator()
	private var uploadCapacity = CapacityEstimator()
	private var idleSince: [String: TimeInterval] = [:]
	mutating func stoppedSeeds(_ observations: [TransferObservation], idleMinutes: Int) -> Set<String> {
		let now = clock(); var stopped = Set<String>()
		let valid = Set(observations.map(\.id)); idleSince = idleSince.filter { valid.contains($0.key) }
		for t in observations {
			guard idleMinutes > 0 && t.wanted && t.complete && !t.blocked else { idleSince[t.id] = nil; continue }
			if t.uploadDemand || t.uploadRate > 0 { idleSince[t.id] = nil }
			else { if idleSince[t.id] == nil { idleSince[t.id] = now }; if now - idleSince[t.id]! >= Double(idleMinutes * 60) { stopped.insert(t.id) } }
		}
		return stopped
	}
	mutating func schedule(_ observations: [TransferObservation], downloads: Int, seeds: Int) -> [String: ScheduleDecision] {
		let sorted = observations.sorted { $0.priority != $1.priority ? $0.priority.rawValue > $1.priority.rawValue : $0.order < $1.order }
		var result = Dictionary(uniqueKeysWithValues: observations.map { ($0.id, ScheduleDecision(running: false)) })
		var downloadCount = 0, seedCount = 0
		for t in sorted where t.wanted && !t.blocked {
			let count = t.complete ? seedCount : downloadCount
			let limit = t.complete ? seeds : downloads
			if t.force || count < max(0, limit) {
				result[t.id]?.running = true
				if !t.force { if t.complete { seedCount += 1 } else { downloadCount += 1 } }
			}
		}
		let running = sorted.filter { result[$0.id]?.running == true }
		let now = clock()
		let downProbe = downloadCapacity.observe(rate: running.reduce(0) { $0 + $1.downloadRate }, demand: running.contains { $0.downloadDemand }, now: now)
		let upProbe = uploadCapacity.observe(rate: running.reduce(0) { $0 + $1.uploadRate }, demand: running.contains { $0.uploadDemand }, now: now)
		let down = allocate(running.filter { !$0.complete && $0.downloadDemand }, capacity: downloadCapacity.estimate, probe: downProbe, upload: false)
		let up = allocate(running.filter { $0.uploadDemand }, capacity: uploadCapacity.estimate, probe: upProbe, upload: true)
		for t in running { result[t.id]?.downloadLimit = down[t.id] ?? 0; result[t.id]?.uploadLimit = up[t.id] ?? 0 }
		return result
	}
	private func allocate(_ transfers: [TransferObservation], capacity: Double, probe: Bool, upload: Bool) -> [String: Int] {
		guard transfers.count > 1 && !probe else { return [:] }
		var remaining = capacity, result: [String: Int] = [:]
		for priority in TransferPriority.allCases.reversed() {
			let tier = transfers.filter { $0.priority == priority }
			guard !tier.isEmpty else { continue }
			var pending = tier
			while !pending.isEmpty {
				let share = max(1, remaining / Double(pending.count))
				let satisfied = pending.filter { Double(max(1024, (upload ? $0.uploadRate : $0.downloadRate))) * 1.25 < share }
				if satisfied.isEmpty {
					for t in pending { result[t.id] = max(1, Int(share)) }
					remaining = max(0, remaining - share * Double(pending.count)); break
				}
				for t in satisfied {
					let amount = Double(max(1024, upload ? t.uploadRate : t.downloadRate)) * 1.25
					result[t.id] = Int(amount); remaining = max(0, remaining - amount)
				}
				let ids = Set(satisfied.map(\.id)); pending.removeAll { ids.contains($0.id) }
			}
		}
		return result
	}
}
