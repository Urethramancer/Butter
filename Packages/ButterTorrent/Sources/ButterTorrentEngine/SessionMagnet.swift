import Foundation
import ButterTorrentMetadata
import ButterTorrentNetworking
import ButterTorrentStorage

public struct SessionMagnetSnapshot: Sendable {
	public let id: String
	public let magnet: Magnet
	public let destination: URL
	public let running: Bool
	public let error: String
	public let trackers: [SessionTrackerSnapshot]
}

// Session-owned catalogue record. Its resolver carries the cancellable network work.
final class SessionPendingMagnet {
	let id: String
	let state: PendingMagnetState
	var magnet: Magnet
	var destination: URL
	var running = false
	var error = ""
	var downloadLimit: Int, uploadLimit: Int
	var revision = UUID()
	var resolver: SessionMagnetResolver?
	var tracker: SessionTracker?
	var trackerMessages: [URL: String] = [:]
	var trackerFailure = ""
	var verified: (TorrentMetadata, NetworkEndpoint?)?
	var promotion: Task<Void, Never>?
	init(id: String, state: PendingMagnetState, configuration: TCPTransferConfiguration) {
		self.id = id; self.state = state; magnet = state.magnet; destination = state.destination
		downloadLimit = configuration.downloadLimit; uploadLimit = configuration.uploadLimit
	}
	func snapshot(messages: [URL: String], fallback: String) -> SessionMagnetSnapshot {
		let trackers = magnet.trackers.map { url in SessionTrackerSnapshot(url: url, message: URL(string: url).flatMap { messages[$0] } ?? fallback) }
		return SessionMagnetSnapshot(id: id, magnet: magnet, destination: destination, running: running, error: error, trackers: trackers)
	}
}

actor SessionMagnetResolver {
	private struct Candidate: Hashable, Sendable {
		let endpoint: NetworkEndpoint
		let utp: UTPTransport?
		static func == (a: Self, b: Self) -> Bool { a.endpoint == b.endpoint && a.utp === b.utp }
		func hash(into hasher: inout Hasher) { hasher.combine(endpoint); hasher.combine(utp.map(ObjectIdentifier.init)) }
	}
	nonisolated let id = UUID()
	private let magnet: Magnet
	private let budget: TCPPeerBudget
	private let permits: TransferPermits
	private let configuration: TCPTransferConfiguration
	private let clock: any TransportClock
	private let transport: @Sendable (NetworkEndpoint) async throws -> UTPTransport?
	private let verified: @Sendable (TorrentMetadata, NetworkEndpoint?) async -> Void
	private var queue: PeerCandidateQueue<Candidate>?
	private var incoming: [UUID: (PeerStream, Task<Void, Never>)] = [:]
	private var closed = false
	init(magnet: Magnet, budget: TCPPeerBudget, permits: TransferPermits, configuration: TCPTransferConfiguration, clock: any TransportClock,
		transport: @escaping @Sendable (NetworkEndpoint) async throws -> UTPTransport?, verified: @escaping @Sendable (TorrentMetadata, NetworkEndpoint?) async -> Void) {
		self.magnet = magnet; self.budget = budget; self.permits = permits; self.configuration = configuration; self.clock = clock
		self.transport = transport; self.verified = verified
	}
	func enqueue(_ peers: [NetworkEndpoint], utp: UTPTransport? = nil) async {
		guard !closed else { return }
		if queue == nil { queue = PeerCandidateQueue(maximumPending: 32) { [weak self] candidate in await self?.connect(candidate) } }
		await queue?.enqueue(peers.filter { $0.port > 0 && !$0.address.isUnspecified && !$0.address.isMulticast && configuration.addressFilter.allows($0.address) }.map { Candidate(endpoint: $0, utp: utp) })
	}
	private func connect(_ candidate: Candidate) async {
		guard !closed else { return }
		do { try await permits.acquire() } catch { return }
		do {
			try Task.checkCancellation(); guard !closed else { throw PeerFailure.closed }
			let utp: UTPTransport?
			if let chosen = candidate.utp { utp = chosen } else { utp = try await transport(candidate.endpoint) }
			let exchange = MetadataExchange(clock: clock, budget: budget, encryption: configuration.encryption, utp: utp)
			let metadata = try await exchange.fetch(magnet, peers: [candidate.endpoint], timeout: 30)
			try Task.checkCancellation()
			await finish(metadata, endpoint: candidate.endpoint)
		} catch { }
		await permits.release()
	}
	func attach(_ stream: PeerStream, hello: PeerHandshake, peerID: Data) throws {
		try Task.checkCancellation()
		guard !closed, incoming.count < 2, let endpoint = stream.raw.remoteEndpoint,
			configuration.addressFilter.allows(endpoint.address) else { throw PeerFailure.limit("incoming metadata peers") }
		let id = UUID()
		let task = Task { [weak self] in
			guard let self else { stream.close(); return }
			await self.receive(stream, hello: hello, peerID: peerID, endpoint: endpoint, id: id)
		}
		incoming[id] = (stream, task)
	}

	private func receive(_ stream: PeerStream, hello: PeerHandshake, peerID: Data, endpoint: NetworkEndpoint, id: UUID) async {
		defer { incoming[id] = nil }
		do { try await permits.acquire() }
		catch { try? await stream.raw.shutdown(); return }
		do {
			try Task.checkCancellation()
			let (metadata, port) = try await MetadataExchange.receive(magnet, from: stream, hello: hello, peerID: peerID, clock: clock)
			try? await stream.raw.shutdown()
			try Task.checkCancellation()
			await finish(metadata, endpoint: port.map { NetworkEndpoint(address: endpoint.address, port: $0) })
		} catch { try? await stream.raw.shutdown() }
		await permits.release()
	}

	private func finish(_ metadata: TorrentMetadata, endpoint: NetworkEndpoint?) async {
		guard !closed else { return }
		closed = true
		await queue?.halt()
		// Publication runs separately and drains every competing connection.
		await verified(metadata, endpoint)
	}

	func stop() async {
		closed = true
		let jobs = Array(incoming.values)
		for (stream, task) in jobs { task.cancel(); stream.close() }
		await queue?.stop(); queue = nil
		for (_, task) in jobs { await task.value }
	}
	static func endpoint(_ text: String) -> NetworkEndpoint? {
		guard let colon = text.lastIndex(of: ":"), let port = UInt16(text[text.index(after: colon)...]), port > 0 else { return nil }
		var host = text[..<colon]
		if host.first == "[", host.last == "]" { host = host.dropFirst().dropLast() }
		else if host.contains(":") { return nil }
		return try? NetworkEndpoint(String(host), port: port)
	}
}
