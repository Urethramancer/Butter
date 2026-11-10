import Foundation
import ButterTorrentNetworking

// Disposable interoperability fixture; both directions split handshake and payload bytes.
actor TCPFragmentingRelay {
	nonisolated let port: UInt16
	private let listener: TCPListener
	private var streams: [TCPStream] = []
	private var task: Task<Void, Error>?
	private var closed = false
	private init(listener: TCPListener) { self.listener = listener; port = listener.port }
	static func open(host: String, target: NetworkEndpoint) async throws -> TCPFragmentingRelay {
		let listener = try await TCPListener.listen(address: IPAddress(host)), relay = TCPFragmentingRelay(listener: listener)
		await relay.start(target: target); return relay
	}
	private func start(target: NetworkEndpoint) { task = Task { try await self.run(target: target) } }
	private func run(target: NetworkEndpoint) async throws {
		let incoming = try await listener.accept(timeout: 10)
		guard !closed else { incoming.close(); return }; streams.append(incoming)
		let outgoing = try await TCPStream.connect(to: target)
		guard !closed else { outgoing.close(); return }; streams.append(outgoing)
		defer { incoming.close(); outgoing.close() }
		try await withThrowingTaskGroup(of: Void.self) { group in
			group.addTask { try await Self.pipe(incoming, to: outgoing) }
			group.addTask { try await Self.pipe(outgoing, to: incoming) }
			do { _ = try await group.next(); group.cancelAll(); incoming.close(); outgoing.close(); try await group.waitForAll() }
			catch { group.cancelAll(); incoming.close(); outgoing.close(); throw error }
		}
	}
	private static func pipe(_ input: TCPStream, to output: TCPStream) async throws {
		var sent = 0
		while true {
			let bytes = try await input.read(maximumBytes: 8192, timeout: 20)
			if bytes.isEmpty { return }
			var offset = 0
			while offset < bytes.count {
				try Task.checkCancellation()
				let count = min(sent < 68 ? 1 : 4093, bytes.count - offset)
				try await output.write(bytes.subdata(in: offset..<(offset + count))); offset += count; sent += count
				if sent <= 68 { try await Task.sleep(for: .microseconds(100)) }
			}
		}
	}
	func close() async {
		closed = true; task?.cancel(); for stream in streams { stream.close() }
		try? await listener.shutdown(); _ = try? await task?.value; task = nil; streams.removeAll()
	}
}
