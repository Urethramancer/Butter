import Foundation
import Testing
@testable import ButterTorrentNetworking

private final class ArithmeticGate: @unchecked Sendable {
	private let lock = NSLock()
	private var started = 0
	private let semaphore = DispatchSemaphore(value: 0)
	var count: Int { lock.withLock { started } }
	func hold() -> Int { lock.withLock { started += 1 }; semaphore.wait(); return 1 }
	func release() { for _ in 0..<4 { semaphore.signal() } }
}

@Suite struct MSEWorkerTests {
	@Test func workerAndQueueBoundsCancellationAndQueuedDeadline() async throws {
		let workers = MSEWorkers(), gate = ArithmeticGate()
		let holders = (0..<4).map { _ in Task { try await workers.run { gate.hold() } } }
		var queued: [Task<Int, Error>] = []
		do {
			try await deadline { while gate.count < 4 { try await Task.sleep(for: .milliseconds(1)) } }
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
			gate.release(); for task in holders { task.cancel(); _ = try? await task.value }; for task in queued { task.cancel(); _ = try? await task.value }; throw error
		}
		gate.release(); for task in holders { #expect(try await task.value == 1) }
	}
}
