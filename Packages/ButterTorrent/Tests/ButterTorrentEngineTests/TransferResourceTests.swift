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
	@Test func cancellingPayloadAlreadyWaitingForRateLimitUnblocksControlReplies() async throws {
		try await transferFixture { fixture in
			let clock = EngineClock(); var config = TCPTransferConfiguration(); config.uploadLimit = 1024
			let seed = try await fixture.transfer("seed", seed: true, configuration: config, clock: clock)
			_ = try await clock.nextSleep() // Drain the ticker's initial wait before observing the writer.
			let ticker = await seed.ticker; ticker?.cancel(); await ticker?.value
			var flags = Data(repeating: 0, count: 8); flags[7] = 4
			let peer = try await fixture.scripted(seed, reserved: flags)
			try await peer.send(.haveNone); try await peer.send(.interested)
			let block = PeerBlock(piece: 0, offset: 0, length: 16384)
			try await peer.send(.request(block))
			// Socket operations also install deadlines on this clock; only the writer uses a one-second wait.
			var wait: TimeInterval = 0
			repeat { wait = try await clock.nextSleep() } while wait != 1
			try await peer.send(.cancel(block))
			try await eventually { await seed.pendingUploadsForTesting() == 0 }
			clock.advance(1)
			var rejects = 0
			while rejects == 0 {
				let message = try await peer.next()
				if case .reject(let rejected) = message { #expect(rejected == block); rejects += 1 }
				if case .piece = message { Issue.record("Cancelled rate-limited payload reached the wire") }
			}
			try await peer.send(.request(PeerBlock(piece: 0, offset: 0, length: 1)))
			while true {
				let message = try await peer.next()
				if case .reject = message { rejects += 1 }
				if case .piece(_, _, let bytes) = message { #expect(bytes == fixture.bytes.prefix(1)); break }
			}
			#expect(rejects == 1)
		}
	}
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

extension TCPTransfer {
	func pendingUploadsForTesting() -> Int { peers.values.reduce(0) { $0 + $1.uploads.count } }
}
