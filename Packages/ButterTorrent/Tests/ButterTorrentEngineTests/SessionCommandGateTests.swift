import Testing
@testable import ButterTorrentEngine

@Suite struct SessionCommandGateTests {
	@Test func independentTransfersOverlapAndQueuedBarriersStayFairUnderCancellation() async throws {
		let gate = SessionCommandGate(), first = try await gate.acquire("first"), second = try await gate.acquire("second")
		let duplicate = Task { try await gate.acquire("first") }
		try await eventually { await gate.waitingCount == 1 }
		let barrier = Task { try await gate.acquire() }
		try await eventually { await gate.waitingCount == 2 }
		let independent = Task { try await gate.acquire("third") }
		try await eventually { await gate.waitingCount == 3 }
		#expect(await gate.tryAcquire("fourth") == nil)
		duplicate.cancel(); await #expect(throws: CancellationError.self) { try await duplicate.value }
		await gate.release(first); await gate.release(second)
		let exclusive = try await barrier.value
		#expect(await gate.waitingCount == 1)
		#expect(await gate.tryAcquire("first") == nil)
		await gate.release(exclusive)
		let third = try await independent.value
		#expect(await gate.waitingCount == 0)
		await gate.release(third)
		let final = try #require(await gate.tryAcquire()); await gate.release(final)
	}
	@Test func cancellingABarrierReleasesUnrelatedWaitersWithoutReleasingBusyTransfers() async throws {
		let gate = SessionCommandGate(), busy = try await gate.acquire("busy")
		let barrier = Task { try await gate.acquire() }
		try await eventually { await gate.waitingCount == 1 }
		let unrelated = Task { try await gate.acquire("other") }
		try await eventually { await gate.waitingCount == 2 }
		barrier.cancel(); await #expect(throws: CancellationError.self) { try await barrier.value }
		let other = try await unrelated.value
		#expect(await gate.tryAcquire("busy") == nil)
		await gate.release(other); await gate.release(busy)
	}
}
