import Foundation
import Testing
import ButterTorrentNetworking
@testable import ButterTorrentStorage
@testable import ButterTorrentEngine

private final class BatchVerificationGate: @unchecked Sendable {
	private let lock = NSLock()
	private var armed = false
	let entered = AsyncStream<Void>.makeStream()
	let release = DispatchSemaphore(value: 0)
	func arm() { lock.withLock { armed = true } }
	func observe(_ event: StorageEvent) {
		guard event == .progressCheckpointDurable,
			lock.withLock({ if !armed { return false }; armed = false; return true }) else { return }
		entered.continuation.yield(())
		if release.wait(timeout: .now() + 6) != .success { Issue.record("Verification checkpoint gate expired") }
	}
}

private extension TCPTransfer {
	func verifyingPiecesForTesting() -> Set<Int> { Set(picker.active.filter { $0.value.verifying }.map(\.key)) }
}

// Collect a known fixture burst to deterministically exercise a multi-feed read.
private final class CoalescingPeerStream: PeerByteStream, @unchecked Sendable {
	let raw: TCPStream
	private let lock = NSLock()
	private var target: Int?
	private var largest = 0, reads = 0
	private var closed = false
	init(_ raw: TCPStream) { self.raw = raw }
	var remoteEndpoint: NetworkEndpoint? { raw.remoteEndpoint }
	var kind: PeerTransportKind { .tcp }
	var largestRead: Int { lock.withLock { largest } }
	var isClosed: Bool { lock.withLock { closed } }
	var activeReads: Int { lock.withLock { reads } }
	func coalesce(_ count: Int) { lock.withLock { target = count } }
	func read(maximumBytes: Int, timeout: TimeInterval) async throws -> Data {
		lock.withLock { reads += 1 }; defer { lock.withLock { reads -= 1 } }
		var bytes = try await raw.read(maximumBytes: maximumBytes, timeout: timeout)
		let goal = lock.withLock { let count = min(target ?? bytes.count, maximumBytes); target = nil; return count }
		while bytes.count < goal {
			let next = try await raw.read(maximumBytes: goal - bytes.count, timeout: timeout)
			if next.isEmpty { break }; bytes.append(next)
		}
		lock.withLock { largest = max(largest, bytes.count) }; return bytes
	}
	func write(_ bytes: Data, timeout: TimeInterval) async throws { try await raw.write(bytes, timeout: timeout) }
	func close() { lock.withLock { closed = true }; raw.close() }
}

