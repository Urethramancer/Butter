import Foundation
import Testing
@testable import ButterTorrentEngine

@Suite struct PeerReadAheadTests {
	@Test(arguments: [1, 65536, 131072, 262143]) func pendingReadSharesTheExistingRawByteBudget(_ retained: Int) async throws {
		let reader = PeerReadAhead()
		let capacity = try #require(reader.prefetch(retainedBytes: retained) { Data(count: $0) })
		#expect(retained + capacity == PeerReadAhead.maximumBytes)
		#expect(reader.prefetch(retainedBytes: retained) { _ in Issue.record("Second read was admitted"); return Data() } == nil)
		let task = try #require(reader.take())
		#expect(try await task.value.count == capacity)
		#expect(reader.take() == nil)
		await reader.drain()
		#expect(reader.prefetch(retainedBytes: retained) { _ in Issue.record("Read was admitted after cancellation"); return Data() } == nil)
	}
	@Test(arguments: [-1, 0, 262144, 262145]) func exhaustedOrInvalidBudgetsDoNotRead(_ retained: Int) async {
		let reader = PeerReadAhead()
		#expect(reader.prefetch(retainedBytes: retained) { _ in Issue.record("Invalid read budget was admitted"); return Data() } == nil)
		await reader.drain()
	}
	@Test func cancellationDrainsThePendingRead() async throws {
		let reader = PeerReadAhead(), entered = AsyncStream<Void>.makeStream()
		#expect(reader.prefetch(retainedBytes: 65536) { _ in
			entered.continuation.yield(())
			try await Task.sleep(for: .seconds(60)); return Data()
		} != nil)
		try await engineDeadline { for await _ in entered.stream { return }; throw PeerFailure.closed }
		reader.cancel()
		try await engineDeadline { await reader.drain() }
		#expect(reader.take() == nil)
	}
}
