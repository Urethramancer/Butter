import Foundation
import ButterTorrentNetworking

// One reader and one writer own the TCP stream; the controller owns protocol state.
final class PeerSession: @unchecked Sendable {
	struct Outbound: Sendable { let bytes: Data; let payload: Int; let token: UUID?; let block: PeerBlock? }
	let stream: any PeerByteStream
	private let transport: PeerStream?
	private let lock = NSLock()
	private let outputReady = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
	private var outgoing: [Outbound] = []
	private var queuedBytes = 0
	private var queuedMessages = 0
	private var reservedBytes = 0
	private var reservations: [UUID: Int] = [:]
	private var closed = false
	private var tokens: Set<UUID> = []
	init(stream: any PeerByteStream, transport: PeerStream? = nil) { self.stream = stream; self.transport = transport }
	func handshake(_ hello: PeerHandshake) throws { try enqueue(Outbound(bytes: hello.encoded, payload: 0, token: nil, block: nil)) }
	func register(_ token: UUID, bytes: Int) -> Bool {
		lock.withLock {
			guard !closed, bytes > 0, bytes <= 524_288 - queuedBytes - reservedBytes,
				queuedMessages + reservations.count < 128, !tokens.contains(token) else { return false }
			tokens.insert(token); reservations[token] = bytes; reservedBytes += bytes; return true
		}
	}
	func send(_ message: PeerMessage, token: UUID? = nil, block: PeerBlock? = nil) throws {
		let payload: Int
		if case .piece(_, _, let bytes) = message { payload = bytes.count } else { payload = 0 }
		try enqueue(Outbound(bytes: message.encoded(), payload: payload, token: token, block: block))
	}
	private func enqueue(_ item: Outbound) throws {
		try lock.withLock {
			guard !closed else { throw PeerFailure.closed }
			let credit: Int
			if let token = item.token {
				guard tokens.contains(token), let reserved = reservations[token] else { throw PeerFailure.closed }
				guard reserved == item.bytes.count else { throw PeerFailure.invalid("upload output reservation") }; credit = reserved
			} else { credit = 0 }
			guard queuedBytes + reservedBytes - credit + item.bytes.count <= 524_288 else { throw PeerFailure.limit("peer output bytes") }
			guard queuedMessages + reservations.count - (item.token == nil ? 0 : 1) < 128 else { throw PeerFailure.limit("peer output messages") }
			if let token = item.token { reservations[token] = nil; reservedBytes -= credit }
			outgoing.append(item); queuedBytes += item.bytes.count; queuedMessages += 1
			outputReady.continuation.yield(())
		}
	}
	@discardableResult func cancel(_ token: UUID) -> Bool {
		lock.withLock {
			if let bytes = reservations.removeValue(forKey: token) { reservedBytes -= bytes }
			return tokens.remove(token) != nil
		}
	}
	func close() {
		lock.withLock { closed = true; tokens.removeAll(); reservations.removeAll(); reservedBytes = 0; outgoing.removeAll(); queuedBytes = 0; queuedMessages = 0 }
		outputReady.continuation.finish(); stream.close()
	}
	func takeOutgoing(maximumCount: Int, maximumBytes: Int) -> [Outbound] {
		lock.withLock {
			var count = 0, bytes = 0
			for item in outgoing.prefix(maximumCount) {
				guard item.bytes.count <= maximumBytes - bytes else { break }
				count += 1; bytes += item.bytes.count
			}
			let result = Array(outgoing.prefix(count)); outgoing.removeFirst(count)
			queuedBytes -= bytes; queuedMessages -= count; return result
		}
	}
	func claimOutgoing(_ items: [Outbound]) -> [Outbound] {
		lock.withLock {
			guard !closed else { return [] }
			return items.filter { item in item.token.map { tokens.remove($0) != nil } ?? true }
		}
	}
	private func writeOutput(_ channel: PeerStream, id: UUID, engine: TCPTransfer, upload: TransferRateLimiter) async throws {
		for await _ in self.outputReady.stream {
			while true {
				try Task.checkCancellation()
				let unrestricted = await upload.consumeUnrestrictedBatch()
				// µTP retains each write against a shared transport budget; keep its frame-sized admission.
				let items = self.takeOutgoing(maximumCount: unrestricted && stream.kind == .tcp ? 16 : 1, maximumBytes: 262144)
				if items.isEmpty { break }
				if !unrestricted, let item = items.first {
					if let token = item.token, !self.lock.withLock({ self.tokens.contains(token) }) { continue }
					do { try await upload.consume(item.payload) { item.token.map { token in !self.lock.withLock({ self.tokens.contains(token) }) } ?? false } }
					catch is CancellationError {
						if !Task.isCancelled, let token = item.token, !self.lock.withLock({ self.tokens.contains(token) }) { continue }; throw CancellationError()
					}
				}
				try Task.checkCancellation()
				let ready = self.claimOutgoing(items)
				if ready.isEmpty { continue }
				let bytes: Data
				if ready.count == 1 { bytes = ready[0].bytes }
				else { var joined = Data(capacity: ready.reduce(0) { $0 + $1.bytes.count }); for item in ready { joined.append(item.bytes) }; bytes = joined }
				// Drain only work already available; never wait to fill a network batch.
				try await channel.write(bytes)
				if ready.contains(where: { $0.token != nil }) { await engine.uploadedBatch(id, items: ready) }
			}
		}
	}
	private func readInput(_ channel: PeerStream, id: UUID, engine: TCPTransfer, download: TransferRateLimiter, idleTimeout: TimeInterval) async throws {
		var decoder = PeerWireDecoder(), ready = false, frames = 0
		while true {
			var maximum = 65536
			if stream.kind == .tcp, await download.consumeUnrestrictedBatch() { maximum = 262144 }
			let bytes = try await channel.read(maximumBytes: maximum, timeout: ready ? idleTimeout : 10)
			if bytes.isEmpty {
				guard ready else { throw NetworkFailure.closed }
				try decoder.finish(); return
			}
			var firstBlock: IncomingPieceBlock?, blocks: [IncomingPieceBlock] = [], blockBytes = 0
			func flushBlocks() async throws {
				guard let first = firstBlock else { return }
				let batch = blocks; blocks = []; firstBlock = nil; blockBytes = 0
				if batch.isEmpty { try await engine.received(id, message: .piece(first.piece, first.offset, first.bytes)) }
				else { try await engine.receivedBlocks(id, blocks: batch) }
			}
			do {
				// Consume already available bytes through bounded decoder feeds.
				for offset in stride(from: bytes.startIndex, to: bytes.endIndex, by: 65536) {
					try Task.checkCancellation()
					try decoder.feed(bytes[offset..<min(offset + 65536, bytes.endIndex)])
					if !ready {
						guard let handshake = try decoder.handshake() else { continue }
						let features = try await engine.handshaken(id, handshake: handshake); decoder.negotiate(features); ready = true
					}
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
				}
			} catch { let failure = error; try await flushBlocks(); throw failure }
			// Flush a short batch before the next network wait; never wait to fill it.
			try await flushBlocks()
		}
	}
	func run(id: UUID, hello: PeerHandshake, outgoing: Bool, engine: TCPTransfer, upload: TransferRateLimiter, download: TransferRateLimiter, idleTimeout: TimeInterval,
		hashes: [Data], encryption: PeerEncryptionConfiguration, clock: any TransportClock) async throws {
		defer { close() }
		let channel: PeerStream
		if let transport { channel = transport } else { channel = try await PeerStream.accept(stream, hashes: hashes, configuration: encryption, clock: clock) }
		await engine.negotiated(id, mode: channel.mode)
		if outgoing { try handshake(hello) }
		try await withThrowingTaskGroup(of: Void.self) { group in
			group.addTask { try await self.writeOutput(channel, id: id, engine: engine, upload: upload) }
			group.addTask { try await self.readInput(channel, id: id, engine: engine, download: download, idleTimeout: idleTimeout) }
			do { _ = try await group.next(); group.cancelAll(); close(); try await group.waitForAll() }
			catch { group.cancelAll(); close(); throw error }
		}
	}
}
