import Foundation
import ButterTorrentNetworking

// One reader and one writer own the TCP stream; the controller owns protocol state.
final class PeerSession: @unchecked Sendable {
	struct Outbound: Sendable { let bytes: Data; let payload: Int; let token: UUID?; let block: PeerBlock? }
	let stream: TCPStream
	private let lock = NSLock()
	private let outgoing = AsyncStream<Outbound>.makeStream(bufferingPolicy: .bufferingOldest(128))
	private var queuedBytes = 0
	private var closed = false
	private var tokens: Set<UUID> = []
	init(stream: TCPStream) { self.stream = stream }
	func send(_ message: PeerMessage, token: UUID? = nil, block: PeerBlock? = nil) throws {
		let payload: Int
		if case .piece(_, _, let bytes) = message { payload = bytes.count } else { payload = 0 }
		try enqueue(Outbound(bytes: message.encoded(), payload: payload, token: token, block: block))
	}
	private func enqueue(_ item: Outbound) throws {
		try lock.withLock {
			guard !closed else { throw PeerFailure.closed }
			guard queuedBytes + item.bytes.count <= 524_288 else { throw PeerFailure.limit("peer output bytes") }
			if case .enqueued = outgoing.continuation.yield(item) {
				queuedBytes += item.bytes.count; if let token = item.token { tokens.insert(token) }
			} else { throw PeerFailure.limit("peer output messages") }
		}
	}
	func cancel(_ token: UUID) { _ = lock.withLock { tokens.remove(token) } }
	func close() { lock.withLock { closed = true; tokens.removeAll() }; outgoing.continuation.finish(); stream.close() }
	func run(id: UUID, hello: PeerHandshake, engine: TCPTransfer, upload: TransferRateLimiter, idleTimeout: TimeInterval) async throws {
		defer { close() }
		try enqueue(Outbound(bytes: hello.encoded, payload: 0, token: nil, block: nil))
		try await withThrowingTaskGroup(of: Void.self) { group in
			group.addTask {
				for await item in self.outgoing.stream {
					self.lock.withLock { self.queuedBytes -= item.bytes.count }
					try Task.checkCancellation()
					if let token = item.token, !self.lock.withLock({ self.tokens.contains(token) }) { continue }
					try await upload.consume(item.payload)
					if let token = item.token, !self.lock.withLock({ self.tokens.remove(token) != nil }) { continue }
					try await self.stream.write(item.bytes)
					if let block = item.block, let token = item.token { await engine.uploaded(id, block: block, token: token, count: item.payload) }
				}
			}
			group.addTask {
				var decoder = PeerWireDecoder(), ready = false, frames = 0
				while true {
					let bytes = try await self.stream.read(timeout: ready ? idleTimeout : 10)
					if bytes.isEmpty { try decoder.finish(); return }
					try decoder.feed(bytes)
					if !ready {
						guard let handshake = try decoder.handshake() else { continue }
						try await engine.handshaken(id, handshake: handshake); ready = true
					}
					while let message = try decoder.next() {
						try Task.checkCancellation(); try await engine.received(id, message: message)
						frames += 1; if frames % 128 == 0 { await Task.yield() }
					}
				}
			}
			do { _ = try await group.next(); group.cancelAll(); close(); try await group.waitForAll() }
			catch { group.cancelAll(); close(); throw error }
		}
	}
}
