import Foundation
import Testing
@testable import ButterTorrentNetworking

@Suite struct MSEWorkerTests {
	@Test func workerAndQueueBoundsCancellationAndQueuedDeadline() async throws {
		let workers = MSEWorkers()
		// Reserve admission directly so the fixture also works on machines with fewer than four cores.
		for _ in 0..<4 { try await workers.acquire() }
		var queued: [Task<Int, Error>] = []
		do {
			queued = (0..<64).map { _ in Task { try await workers.run { 0 } } }
			try await deadline { while await workers.waitingCount < 64 { try await Task.sleep(for: .milliseconds(1)) } }
			await #expect(throws: NetworkFailure.limit("MSE arithmetic workers")) { try await workers.run { 0 } }
			for task in queued { task.cancel() }
			for task in queued { await #expect(throws: CancellationError.self) { try await task.value } }
			#expect(await workers.waitingCount == 0)
			let listener = try await TCPListener.listen(address: IPAddress("127.0.0.1")), raw = try await TCPStream.connect(to: NetworkEndpoint("127.0.0.1", port: listener.port)), peer = try await listener.accept(timeout: 3)
			let clock = ManualTransportClock()
			var setup = MSEHandshake(stream: raw, clock: clock, deadline: clock.now() + 1, configuration: .init()); setup.workers = workers
			let handshake = setup
			let calculation = Task { try await handshake.calculate { 0 } }
			try await clock.waitForSleep(1); clock.advance(1)
			await #expect(throws: NetworkFailure.timedOut) { try await calculation.value }
			#expect(await workers.waitingCount == 0)
			raw.close(); peer.close(); try await listener.shutdown()
		} catch {
			for task in queued { task.cancel(); _ = try? await task.value }; for _ in 0..<4 { await workers.release() }; throw error
		}
		for _ in 0..<4 { await workers.release() }
		#expect(try await workers.run { 1 } == 1)
	}
}