@Suite struct TransferWriteBatchTests {
	@Test(arguments: [false, true]) func requestsOverlapAdmittedWritesWithinTheExistingWindow(_ batched: Bool) async throws {
		try await transferFixture { fixture in
			let resources = try TransferResources(maximumDiskOperations: 1), clock = EngineClock()
			var config = plainTransferConfiguration(); config.pipeline = batched ? 2 : 1
			let down = try await fixture.transfer("download", configuration: config, clock: clock, resources: resources)
			let peer = try await fixture.scripted(down)
			try await peer.seed(pieceCount: 3)
			let requests = try await peer.requests(config.pipeline), id = await down.snapshot().peers[0].id
			let blocks = requests.map { IncomingPieceBlock(piece: $0.piece, offset: $0.offset, bytes: fixture.bytes.subdata(in: $0.offset..<($0.offset + $0.length))) }
			let worker = await fixture.stores[0].worker, entered = AsyncStream<Void>.makeStream(), release = DispatchSemaphore(value: 0)
			let blocker = Task { try await worker.run { _ in entered.continuation.yield(()); _ = release.wait(timeout: .now() + 6) } }
			defer { release.signal(); peer.stream.close() }
			try await engineDeadline { for await _ in entered.stream { return }; throw PeerFailure.closed }
			let writing = Task {
				if batched { try await down.receivedBlocks(id, blocks: blocks) }
				else { try await down.received(id, message: .piece(blocks[0].piece, blocks[0].offset, blocks[0].bytes)) }
			}
			do {
				let next = try await peer.requests(config.pipeline)
				#expect(Set(next).isDisjoint(with: requests))
				let status = await down.snapshot()
				#expect(status.writingBlocks == config.pipeline && status.verifiedPieces.isEmpty)
				#expect(status.peers.first?.pendingRequests == config.pipeline)
				#expect(await resources.snapshot().diskOperations == 1)
				release.signal(); try await blocker.value; try await writing.value
				#expect(await down.snapshot().writingBlocks == 0)
			} catch { writing.cancel(); release.signal(); _ = try? await blocker.value; _ = try? await writing.value; throw error }
		}
	}
	@Test(arguments: [false, true]) func requestsOverlapVerificationWithinTheExistingWindow(_ batched: Bool) async throws {
		try await transferFixture { fixture in
			let gate = BatchVerificationGate(), resources = try TransferResources(maximumDiskOperations: 1), clock = EngineClock()
			var config = plainTransferConfiguration(); config.pipeline = batched ? 2 : 1
			let down = try await fixture.transfer("download", configuration: config, clock: clock, resources: resources, event: { gate.observe($0) })
			let peer = try await fixture.scripted(down)
			defer { gate.release.signal(); peer.stream.close() }
			try await peer.seed(pieceCount: 3)
			var requests = try await peer.requests(config.pipeline)
			let id = await down.snapshot().peers[0].id
			if !batched {
				let block = requests[0]
				try await down.received(id, message: .piece(block.piece, block.offset, fixture.bytes.subdata(in: block.offset..<(block.offset + block.length))))
				requests = try await peer.requests(1)
			}
			let blocks = requests.map { IncomingPieceBlock(piece: $0.piece, offset: $0.offset, bytes: fixture.bytes.subdata(in: $0.offset..<($0.offset + $0.length))) }
			gate.arm()
			let writing = Task {
				if batched { try await down.receivedBlocks(id, blocks: blocks) }
				else { try await down.received(id, message: .piece(blocks[0].piece, blocks[0].offset, blocks[0].bytes)) }
			}
			do {
				try await engineDeadline { for await _ in gate.entered.stream { return }; throw PeerFailure.closed }
				let next = try await peer.requests(config.pipeline)
				#expect(next.allSatisfy { $0.piece == 1 })
				// A fused job has not yet returned its write result to the picker.
				// The checkpoint gate proves verification is running; publication waits.
				#expect(await down.snapshot().verifiedPieces.isEmpty)
				#expect(await resources.snapshot().diskOperations == 1)
				gate.release.signal(); try await writing.value
				let status = await down.snapshot()
				#expect(status.verifiedPieces == [0] && status.peers.first?.pendingRequests == config.pipeline)
			} catch { writing.cancel(); gate.release.signal(); _ = try? await writing.value; throw error }
		}
	}
	@Test(arguments: [false, true], [false, true]) func availableRequestBurstProcessesCancelBeforeBlockedPayloads(_ encrypted: Bool, _ limited: Bool) async throws {
		try await transferFixture { fixture in
			let resources = try TransferResources(maximumDiskOperations: 1)
			var config = plainTransferConfiguration(); config.downloadLimit = limited ? 1048576 : 0
			if encrypted { config.encryption = .init(incoming: .required, outgoing: .required, levels: .rc4) }
			let seed = try await fixture.transfer("seed", seed: true, configuration: config, resources: resources), listener = try await fixture.listen()
			let blocker = TransferDiskScope(resources: resources); try await blocker.acquire()
			let endpoint = try NetworkEndpoint("127.0.0.1", port: listener.port), hash = fixture.metadata.hashes.v1!, encryption = config.encryption
			let connecting = Task { try await PeerStream.connect(to: endpoint, hash: hash, configuration: encryption) }
			var held = true
			do {
				let stream = CoalescingPeerStream(try await listener.accept(timeout: 3)); _ = try await seed.attach(stream)
				let channel = try await connecting.value; defer { channel.close() }
				let peer = WirePeer(channel: channel); var reserved = Data(repeating: 0, count: 8); reserved[7] = 4
				try await peer.hello(hash: hash, identity: 42, reserved: reserved)
				try await peer.send(.haveNone); try await peer.send(.interested); try await peer.send(.unchoke)
				while try await peer.next() != .unchoke {}
				try await eventually { await seed.snapshot().peers.first?.remoteChoking == false }
				let requests = (0..<TCPTransferConfiguration.advertisedUploadRequestLimit).map { PeerBlock(piece: $0 % 2, offset: $0 / 2, length: 16384) }
				let cancelled = requests[requests.count / 2]
				var frames = Data()
				for block in requests { frames.append(try PeerMessage.request(block).encoded()) }
				frames.append(try PeerMessage.cancel(cancelled).encoded()); frames.append(try PeerMessage.choke.encoded())
				stream.coalesce(frames.count); try await channel.write(frames)
				var rejected = false
				while !rejected {
					let message = try await peer.next()
					if case .reject(let block) = message { #expect(block == cancelled); rejected = true }
					if case .piece = message { Issue.record("Blocked payload preceded the cancellation reply") }
				}
				try await eventually { await seed.snapshot().peers.first?.remoteChoking == true }
				await blocker.release(); held = false
				var remaining = Set(requests); remaining.remove(cancelled)
				while !remaining.isEmpty {
					if case .piece(let piece, let offset, let bytes) = try await peer.next() {
						let block = PeerBlock(piece: piece, offset: offset, length: bytes.count)
						try #require(remaining.remove(block) != nil, "Unexpected, duplicate or cancelled payload")
						let start = piece * 32768 + offset
						#expect(bytes == fixture.bytes.subdata(in: start..<(start + bytes.count)))
					}
				}
				try await eventually { await seed.uploaded == Int64((requests.count - 1) * 16384) }
				#expect(await seed.lastPeerError == nil)
			} catch {
				if held { await blocker.release() }; connecting.cancel()
				if let channel = try? await connecting.value { channel.close() }; throw error
			}
		}
	}
	@Test func cancellationDuringVerificationReleasesEveryRemainingReadyPiece() async throws {
		try await transferFixture { fixture in
			let gate = BatchVerificationGate(), resources = try TransferResources(maximumDiskOperations: 1)
			let down = try await fixture.transfer("download", resources: resources, event: { gate.observe($0) }), peer = try await fixture.scripted(down)
			defer { gate.release.signal(); peer.stream.close() }
			try await peer.seed(pieceCount: 3); let requests = try await peer.requests(6)
			let blocks = requests.map { block in
				let start = block.piece * 32768 + block.offset
				return IncomingPieceBlock(piece: block.piece, offset: block.offset, bytes: fixture.bytes.subdata(in: start..<(start + block.length)))
			}
			let id = await down.snapshot().peers[0].id
			gate.arm(); let writing = Task { try await down.receivedBlocks(id, blocks: blocks) }
			try await engineDeadline { for await _ in gate.entered.stream { return }; throw PeerFailure.closed }
			writing.cancel(); gate.release.signal()
			await #expect(throws: CancellationError.self) { try await writing.value }
			let pending = await down.verifyingPiecesForTesting()
			try #require(pending.isEmpty, "Cancelled verification must release the rest of the ready batch")
			#expect(await down.snapshot().writingBlocks == 0)
			let disk = await resources.snapshot()
			#expect(disk.diskOperations == 0 && disk.waitingDiskOperations == 0)
			peer.stream.close()
			let seed = try await fixture.transfer("seed", seed: true); try await fixture.join(down, seed)
			try await engineDeadline { try await down.waitUntilComplete() }
			let status = await down.snapshot()
			#expect(status.verifiedPieces == [0, 1, 2] && status.corruptBytes == 0)
			#expect(status.downloaded - status.redundantBytes == Int64(fixture.bytes.count))
		}
	}
	@Test(arguments: [false, true], [(0, 262144), (1_048_576, 65536), (2_000_000, 6 * 16397)])
	func availableReadSpansDecoderFeedsAndFlushesBeforeControl(_ encrypted: Bool, _ cap: (rate: Int, maximum: Int)) async throws {
		for (large, singleFile) in [(false, false), (true, false), (true, true)] {
			let pieceLength = large ? 524288 : 32768, pieceCount = large ? 1 : 3
			let fixture = try large ? TransferFixture(lengths: singleFile ? [524288] : [524288, 0, 0, 0], pieceLength: pieceLength) : TransferFixture()
			try await transferFixture(fixture) { fixture in
				var config = plainTransferConfiguration(); config.downloadLimit = cap.rate
				if encrypted { config.encryption = .init(incoming: .required, outgoing: .required, levels: .rc4) }
				let down = try await fixture.transfer("download", configuration: config), listener = try await fixture.listen()
				let endpoint = try NetworkEndpoint("127.0.0.1", port: listener.port), hash = fixture.metadata.hashes.v1!, encryption = config.encryption
				let connecting = Task { try await PeerStream.connect(to: endpoint, hash: hash, configuration: encryption) }
				do {
					let stream = CoalescingPeerStream(try await listener.accept(timeout: 3))
					_ = try await down.attach(stream)
					let channel = try await connecting.value; defer { channel.close() }
					let peer = WirePeer(channel: channel)
					try await peer.hello(hash: hash, identity: 42); try await peer.seed(pieceCount: pieceCount)
					let requests = try await peer.requests(large ? 32 : 6)
					var frames = Data()
					for block in requests {
						let start = block.piece * pieceLength + block.offset
						frames.append(try PeerMessage.piece(block.piece, block.offset, fixture.bytes.subdata(in: start..<(start + block.length))).encoded())
					}
					frames.append(try PeerMessage.choke.encoded()); stream.coalesce(frames.count)
					try await channel.write(frames)
					try await eventually {
						let status = await down.snapshot()
						return status.verifiedPieces == Set(0..<pieceCount) && status.peers.first?.remoteChoking == true && status.peers.first?.pendingRequests == 0
					}
					#expect(stream.largestRead == min(frames.count, cap.maximum))
					#expect(await down.snapshot().downloaded == Int64(fixture.bytes.count))
				} catch { connecting.cancel(); if let channel = try? await connecting.value { channel.close() }; throw error }
			}
		}
	}
	@Test(arguments: [false, true]) func fairnessYieldPreservesPayloadBeforeControl(_ encrypted: Bool) async throws {
		try await transferFixture { fixture in
			var config = plainTransferConfiguration()
			if encrypted { config.encryption = .init(incoming: .required, outgoing: .required, levels: .rc4) }
			let resources = try TransferResources(maximumDiskOperations: 1)
			let down = try await fixture.transfer("download", configuration: config, resources: resources), listener = try await fixture.listen()
			let endpoint = try NetworkEndpoint("127.0.0.1", port: listener.port), hash = fixture.metadata.hashes.v1!, encryption = config.encryption
			let connecting = Task { try await PeerStream.connect(to: endpoint, hash: hash, configuration: encryption) }
			let release = DispatchSemaphore(value: 0)
			defer { release.signal() }
			do {
				let stream = CoalescingPeerStream(try await listener.accept(timeout: 3)); _ = try await down.attach(stream)
				let channel = try await connecting.value; defer { channel.close() }
				let peer = WirePeer(channel: channel)
				try await peer.hello(hash: hash, identity: 42); try await peer.seed(pieceCount: 3)
				let requests = try await peer.requests(6)
				// Bitfield and unchoke count as two frames. Cross frame 128 after
				// three payloads, leaving three more available across decoder feeds.
				var frames = Data(repeating: 0, count: 123 * 4)
				for block in requests {
					let start = block.piece * 32768 + block.offset
					frames.append(try PeerMessage.piece(block.piece, block.offset, fixture.bytes.subdata(in: start..<(start + block.length))).encoded())
				}
				frames.append(try PeerMessage.choke.encoded()); stream.coalesce(frames.count)
				let worker = await fixture.stores[0].worker, entered = AsyncStream<Void>.makeStream()
				let blocker = Task { try await worker.run { _ in entered.continuation.yield(()); _ = release.wait(timeout: .now() + 6) } }
				do {
					try await engineDeadline { for await _ in entered.stream { return }; throw PeerFailure.closed }
					try await channel.write(frames)
					try await eventually { await down.snapshot().writingBlocks > 0 }
					let blocked = await down.snapshot()
					#expect(blocked.peers.first?.remoteChoking == false)
					#expect(stream.largestRead == frames.count)
					release.signal(); try await blocker.value
					try await eventually {
						let status = await down.snapshot()
						return status.verifiedPieces == [0, 1, 2] && status.writingBlocks == 0 && status.peers.first?.remoteChoking == true
					}
					#expect(await down.snapshot().downloaded == Int64(fixture.bytes.count))
					try await down.shutdown()
					#expect(stream.activeReads == 0)
					let usage = await resources.snapshot()
					#expect(usage.diskOperations == 0 && usage.waitingDiskOperations == 0)
				} catch { release.signal(); _ = try? await blocker.value; throw error }
			} catch { connecting.cancel(); if let channel = try? await connecting.value { channel.close() }; throw error }
		}
	}
	@Test(arguments: [false, true], [false, true]) func shutdownDrainsQueuedPayloadWhileStorageIsBlocked(_ encrypted: Bool, _ changeRate: Bool) async throws {
		try await transferFixture { fixture in
			var config = plainTransferConfiguration()
			if encrypted { config.encryption = .init(incoming: .required, outgoing: .required, levels: .rc4) }
			let resources = try TransferResources(maximumDiskOperations: 1)
			let down = try await fixture.transfer("download", configuration: config, resources: resources), listener = try await fixture.listen()
			let endpoint = try NetworkEndpoint("127.0.0.1", port: listener.port), hash = fixture.metadata.hashes.v1!, encryption = config.encryption
			let connecting = Task { try await PeerStream.connect(to: endpoint, hash: hash, configuration: encryption) }
			let release = DispatchSemaphore(value: 0)
			defer { release.signal() }
			do {
				let stream = CoalescingPeerStream(try await listener.accept(timeout: 3)); _ = try await down.attach(stream)
				let channel = try await connecting.value; defer { channel.close() }
				let peer = WirePeer(channel: channel)
				try await peer.hello(hash: hash, identity: 42); try await peer.seed(pieceCount: 3)
				let requests = try await peer.requests(6)
				func frame(_ block: PeerBlock) throws -> Data {
					let start = block.piece * 32768 + block.offset
					return try PeerMessage.piece(block.piece, block.offset, fixture.bytes.subdata(in: start..<(start + block.length))).encoded()
				}
				// Finish one payload cycle before holding the next storage operation.
				try await channel.write(frame(requests[0]))
				try await eventually { let status = await down.snapshot(); return status.downloaded == 16384 && status.writingBlocks == 0 }
				let worker = await fixture.stores[0].worker, entered = AsyncStream<Void>.makeStream()
				let blocker = Task { try await worker.run { _ in entered.continuation.yield(()); _ = release.wait(timeout: .now() + 6) } }
				do {
					try await engineDeadline { for await _ in entered.stream { return }; throw PeerFailure.closed }
					try await channel.write(frame(requests[1]))
					try await eventually { await down.snapshot().writingBlocks == 1 }
					if changeRate { try await down.setLimits(download: 1048576, upload: 0) }
					for block in requests.dropFirst(2) {
						let bytes = try frame(block)
						try await channel.write(bytes)
					}
					let stopping = Task { try await down.shutdown() }
					try await eventually { stream.isClosed }
					release.signal(); try await blocker.value
					try await engineDeadline { try await stopping.value }
					#expect(stream.activeReads == 0)
					let usage = await resources.snapshot()
					#expect(usage.diskOperations == 0 && usage.waitingDiskOperations == 0)
					#expect(await down.snapshot().peers.isEmpty)
				} catch { release.signal(); _ = try? await blocker.value; throw error }
			} catch { connecting.cancel(); if let channel = try? await connecting.value { channel.close() }; throw error }
		}
	}
	@Test func flushesAvailablePiecesBeforeProcessingAChoke() async throws {
		try await transferFixture { fixture in
			let down = try await fixture.transfer("download"), peer = try await fixture.scripted(down)
			try await peer.seed(pieceCount: 3); let requests = try await peer.requests(6)
			var frames = Data()
			for block in requests where block.piece == 0 {
				frames.append(try PeerMessage.piece(block.piece, block.offset, fixture.bytes.subdata(in: block.offset..<(block.offset + block.length))).encoded())
			}
			frames.append(try PeerMessage.choke.encoded()); try await peer.stream.write(frames)
			try await eventually {
				let status = await down.snapshot()
				return status.verifiedPieces == [0] && status.peers.first?.remoteChoking == true && status.peers.first?.pendingRequests == 0
			}
			#expect(await down.snapshot().downloaded == 32768)
			peer.stream.close()
		}
	}
	@Test(arguments: [0, 125]) func shortAvailableBatchDoesNotWaitForAnotherFrame(_ keepAlives: Int) async throws {
		try await transferFixture { fixture in
			let down = try await fixture.transfer("download"), peer = try await fixture.scripted(down)
			try await peer.seed(pieceCount: 3); let block = try await peer.requests(6)[0]
			#expect(block.piece == 0 && block.offset == 0)
			// With bitfield and unchoke, this places the only payload at frame 128.
			if keepAlives > 0 { try await peer.stream.write(Data(repeating: 0, count: keepAlives * 4)) }
			try await peer.reply(block, bytes: fixture.bytes)
			let file = fixture.root.appendingPathComponent("download/bundle/a"), expected = Data(fixture.bytes.prefix(10003))
			try await eventually {
				let status = await down.snapshot()
				return status.writingBlocks == 0 && (try? Data(contentsOf: file)) == expected
			}
			#expect(await down.snapshot().downloaded == 16384)
			peer.stream.close()
		}
	}
	@Test func cancellationAbortsEveryQueuedBlockAndAccountsForLostPayloadOnce() async throws {
		try await transferFixture { fixture in
			let down = try await fixture.transfer("download"), peer = try await fixture.scripted(down)
			try await peer.seed(pieceCount: 3)
			let requests = try await peer.requests(6).filter { $0.piece == 0 }
			let blocks = requests.map { IncomingPieceBlock(piece: $0.piece, offset: $0.offset, bytes: fixture.bytes.subdata(in: $0.offset..<($0.offset + $0.length))) }
			let id = await down.snapshot().peers[0].id
			let worker = await fixture.stores[0].worker, entered = AsyncStream<Void>.makeStream(), release = DispatchSemaphore(value: 0)
			let blocker = Task { try await worker.run { _ in entered.continuation.yield(()); _ = release.wait(timeout: .now() + 6) } }
			defer { release.signal(); peer.stream.close() }
			try await engineDeadline { for await _ in entered.stream { return }; throw PeerFailure.closed }
			let writing = Task { try await down.receivedBlocks(id, blocks: blocks) }
			try await eventually { await down.snapshot().writingBlocks == 2 }
			writing.cancel(); release.signal(); try await blocker.value
			await #expect(throws: CancellationError.self) { try await writing.value }
			#expect(await down.snapshot().writingBlocks == 0)
			#expect(await down.snapshot().redundantBytes == 32768)
			let seed = try await fixture.transfer("seed", seed: true); try await fixture.join(down, seed)
			try await engineDeadline { try await down.waitUntilComplete() }
			let status = await down.snapshot()
			#expect(status.downloaded == Int64(fixture.bytes.count) + 32768 && status.redundantBytes == 32768 && status.corruptBytes == 0)
		}
	}
	@Test func verifiesStoredBytesAndRejectsACorruptCompletedPiece() async throws {
		try await transferFixture { fixture in
			let down = try await fixture.transfer("download"), peer = try await fixture.scripted(down)
			try await peer.seed(pieceCount: 3)
			let requests = try await peer.requests(6).filter { $0.piece == 0 }, id = await down.snapshot().peers[0].id
			let blocks = requests.map { block in
				var bytes = fixture.bytes.subdata(in: block.offset..<(block.offset + block.length))
				if block.offset == 0 { bytes[0] ^= 255 }
				return IncomingPieceBlock(piece: block.piece, offset: block.offset, bytes: bytes)
			}
			try await down.receivedBlocks(id, blocks: blocks)
			let status = await down.snapshot()
			#expect(status.verifiedPieces.isEmpty && status.corruptPieces == 1 && status.corruptBytes == 32768 && status.storageError == nil)
			peer.stream.close()
		}
	}
}
