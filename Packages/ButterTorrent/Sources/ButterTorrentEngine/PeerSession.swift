import Foundation
import ButterTorrentNetworking

// One reader and one writer own the TCP stream; the controller owns protocol state.
final class PeerSession: @unchecked Sendable {
	struct Outbound: Sendable { let bytes: Data; let payload: Int; let token: UUID?; let block: PeerBlock? }
	let stream: any PeerByteStream
	private let transport: PeerStream?
	private let lock = NSLock()
	private let outgoing = AsyncStream<Outbound>.makeStream(bufferingPolicy: .bufferingOldest(128))
	private var queuedBytes = 0
	private var closed = false
	private var tokens: Set<UUID> = []
	init(stream: any PeerByteStream, transport: PeerStream? = nil) { self.stream = stream; self.transport = transport }
	func handshake(_ hello: PeerHandshake) throws { try enqueue(Outbound(bytes: hello.encoded, payload: 0, token: nil, block: nil)) }
	func register(_ token: UUID) { _ = lock.withLock { tokens.insert(token) } }
	func send(_ message: PeerMessage, token: UUID? = nil, block: PeerBlock? = nil) throws {
		let payload: Int
		if case .piece(_, _, let bytes) = message { payload = bytes.count } else { payload = 0 }
		try enqueue(Outbound(bytes: message.encoded(), payload: payload, token: token, block: block))
	}
	private func enqueue(_ item: Outbound) throws {
		try lock.withLock {
			guard !closed else { throw PeerFailure.closed }
			guard queuedBytes + item.bytes.count <= 524_288 else { throw PeerFailure.limit("peer output bytes") }
			if let token = item.token, !tokens.contains(token) { throw PeerFailure.closed }
			if case .enqueued = outgoing.continuation.yield(item) {
				queuedBytes += item.bytes.count
			} else { throw PeerFailure.limit("peer output messages") }
		}
	}
	@discardableResult func cancel(_ token: UUID) -> Bool { lock.withLock { tokens.remove(token) != nil } }
	func close() { lock.withLock { closed = true; tokens.removeAll() }; outgoing.continuation.finish(); stream.close() }
	func run(id: UUID, hello: PeerHandshake, outgoing: Bool, engine: TCPTransfer, upload: TransferRateLimiter, idleTimeout: TimeInterval,
		hashes: [Data], encryption: PeerEncryptionConfiguration, clock: any TransportClock) async throws {
		defer { close() }
		let channel: PeerStream
		if let transport { channel = transport } else { channel = try await PeerStream.accept(stream, hashes: hashes, configuration: encryption, clock: clock) }
		await engine.negotiated(id, mode: channel.mode)
		if outgoing { try handshake(hello) }
		try await withThrowingTaskGroup(of: Void.self) { group in
			group.addTask {
				for await item in self.outgoing.stream {
					self.lock.withLock { self.queuedBytes -= item.bytes.count }
					try Task.checkCancellation()
					if let token = item.token, !self.lock.withLock({ self.tokens.contains(token) }) { continue }
					do { try await upload.consume(item.payload) { item.token.map { token in !self.lock.withLock({ self.tokens.contains(token) }) } ?? false } }
					catch is CancellationError {
						if !Task.isCancelled, let token = item.token, !self.lock.withLock({ self.tokens.contains(token) }) { continue }; throw CancellationError()
					}
					if let token = item.token, !self.lock.withLock({ self.tokens.remove(token) != nil }) { continue }
					try await channel.write(item.bytes)
					if let block = item.block, let token = item.token { await engine.uploaded(id, block: block, token: token, count: item.payload) }
				}
			}
			group.addTask {
				var decoder = PeerWireDecoder(), ready = false, frames = 0
				while true {
					let bytes = try await channel.read(timeout: ready ? idleTimeout : 10)
					if bytes.isEmpty {
						guard ready else { throw NetworkFailure.closed }
						try decoder.finish(); return
					}
					try decoder.feed(bytes)
					if !ready {
						guard let handshake = try decoder.handshake() else { continue }
						let features = try await engine.handshaken(id, handshake: handshake); decoder.negotiate(features); ready = true
					}
					var firstBlock: IncomingPieceBlock?, blocks: [IncomingPieceBlock] = [], blockBytes = 0
					func flushBlocks() async throws {
						guard let first = firstBlock else { return }
						let batch = blocks; blocks = []; firstBlock = nil; blockBytes = 0
						if batch.isEmpty { try await engine.received(id, message: .piece(first.piece, first.offset, first.bytes)) }
						else { try await engine.receivedBlocks(id, blocks: batch) }
					}
					do {
						while let message = try decoder.next() {
							try Task.checkCancellation()
							if case .piece(let piece, let offset, let bytes) = message {
								if bytes.count > 262144 - blockBytes || blocks.count == 16 { try await flushBlocks() }
								let block = IncomingPieceBlock(piece: piece, offset: offset, bytes: bytes)
								if let first = firstBlock {
									if blocks.isEmpty { blocks = [first, block] } else { blocks.append(block) }
								} else { firstBlock = block }
								blockBytes += bytes.count
							} else { try await flushBlocks(); try await engine.received(id, message: message) }
							frames += 1
							if frames % 128 == 0 { try await flushBlocks(); await Task.yield() }
						}
					} catch { let failure = error; try await flushBlocks(); throw failure }
					// Flush all available frames before the next network wait, including a short batch.
					try await flushBlocks()
				}
			}
			do { _ = try await group.next(); group.cancelAll(); close(); try await group.waitForAll() }
			catch { group.cancelAll(); close(); throw error }
		}
	}
}
