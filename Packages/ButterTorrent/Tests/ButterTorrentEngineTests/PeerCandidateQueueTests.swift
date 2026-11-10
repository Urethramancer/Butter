import Foundation
import Testing
@testable import ButterTorrentEngine

@Suite struct PeerCandidateQueueTests {
	@Test func excessCandidatesStayBoundedAndPendingDuplicatesAreCoalesced() async throws {
		let recorder = CandidateRecorder(), queue = PeerCandidateQueue<Int> { await recorder.connect($0) }
		await queue.enqueue(Array(0..<3000) + Array(0..<3000))
		try await eventually { await recorder.calls.count == 2000 }
		await queue.stop()
		let calls = await recorder.calls
		#expect(calls.count == 2000 && Set(calls).count == 2000)
	}
	@Test func stoppingCancelsBothConnectorsAndRejectsLaterCandidates() async throws {
		let recorder = CandidateRecorder(blocked: true), queue = PeerCandidateQueue<Int> { await recorder.connect($0) }
		await queue.enqueue(Array(0..<3000))
		try await eventually { await recorder.active == 2 }
		await queue.stop(); await queue.enqueue([4000]); await queue.stop()
		#expect(await recorder.active == 0); #expect(await recorder.calls.count == 2); #expect(await recorder.cancelled == 2)
	}
}

private actor CandidateRecorder {
	let blocked: Bool
	var calls: [Int] = []
	var active = 0
	var cancelled = 0
	init(blocked: Bool = false) { self.blocked = blocked }
	func connect(_ item: Int) async {
		calls.append(item); active += 1; defer { active -= 1 }
		if blocked { do { try await Task.sleep(for: .seconds(60)) } catch { cancelled += 1 } }
	}
}
