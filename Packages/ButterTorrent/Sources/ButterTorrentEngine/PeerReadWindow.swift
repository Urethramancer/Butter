import Foundation

// One reader owns each sample. The elapsed interval includes local work, but
// only waits inside a stream read count towards the stall fraction.
struct PeerReadWindow {
	private var since: TimeInterval?
	private var stalls = 0
	private var stalled: TimeInterval = 0
	private var bytes = 0

	mutating func record(start: TimeInterval, end: TimeInterval, payload: Int) -> Int? {
		let first = since ?? start
		since = first
		bytes += payload
		let wait = end - start
		if wait >= 0.003 { stalls += 1; stalled += wait }
		let elapsed = end - first
		guard elapsed >= 0.25 else { return nil }
		defer { since = end; stalls = 0; stalled = 0; bytes = 0 }
		guard stalls >= 3, stalled >= elapsed * 0.25 else { return 32 }
		// Cover 50 ms of delivered payload, bounded by the tested wire windows.
		let blocks = Double(bytes) * 0.05 / (elapsed * 16_384)
		return Int(min(48, max(32, blocks.rounded(.up))))
	}
}
