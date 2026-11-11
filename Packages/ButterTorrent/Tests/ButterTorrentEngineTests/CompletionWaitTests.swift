import Foundation
import Testing
import ButterTorrentNetworking
@testable import ButterTorrentEngine

@Suite struct CompletionWaitTests {
	@Test func completionBeforeAndAfterRegistration() async throws {
		try await transferFixture { fixture in
			let seed = try await fixture.transfer("seed", seed: true)
			try await engineDeadline { try await seed.waitUntilComplete() }
			let down = try await fixture.transfer("download")
			let waiters = (0..<8).map { _ in Task { try await down.waitUntilComplete() } }
			try await eventually { await down.completionWaiters.count == 8 }
			try await fixture.join(down, seed)
			for waiter in waiters { try await engineDeadline { try await waiter.value } }
			#expect(await down.completionWaiters.isEmpty)
			try await down.waitUntilComplete()
		}
	}
	@Test func cancellationAndDisconnectDoNotConsumeOtherWaiters() async throws {
		try await transferFixture { fixture in
			let down = try await fixture.transfer("download")
			let cancelled = Task { try await down.waitUntilComplete() }
			let retained = Task { try await down.waitUntilComplete() }
			try await eventually { await down.completionWaiters.count == 2 }
			cancelled.cancel()
			await #expect(throws: CancellationError.self) { try await cancelled.value }
			await down.disconnectPeers()
			#expect(await down.completionWaiters.count == 1)
			let seed = try await fixture.transfer("seed", seed: true)
			try await fixture.join(down, seed)
			try await engineDeadline { try await retained.value }
		}
	}
	@Test(arguments: [false, true]) func storageFailureAndShutdownSettleWaiters(_ diskFailure: Bool) async throws {
		try await transferFixture { fixture in
			let down = try await fixture.transfer("download")
			let waiters = (0..<8).map { _ in Task { try await down.waitUntilComplete() } }
			try await eventually { await down.completionWaiters.count == 8 }
			if diskFailure { await down.diskFailed(PeerFailure.invalid("disk fixture")) }
			else { try await down.shutdown() }
			for waiter in waiters { await #expect(throws: (any Error).self) { try await waiter.value } }
			await #expect(throws: (any Error).self) { try await down.waitUntilComplete() }
			#expect(await down.completionWaiters.isEmpty)
		}
	}
	@Test func cancellationRacesRegistrationAndShutdown() async throws {
		try await transferFixture { fixture in
			let down = try await fixture.transfer("download")
			let waiters = (0..<64).map { _ in Task { try await down.waitUntilComplete() } }
			for waiter in waiters { waiter.cancel() }
			try await down.shutdown()
			for waiter in waiters { await #expect(throws: (any Error).self) { try await waiter.value } }
			#expect(await down.completionWaiters.isEmpty)
		}
	}
}
