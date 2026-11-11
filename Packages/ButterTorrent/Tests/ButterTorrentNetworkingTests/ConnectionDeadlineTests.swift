import Foundation
import Testing
@testable import ButterTorrentNetworking

private final class RecordedDeadlineClock: TransportClock, @unchecked Sendable {
	let base = ManualTransportClock()
	private let lock = NSLock()
	private var calls = 0
	var sleeps: Int { lock.withLock { calls } }
	func now() -> TimeInterval { base.now() }
	func sleep(for seconds: TimeInterval) async throws {
		lock.withLock { calls += 1 }; try await base.sleep(for: seconds)
	}
}
private struct FailedDeadlineClock: TransportClock {
	func now() -> TimeInterval { 0 }
	func sleep(for seconds: TimeInterval) async throws { throw NetworkFailure.invalid("clock failure") }
}
private struct InvalidDeadlineClock: TransportClock {
	func now() -> TimeInterval { .nan }
	func sleep(for seconds: TimeInterval) async throws { Issue.record("Invalid clock started a timer") }
}

@Suite struct ConnectionDeadlineTests {
	@Test func reusesOneTimerAcrossCompletedIOWithoutLosingTheFinalDeadline() async throws {
		let clock = RecordedDeadlineClock(), deadlines = ConnectionDeadlines(clock: clock), first = UUID()
		defer { deadlines.close(NetworkFailure.closed) }
		try deadlines.insert(first, timeout: 30) { _ in Issue.record("Completed operation expired") }
		try await clock.base.waitForSleep(30); deadlines.remove(first)
		for _ in 0..<1000 {
			let id = UUID(); try deadlines.insert(id, timeout: 30) { _ in Issue.record("Removed operation expired") }; deadlines.remove(id)
		}
		#expect(clock.sleeps == 1)
		let waiter = NetworkWaiter<Void>(), last = UUID()
		try deadlines.insert(last, timeout: 30) { waiter.resolve(.failure($0)) }
		clock.base.advance(30)
		await #expect(throws: NetworkFailure.timedOut) { try await deadline { try await waiter.value() } }
	}
	@Test func anEarlierDeadlineSupersedesTheTimerWithoutExpiringALaterOperation() async throws {
		let clock = RecordedDeadlineClock(), deadlines = ConnectionDeadlines(clock: clock), first = UUID(), earlier = UUID()
		defer { deadlines.close(NetworkFailure.closed) }
		let waiter = NetworkWaiter<Void>()
		try deadlines.insert(first, timeout: 30) { waiter.resolve(.failure($0)) }
		try await clock.base.waitForSleep(30)
		try deadlines.insert(earlier, timeout: 10) { _ in Issue.record("Removed early operation expired") }
		try await clock.base.waitForSleep(10); deadlines.remove(earlier)
		clock.base.advance(10); try await clock.base.waitForSleep(20)
		#expect(waiter.isPending)
		clock.base.advance(20)
		await #expect(throws: NetworkFailure.timedOut) { try await deadline { try await waiter.value() } }
	}
	@Test func closeCompletionAndCancellationSettleOnce() async throws {
		for _ in 0..<32 {
			let deadlines = ConnectionDeadlines(clock: ContinuousTransportClock()), waiter = NetworkWaiter<Void>(), id = UUID()
			try deadlines.insert(id, timeout: 30) { waiter.resolve(.failure($0)) }
			let waiting = Task { try await waiter.value() }
			await withTaskGroup(of: Void.self) { group in
				group.addTask { deadlines.close(NetworkFailure.closed) }
				group.addTask { waiter.resolve(.success(())) }
				group.addTask { waiting.cancel() }
			}
			do { try await deadline { try await waiting.value } }
			catch { #expect(error is CancellationError || error as? NetworkFailure == .closed) }
			#expect(!waiter.isPending)
			#expect(throws: NetworkFailure.closed) { try deadlines.insert(UUID(), timeout: 30) { _ in } }
		}
	}
	@Test func clockFailureAndInvalidDeadlinesCannotLeavePendingIO() async throws {
		let invalid = ConnectionDeadlines(clock: InvalidDeadlineClock())
		defer { invalid.close(NetworkFailure.closed) }
		#expect(throws: NetworkFailure.invalid("deadline clock")) { try invalid.insert(UUID(), timeout: 1) { _ in } }
		let deadlines = ConnectionDeadlines(clock: FailedDeadlineClock()), waiter = NetworkWaiter<Void>()
		defer { deadlines.close(NetworkFailure.closed) }
		for timeout in [0, -1, .infinity, .nan, 86401] {
			#expect(throws: NetworkFailure.invalid("deadline")) { try deadlines.insert(UUID(), timeout: timeout) { _ in } }
		}
		try deadlines.insert(UUID(), timeout: 1) { waiter.resolve(.failure($0)) }
		await #expect(throws: NetworkFailure.invalid("clock failure")) { try await deadline { try await waiter.value() } }
		#expect(throws: NetworkFailure.invalid("clock failure")) { try deadlines.insert(UUID(), timeout: 1) { _ in } }
	}
}
