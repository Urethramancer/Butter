import Foundation
import Testing
import ButterTorrentMetadata
import ButterTorrentNetworking
@testable import ButterTorrentEngine

final class EngineClock: TransportClock, @unchecked Sendable {
	private let lock = NSLock()
	private var time: TimeInterval = 100
	private var pending: [UUID: (TimeInterval, CheckedContinuation<Void, Error>)] = [:]
	let sleeps = AsyncStream<TimeInterval>.makeStream(bufferingPolicy: .bufferingNewest(256))
	func now() -> TimeInterval { lock.withLock { time } }
	func sleep(for seconds: TimeInterval) async throws {
		let id = UUID()
		try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
				lock.withLock {
					if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
					else { pending[id] = (time + seconds, continuation); sleeps.continuation.yield(seconds) }
				}
			}
		} onCancel: { self.lock.withLock { self.pending.removeValue(forKey: id)?.1 }?.resume(throwing: CancellationError()) }
	}
	func advance(_ seconds: TimeInterval) {
		let continuations = lock.withLock {
			time += seconds
			let ready = pending.filter { $0.value.0 <= time }
			for id in ready.keys { pending[id] = nil }; return ready.values.map(\.1)
		}
		for continuation in continuations { continuation.resume() }
	}
	func nextSleep() async throws -> TimeInterval {
		try await withThrowingTaskGroup(of: TimeInterval.self) { group in
			group.addTask { for await seconds in self.sleeps.stream { return seconds }; throw PeerFailure.closed }
			group.addTask { try await Task.sleep(for: .seconds(3)); throw PeerFailure.invalid("clock test deadline") }
			defer { group.cancelAll() }; return try await group.next()!
		}
	}
}

@Suite struct TransferResourceTests {
	@Test func rateBucketHasBoundedBurstAndCancellableWaits() async throws {
		let clock = EngineClock(), limiter = TransferRateLimiter(rate: 100, clock: clock)
		let consuming = Task { try await limiter.consume(150) }
		#expect(try await clock.nextSleep() == 0.5)
		clock.advance(0.5); try await consuming.value
		let cancelled = Task { try await limiter.consume(100) }
		#expect(try await clock.nextSleep() == 1)
		cancelled.cancel(); await #expect(throws: CancellationError.self) { try await cancelled.value }
		await limiter.set(0); try await limiter.consume(1_000_000)
	}
	@Test func permitsCancelQueuedWorkAndCloseAllWaiters() async throws {
		let permits = TransferPermits(1); try await permits.acquire()
		let cancelled = Task { try await permits.acquire() }
		try await eventually { await permits.waitingCount == 1 }; cancelled.cancel()
		await #expect(throws: CancellationError.self) { try await cancelled.value }
		let closed = Task { try await permits.acquire() }
		try await eventually { await permits.waitingCount == 1 }; await permits.close()
		await #expect(throws: PeerFailure.self) { try await closed.value }
		await permits.release(); await #expect(throws: PeerFailure.self) { try await permits.acquire() }
	}
	@Test func uploadCacheRetainsOnlyHashCheckedImmutableBytesAndRejectsWrongStorage() async throws {
		try await transferFixture { fixture in
			_ = try await fixture.transfer("seed", seed: true)
			let storage = fixture.stores[0], cache = VerifiedPieceCache(storage: storage)
			async let first = cache.piece(0), second = cache.piece(0)
			let a = try await first, b = try await second
			#expect(a == b && a == fixture.bytes.prefix(32768))
			try Data([255]).write(to: fixture.root.appendingPathComponent("seed/bundle/a"))
			#expect(try await cache.piece(0) == a)
			await cache.close(); await #expect(throws: PeerFailure.self) { try await cache.piece(0) }
			var info = fixture.metadata.document.root["info"]!.dictionary!
			info[Data("name".utf8)] = .bytes(Data("different".utf8))
			let other = try TorrentMetadata(BencodeValue.dictionary([Data("info".utf8): .dictionary(info)]).encoded())
			await #expect(throws: PeerFailure.self) { try await TCPTransfer.open(metadata: other, storage: storage) }
		}
	}
	@Test func incompleteHandshakeExpiresAndPeerLimitRejectsAnotherConnection() async throws {
		try await transferFixture { fixture in
			let clock = EngineClock(); var config = TCPTransferConfiguration(); config.maximumPeers = 1
			let engine = try await fixture.transfer("download", configuration: config, clock: clock), listener = try await fixture.listen()
			let connect = Task { try await engine.connect(to: NetworkEndpoint("127.0.0.1", port: listener.port)) }
			let stream = try await listener.accept(timeout: 3); defer { stream.close() }; _ = try await connect.value
			try await stream.write(Data([19]))
			await #expect(throws: PeerFailure.self) { try await engine.connect(to: NetworkEndpoint("127.0.0.1", port: listener.port)) }
			clock.advance(11); await engine.tick()
			try await eventually { await engine.snapshot().peers.isEmpty }
		}
	}
}
