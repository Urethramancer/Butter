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
	@Test func cacheCapacityWaitsAreCancellableAndOwnerCloseDoesNotCancelAnotherLoad() async throws {
		try await transferFixture { fixture in
			_ = try await fixture.transfer("seed", seed: true)
			let gate = TransferPermits(1); try await gate.acquire()
			let pool = SharedPieceCache(limit: 40_000) { storage, index in
				try await gate.acquire()
				do { let bytes = try await storage.readVerifiedPiece(index); await gate.release(); return bytes }
				catch { await gate.release(); throw error }
			}
			let first = PieceCacheOwner(), second = PieceCacheOwner(), storage = fixture.stores[0]
			let reading = Task { try await pool.piece(0, storage: storage, owner: first) }
			try await eventually { await pool.usage.1 == 32768 }
			let cancelled = Task { try await pool.piece(1, storage: storage, owner: second) }
			try await eventually { await pool.waitingCount == 1 }; cancelled.cancel()
			await #expect(throws: CancellationError.self) { try await cancelled.value }
			let closing = Task { try await pool.piece(1, storage: storage, owner: second) }
			try await eventually { await pool.waitingCount == 1 }; await pool.close(second)
			await #expect(throws: PeerFailure.self) { try await closing.value }
			await gate.release(); #expect(try await reading.value == fixture.bytes.prefix(32768))
			await pool.close(first)
			let (cached, loading) = await pool.usage; #expect(cached == 0 && loading == 0)
		}
	}
	@Test func diskScopesShareAdmissionAndClosingOnePreservesOtherTransfers() async throws {
		let resources = try TransferResources(maximumDiskOperations: 1)
		let first = TransferDiskScope(resources: resources), second = TransferDiskScope(resources: resources)
		try await first.acquire()
		let waiting = Task { try await second.acquire() }
		try await eventually { await resources.snapshot().waitingDiskOperations == 1 }
		#expect(await resources.snapshot().diskOperations == 1)
		waiting.cancel(); await #expect(throws: CancellationError.self) { try await waiting.value }
		await first.close(); await first.release()
		try await second.acquire(); await second.release()
		#expect(await resources.snapshot().diskOperations == 0)
		await #expect(throws: PeerFailure.self) { try await first.acquire() }
		await second.close()
	}
	@Test func cacheEvictsAcrossOwnersAndOwnerCloseReleasesOnlyItsBytes() async throws {
		try await transferFixture { fixture in
			_ = try await fixture.transfer("seed", seed: true)
			let pool = SharedPieceCache(limit: 40_000), first = PieceCacheOwner(), second = PieceCacheOwner()
			let storage = fixture.stores[0]
			#expect(try await pool.piece(0, storage: storage, owner: first) == fixture.bytes.prefix(32768))
			#expect(try await pool.piece(1, storage: storage, owner: second) == fixture.bytes.subdata(in: 32768..<65536))
			let (cached, loading) = await pool.usage; #expect(cached == 32768 && loading == 0)
			await pool.close(first)
			let (surviving, _) = await pool.usage; #expect(surviving == 32768)
			await #expect(throws: PeerFailure.self) { try await pool.piece(0, storage: storage, owner: first) }
			await pool.close(second)
			let (empty, pending) = await pool.usage; #expect(empty == 0 && pending == 0)
		}
	}
	@Test(arguments: [false, true]) func cancellingPayloadAlreadyWaitingForRateLimitUnblocksControlReplies(_ encrypted: Bool) async throws {
		try await transferFixture { fixture in
			let clock = EngineClock(); var config = plainTransferConfiguration(); config.uploadLimit = 1024
			if encrypted { config.encryption = .init(incoming: .required, outgoing: .required, levels: .rc4) }
			let seed = try await fixture.transfer("seed", seed: true, configuration: config, clock: clock)
			_ = try await clock.nextSleep() // Drain the ticker's initial wait before observing the writer.
			let ticker = await seed.ticker; ticker?.cancel(); await ticker?.value
			var flags = Data(repeating: 0, count: 8); flags[7] = 4
			let peer = try await fixture.scripted(seed, reserved: flags, encryption: encrypted ? config.encryption : nil)
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
			let clock = EngineClock(); var config = plainTransferConfiguration(); config.maximumPeers = 1
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
