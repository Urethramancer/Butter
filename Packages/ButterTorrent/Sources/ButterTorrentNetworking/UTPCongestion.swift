import Foundation

struct UTPCongestion: Sendable {
	var window: Double = 2360
	var packetSize = 1180
	var rtt: TimeInterval?
	var variance: TimeInterval = 0
	var timeout: TimeInterval = 1
	var backoff = 0
	private var bases: [(TimeInterval, UInt32)] = []
	private var samples: [UInt32] = []
	private var lastLoss: TimeInterval = -.infinity
	mutating func sampleRTT(_ elapsed: TimeInterval) {
		guard elapsed >= 0, elapsed < 120 else { return }
		if let rtt { variance += (abs(rtt - elapsed) - variance) / 4; self.rtt = rtt + (elapsed - rtt) / 8 }
		else { rtt = elapsed; variance = elapsed / 2 }
		timeout = min(8, max(0.5, rtt! + variance * 4))
	}
	mutating func acknowledged(bytes: Int, delay: UInt32, now: TimeInterval) {
		backoff = 0
		guard bytes > 0, delay != 0 else { return }
		let bucket = floor(now / 10) * 10
		bases.removeAll { now - $0.0 >= 120 }
		if let last = bases.last, last.0 == bucket {
			if Int32(bitPattern: delay &- last.1) < 0 { bases[bases.count - 1].1 = delay }
		} else { bases.append((bucket, delay)) }
		guard let baseline = bases.map(\.1).min(by: { Int32(bitPattern: $0 &- $1) < 0 }) else { return }
		let measured = max(0, Int64(Int32(bitPattern: delay &- baseline)))
		samples.append(UInt32(min(Int64(UInt32.max), measured))); if samples.count > 3 { samples.removeFirst() }
		let queue = Double(samples.min() ?? 0), factor = max(-1, min(1, (100_000 - queue) / 100_000))
		window = max(130, min(262_144, window + 1180 * factor * Double(bytes) / max(1180, window)))
		packetSize = min(1180, max(130, Int(window / 2)))
	}
	mutating func lost(now: TimeInterval, timedOut: Bool) {
		if now - lastLoss >= max(0.1, rtt ?? 0.1) { window = max(130, window / 2); lastLoss = now }
		if timedOut { window = 130; packetSize = 130; backoff = min(4, backoff + 1) }
	}
	var retransmitAfter: TimeInterval { min(8, timeout * pow(2, Double(backoff))) }
}
