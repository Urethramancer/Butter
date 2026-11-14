import Foundation
import ButterTorrentNetworking

// One reader and one writer own the TCP stream; the controller owns protocol state.
final class PeerSession: @unchecked Sendable {
	static let outputByteLimit = 524_288
	static let uploadRequestLimit = 32
	// Advertise a window that fits maximum payloads including their wire framing.
	static let advertisedUploadRequestLimit = min(uploadRequestLimit, outputByteLimit / (16384 + 13))
	final class WireBuffer: Sendable {
		let bytes: Data
		init(_ bytes: Data) { self.bytes = bytes }
	}
	struct OutputReceipt: Sendable { let payload: Int; let token: UUID?; let block: PeerBlock? }
	struct Outbound: Sendable {
		enum Contents: Sendable {
			case bytes(Data)
			case shared(WireBuffer, Range<Int>)
		}
		let contents: Contents
		let receipt: OutputReceipt
		var buffer: WireBuffer? {
			if case .shared(let buffer, _) = contents { return buffer }; return nil
		}
		var range: Range<Int> {
			switch contents {
			case .bytes(let bytes): return bytes.startIndex..<bytes.endIndex
			case .shared(_, let range): return range
			}
		}
		var bytes: Data {
			switch contents {
			case .bytes(let bytes): return bytes
			case .shared(let buffer, let range): return buffer.bytes[range]
			}
		}
		var payload: Int { receipt.payload }
		var token: UUID? { receipt.token }
		var block: PeerBlock? { receipt.block }
		init(bytes: Data, payload: Int, token: UUID?, block: PeerBlock?) {
			// Ordinary frames retain their original Data without another allocation.
			contents = .bytes(bytes)
			receipt = OutputReceipt(payload: payload, token: token, block: block)
		}
		init(buffer: WireBuffer, range: Range<Int>, token: UUID, block: PeerBlock) {
			contents = .shared(buffer, range)
			receipt = OutputReceipt(payload: block.length, token: token, block: block)
		}
		init(controlBuffer: WireBuffer, range: Range<Int>) {
			contents = .shared(controlBuffer, range)
			receipt = OutputReceipt(payload: 0, token: nil, block: nil)
		}
	}
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
			guard !closed, bytes > 0, bytes <= Self.outputByteLimit - queuedBytes - reservedBytes,
				queuedMessages + reservations.count < 128, !tokens.contains(token) else { return false }
			tokens.insert(token); reservations[token] = bytes; reservedBytes += bytes; return true
		}
	}
	func send(_ message: PeerMessage, token: UUID? = nil, block: PeerBlock? = nil) throws {
		let payload: Int
		if case .piece(_, _, let bytes) = message { payload = bytes.count } else { payload = 0 }
		try enqueue(Outbound(bytes: message.encoded(), payload: payload, token: token, block: block))
	}
	func sendRequests(_ blocks: [PeerBlock]) throws {
		guard blocks.count <= 32 else { throw PeerFailure.limit("peer request batch messages") }
		if blocks.count <= 1 || stream.kind != .tcp {
			for block in blocks { try send(.request(block)) }; return
		}
		var bytes = Data(capacity: blocks.count * 17)
		for block in blocks { try PeerMessage.appendRequest(block, to: &bytes) }
		let buffer = WireBuffer(bytes)
		let frames = blocks.indices.map { Outbound(controlBuffer: buffer, range: ($0 * 17)..<(($0 + 1) * 17)) }
		try lock.withLock {
			guard !closed else { throw PeerFailure.closed }
			guard queuedBytes + reservedBytes + bytes.count <= Self.outputByteLimit else { throw PeerFailure.limit("peer output bytes") }
			guard queuedMessages + reservations.count + frames.count <= 128 else { throw PeerFailure.limit("peer output messages") }
			outgoing.append(contentsOf: frames); queuedBytes += bytes.count; queuedMessages += frames.count
			outputReady.continuation.yield(())
		}
	}
	func sendPieces(_ requests: [(token: UUID, block: PeerBlock)], piece: Data) throws {
		// A µTP write is retained independently by transport admission. Do not make
		// a single admitted frame retain the other frames in a shared wire buffer.
		if stream.kind != .tcp {
			for (token, block) in requests {
				guard (1...16384).contains(block.length), block.offset >= 0,
					block.offset <= piece.count - block.length else { throw PeerFailure.invalid("upload piece range") }
				let offset = piece.startIndex + block.offset
				try send(.piece(block.piece, block.offset, piece[offset..<(offset + block.length)]), token: token, block: block)
			}
			return
		}
		var start = 0
		while start < requests.count {
			var end = start, size = 0
			while end < requests.count, end - start < 16 {
				let block = requests[end].block
				guard (1...16384).contains(block.length), block.offset >= 0,
					block.offset <= piece.count - block.length else { throw PeerFailure.invalid("upload piece range") }
				guard block.length + 13 <= 262144 - size else { break }
				size += block.length + 13; end += 1
			}
			var bytes = Data(capacity: size), ranges: [Range<Int>] = []
			for request in requests[start..<end] {
				let block = request.block, lower = bytes.count, offset = piece.startIndex + block.offset
				try PeerMessage.appendPiece(block.piece, block.offset, piece[offset..<(offset + block.length)], to: &bytes)
				ranges.append(lower..<bytes.count)
			}
			let buffer = WireBuffer(bytes)
			try lock.withLock {
				guard !closed else { throw PeerFailure.closed }
				// Every frame already owns a reservation. Moving it into the queue
				// leaves total byte/message admission unchanged; check those totals once.
				guard queuedBytes + reservedBytes <= Self.outputByteLimit else { throw PeerFailure.limit("peer output bytes") }
				guard queuedMessages + reservations.count <= 128 else { throw PeerFailure.limit("peer output messages") }
				var published = false
				// A late cancellation or invalid credit retains the original published
				// prefix and must still wake its writer before propagating the error.
				defer { if published { outputReady.continuation.yield(()) } }
				for (index, request) in requests[start..<end].enumerated() {
					guard tokens.contains(request.token), let credit = reservations[request.token] else { throw PeerFailure.closed }
					guard credit == ranges[index].count else { throw PeerFailure.invalid("upload output reservation") }
					reservations[request.token] = nil; reservedBytes -= credit
					outgoing.append(Outbound(buffer: buffer, range: ranges[index], token: request.token, block: request.block))
					queuedBytes += credit; queuedMessages += 1; published = true
				}
			}
			start = end
		}
	}
	static func outputBytes(_ items: [Outbound]) -> Data {
		guard let first = items.first else { return Data() }
		if items.count == 1 { return first.bytes }
		if let buffer = first.buffer {
			var end = first.range.upperBound
			let contiguous = items.dropFirst().allSatisfy { item in
				guard item.buffer === buffer, item.range.lowerBound == end else { return false }
				end = item.range.upperBound; return true
			}
			if contiguous { return buffer.bytes[first.range.lowerBound..<end] }
		}
		var joined = Data(capacity: items.reduce(0) { $0 + $1.range.count })
		for item in items { joined.append(item.bytes) }; return joined
	}
	private func enqueue(_ item: Outbound) throws {
		try lock.withLock {
			guard !closed else { throw PeerFailure.closed }
			let credit: Int
			if let token = item.token {
				guard tokens.contains(token), let reserved = reservations[token] else { throw PeerFailure.closed }
				guard reserved == item.range.count else { throw PeerFailure.invalid("upload output reservation") }; credit = reserved
			} else { credit = 0 }
			guard queuedBytes + reservedBytes - credit + item.range.count <= Self.outputByteLimit else { throw PeerFailure.limit("peer output bytes") }
			guard queuedMessages + reservations.count - (item.token == nil ? 0 : 1) < 128 else { throw PeerFailure.limit("peer output messages") }
			if let token = item.token { reservations[token] = nil; reservedBytes -= credit }
			outgoing.append(item); queuedBytes += item.range.count; queuedMessages += 1
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
				guard item.range.count <= maximumBytes - bytes else { break }
				count += 1; bytes += item.range.count
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
	// Return receipts rather than queued frames so a fallback joined write does not
	// retain its source buffers while the network is suspended.
	private func nextOutput(upload: TransferRateLimiter) async throws -> (bytes: Data, receipts: [OutputReceipt])? {
		while true {
			try Task.checkCancellation()
			let unrestricted = await upload.consumeUnrestrictedBatch()
			// µTP retains each write against a shared transport budget; keep its frame-sized admission.
			let items = takeOutgoing(maximumCount: unrestricted && stream.kind == .tcp ? 16 : 1, maximumBytes: 262144)
			if items.isEmpty { return nil }
			if !unrestricted, let item = items.first {
				if let token = item.token, !lock.withLock({ tokens.contains(token) }) { continue }
				do { try await upload.consume(item.payload) { item.token.map { token in !self.lock.withLock({ self.tokens.contains(token) }) } ?? false } }
				catch is CancellationError {
					if !Task.isCancelled, let token = item.token, !lock.withLock({ tokens.contains(token) }) { continue }; throw CancellationError()
				}
			}
			try Task.checkCancellation()
			let ready = claimOutgoing(items)
			if ready.isEmpty { continue }
			return (Self.outputBytes(ready), ready.filter { $0.token != nil }.map(\.receipt))
		}
	}
	private func writeOutput(_ channel: PeerStream, id: UUID, engine: TCPTransfer, upload: TransferRateLimiter) async throws {
		for await _ in outputReady.stream {
			while let output = try await nextOutput(upload: upload) {
				// Drain only work already available; never wait to fill a network batch.
				try await channel.write(output.bytes)
				if !output.receipts.isEmpty { await engine.uploadedBatch(id, items: output.receipts) }
			}
		}
	}
	private func readInput(_ channel: PeerStream, id: UUID, engine: TCPTransfer, download: TransferRateLimiter, idleTimeout: TimeInterval) async throws {
		let readAhead = PeerReadAhead()
		try await withTaskCancellationHandler {
			do { try await readInput(channel, id: id, engine: engine, download: download, idleTimeout: idleTimeout, readAhead: readAhead) }
			catch { await readAhead.drain(); throw error }
			await readAhead.drain()
		} onCancel: { readAhead.cancel() }
	}
	private func readInput(_ channel: PeerStream, id: UUID, engine: TCPTransfer, download: TransferRateLimiter, idleTimeout: TimeInterval, readAhead: PeerReadAhead) async throws {
		var decoder = PeerWireDecoder(), ready = false, frames = 0
		while true {
			let cycleStarted = ReceivePipelineDiagnostics.tick()
			let admissionStarted = ReceivePipelineDiagnostics.tick()
			var maximum = 65536
			if stream.kind == .tcp, await download.consumeUnrestrictedBatch() { maximum = 262144 }
			let admissionEnded = ReceivePipelineDiagnostics.tick()
			let readStarted = ReceivePipelineDiagnostics.tick()
			let bytes: Data
			let prefetched = readAhead.take()
			do {
				if let prefetched {
					bytes = try await withTaskCancellationHandler { try await prefetched.value } onCancel: { prefetched.cancel() }
				} else { bytes = try await channel.read(maximumBytes: maximum, timeout: ready ? idleTimeout : 10) }
			}
			catch {
				let failed = ReceivePipelineDiagnostics.sample(.terminalRead, started: readStarted)
				failed?.finish(error is CancellationError ? "cancelled" : "failed"); throw error
			}
			let readEnded = ReceivePipelineDiagnostics.tick()
			if bytes.isEmpty {
				let terminal = ReceivePipelineDiagnostics.sample(.terminalRead, started: readStarted)
				var outcome = "failed"
				defer { terminal?.finish(outcome) }
				guard ready else { throw NetworkFailure.closed }
				try decoder.finish(); outcome = "eof"; return
			}
			let cycle = ReceivePipelineDiagnostics.sample(.reader, started: cycleStarted)
			cycle?.end(.readAdmission, since: admissionStarted, until: admissionEnded)
			cycle?.end(.streamRead, since: readStarted, until: readEnded); cycle?.histogram("readBytes", bytes.count)
			if prefetched != nil { cycle?.count("prefetchedReads") }
			var cycleOutcome = "failed"
			defer { cycle?.finish(cycleOutcome) }
			var firstBlock: IncomingPieceBlock?, blocks: [IncomingPieceBlock] = [], blockBytes = 0
			func flushBlocks(_ reason: ReceivePipelineSample.Flush) async throws {
				guard let first = firstBlock else { return }
				let batch = blocks, payloadBytes = blockBytes; blocks = []; firstBlock = nil; blockBytes = 0
				if maximum == PeerReadAhead.maximumBytes, reason != .error,
					let capacity = readAhead.prefetch(retainedBytes: bytes.count, read: { size in try await channel.read(maximumBytes: size, timeout: idleTimeout) }) {
					cycle?.count("prefetchStarted"); cycle?.histogram("prefetchCapacityBytes", capacity)
				}
				let sample = ReceivePipelineDiagnostics.sample(.dispatch)
				sample?.histogram("blocks", batch.isEmpty ? 1 : batch.count); sample?.histogram("payloadBytes", payloadBytes)
				sample?.count("reason." + reason.rawValue)
				let dispatchStarted = cycle?.tick()
				var outcome = "failed"
				defer { sample?.finish(outcome); cycle?.end(.dispatch, since: dispatchStarted) }
				do {
					if batch.isEmpty { try await engine.received(id, message: .piece(first.piece, first.offset, first.bytes), profile: sample) }
					else { try await engine.receivedBlocks(id, blocks: batch, profile: sample) }
					outcome = "succeeded"
				} catch { if error is CancellationError { outcome = "cancelled" }; throw error }
			}
			do {
				// Consume already available bytes through bounded decoder feeds.
				for offset in stride(from: bytes.startIndex, to: bytes.endIndex, by: 65536) {
					try Task.checkCancellation()
					try decoder.feed(bytes[offset..<min(offset + 65536, bytes.endIndex)])
					if !ready {
						guard let handshake = try decoder.handshake() else { continue }
						do {
							let started = cycle?.tick(); defer { cycle?.end(.controlDispatch, since: started) }
							let features = try await engine.handshaken(id, handshake: handshake); decoder.negotiate(features); ready = true
						}
					}
					while let message = try decoder.next() {
						try Task.checkCancellation()
						if case .piece(let piece, let offset, let bytes) = message {
							if bytes.count > 262144 - blockBytes || blocks.count == 16 { try await flushBlocks(.budget) }
							cycle?.count("decodedBlocks"); cycle?.count("payloadBytes", bytes.count)
							let block = IncomingPieceBlock(piece: piece, offset: offset, bytes: bytes)
							if let first = firstBlock {
								if blocks.isEmpty { blocks = [first, block] } else { blocks.append(block) }
							} else { firstBlock = block }
							blockBytes += bytes.count
						} else {
							try await flushBlocks(.control)
							let started = cycle?.tick(); defer { cycle?.end(.controlDispatch, since: started) }
							try await engine.received(id, message: message)
						}
						frames += 1
						if frames % 128 == 0 {
							try await flushBlocks(.yield)
							let started = cycle?.tick(); await Task.yield(); cycle?.end(.schedulerYield, since: started)
						}
					}
				}
			} catch {
				let failure = error
				do { try await flushBlocks(.error) }
				catch { cycleOutcome = error is CancellationError ? "cancelled" : "failed"; throw error }
				cycleOutcome = failure is CancellationError ? "cancelled" : "failed"; throw failure
			}
			// Flush a short batch before the next network wait; never wait to fill it.
			do { try await flushBlocks(.readEnd); cycleOutcome = "succeeded" }
			catch { cycleOutcome = error is CancellationError ? "cancelled" : "failed"; throw error }
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
