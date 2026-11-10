import Foundation
import ButterTorrentNetworking

// Disposable interoperability fixture; both directions split handshake and payload bytes.
actor TCPFragmentingRelay {
	nonisolated let port: UInt16
	private let listener: TCPListener
	private var streams: [TCPStream] = []
	private var task: Task<Void, Error>?
	private var closed = false
	private let handshakeBytes: Int
	private let legacyHash: Data?, rejectHash: Data?
	private(set) var rejectedIdentity = false
	private(set) var failure = ""
	private init(listener: TCPListener, handshakeBytes: Int, legacyHash: Data?, rejectHash: Data?) {
		self.listener = listener; port = listener.port; self.handshakeBytes = handshakeBytes; self.legacyHash = legacyHash; self.rejectHash = rejectHash
	}
	static func open(host: String, target: NetworkEndpoint, handshakeBytes: Int = 68, legacyHash: Data? = nil, rejectHash: Data? = nil) async throws -> TCPFragmentingRelay {
		let listener = try await TCPListener.listen(address: IPAddress(host)), relay = TCPFragmentingRelay(listener: listener, handshakeBytes: handshakeBytes, legacyHash: legacyHash, rejectHash: rejectHash)
		await relay.start(target: target); return relay
	}
	private func start(target: NetworkEndpoint) {
		task = Task {
			do { try await self.run(target: target) }
			catch { failure = String(describing: error); throw error }
		}
	}
	private func run(target: NetworkEndpoint) async throws {
		if let rejectHash {
			let rejected = try await listener.accept(timeout: 10); streams.append(rejected); defer { rejected.close() }
			let hello = try await Self.readHello(rejected)
			guard Data(hello[28..<48]) == rejectHash else { throw NetworkFailure.invalid("unexpected first hybrid wire identity") }
			rejectedIdentity = true
		}
		let incoming = try await listener.accept(timeout: 10)
		guard !closed else { incoming.close(); return }; streams.append(incoming); defer { incoming.close() }
		let outgoing = try await TCPStream.connect(to: target)
		guard !closed else { outgoing.close(); return }; streams.append(outgoing)
		defer { outgoing.close() }
		let handshakeBytes = handshakeBytes, legacyHash = legacyHash
		try await withThrowingTaskGroup(of: Void.self) { group in
			group.addTask { try await Self.pipe(incoming, to: outgoing, handshakeBytes: handshakeBytes, legacyHash: legacyHash) }
			group.addTask { try await Self.pipe(outgoing, to: incoming, handshakeBytes: handshakeBytes, legacyHash: legacyHash) }
			do { _ = try await group.next(); group.cancelAll(); incoming.close(); outgoing.close(); try await group.waitForAll() }
			catch { group.cancelAll(); incoming.close(); outgoing.close(); throw error }
		}
	}
	private static func readHello(_ input: TCPStream) async throws -> Data {
		var bytes = Data()
		while bytes.count < 68 {
			let next = try await input.read(maximumBytes: 68 - bytes.count, timeout: 10)
			guard !next.isEmpty else { throw NetworkFailure.closed }; bytes.append(next)
		}
		return bytes
	}
	private static func pipe(_ input: TCPStream, to output: TCPStream, handshakeBytes: Int, legacyHash: Data?) async throws {
		var sent = 0
		if let legacyHash {
			var hello = try await readHello(input)
			guard Data(hello[28..<48]) == legacyHash else { throw NetworkFailure.invalid("hybrid fixture did not use v1 framing") }
			hello[27] &= ~16 // Suppress BEP 52 upgrade to model a legacy-only remote swarm.
			try await output.write(hello); sent = hello.count
		}
		while true {
			let bytes = try await input.read(maximumBytes: 8192, timeout: 20)
			if bytes.isEmpty { return }
			var offset = 0
			while offset < bytes.count {
				try Task.checkCancellation()
				let count = min(sent < handshakeBytes ? 1 : 4093, bytes.count - offset)
				try await output.write(bytes.subdata(in: offset..<(offset + count))); offset += count; sent += count
				if sent <= handshakeBytes { try await Task.sleep(for: .microseconds(100)) }
			}
		}
	}
	func close() async {
		closed = true; task?.cancel(); for stream in streams { stream.close() }
		try? await listener.shutdown(); _ = try? await task?.value; task = nil; streams.removeAll()
	}
}
