import Foundation
import OSLog
import ButterTorrentMetadata
import ButterTorrentNetworking

/// LocalDiscoveryFactory supplies owned interface services, including injected test transports.
public typealias LocalDiscoveryFactory = @Sendable (UInt16, any TransportClock) throws -> [LocalDiscovery]

actor SessionLocalDiscovery {
	private static let log = Logger(subsystem: "ButterTorrent", category: "LocalDiscovery")
	private struct Candidate: Hashable, Sendable { let revision: UUID; let hash: Data; let endpoint: NetworkEndpoint }
	private let services: [LocalDiscovery]
	private let clock: any TransportClock
	private let connect: @Sendable (SessionDHTTarget, NetworkEndpoint) async -> Void
	private var targets: [Data: SessionDHTTarget] = [:]
	private var generations: [Int: UUID] = [:]
	private var candidates: PeerCandidateQueue<Candidate>?
	private var ticker: Task<Void, Never>?
	private var pumps: [Task<Void, Never>] = []
	private var revision = UUID()
	private var updating = false, closed = false
	private(set) var failure = ""
	init(services: [LocalDiscovery], clock: any TransportClock, connect: @escaping @Sendable (SessionDHTTarget, NetworkEndpoint) async -> Void) {
		self.services = services; self.clock = clock; self.connect = connect
	}
	static func interfaces(port: UInt16, clock: any TransportClock, loopbackOnly: Bool) throws -> [LocalDiscovery] {
		var seen: Set<String> = [], services: [LocalDiscovery] = []
		let cookie = UUID().uuidString
		for interface in try NetworkEnvironment.interfaces(includeLoopback: loopbackOnly, multicastOnly: true) {
			guard !loopbackOnly || interface.address.isLoopback else { continue }
			let key = "\(interface.index)-\(interface.address.isIPv6)"
			guard seen.insert(key).inserted else { continue }
			// An unavailable family must not prevent other interfaces from participating.
			do { services.append(try LocalDiscovery.open(interface: interface.address, interfaceIndex: interface.index, peerPort: port, cookie: cookie, clock: clock)) }
			catch { log.error("Could not open local discovery on \(interface.name, privacy: .public): \(error.localizedDescription, privacy: .public)") }
		}
		return services
	}
	func update(_ entries: [SessionDHTTarget]) async throws {
		guard !closed else { throw NetworkFailure.closed }; guard !updating else { throw NetworkFailure.busy }
		var wanted: [Data: SessionDHTTarget] = [:]
		for entry in entries where !entry.metadata.inspection.private {
			for hash in [entry.metadata.hashes.v1, entry.metadata.hashes.v2.map({ Data($0.prefix(20)) })].compactMap({ $0 }) {
				guard wanted[hash] == nil || wanted[hash]?.id == entry.id else { throw PeerFailure.invalid("ambiguous local discovery swarm") }
				wanted[hash] = entry
			}
		}
		if wanted.count == targets.count, wanted.allSatisfy({ targets[$0.key]?.id == $0.value.id && targets[$0.key]?.owner === $0.value.owner }) { return }
		updating = true; defer { updating = false }; revision = UUID()
		await drain(); targets.removeAll(); generations.removeAll()
		for (index, service) in services.enumerated() {
			try await service.setTorrents(entries.map(\.metadata)); generations[index] = await service.revision
		}
		guard !closed else { throw NetworkFailure.closed }; targets = wanted
		if pumps.isEmpty {
			for (index, service) in services.enumerated() {
				pumps.append(Task { [weak self] in
					for await peer in service.peers { if Task.isCancelled { return }; await self?.receive(peer, from: index) }
				})
			}
		}
		guard !targets.isEmpty else { return }
		candidates = PeerCandidateQueue { [weak self] candidate in await self?.connect(candidate) }
		let clock = clock
		ticker = Task { [weak self] in
			while !Task.isCancelled {
				await self?.announce()
				do { try await clock.sleep(for: 1) } catch { return }
			}
		}
	}
	private func announce() async {
		guard !closed, !updating else { return }
		for service in services {
			guard !Task.isCancelled else { return }
			do { _ = try await service.announceIfDue() }
			catch { if !Task.isCancelled { failure = error.localizedDescription } }
		}
	}
	private func receive(_ peer: DiscoveredPeer, from index: Int) async {
		guard !closed, !updating, generations[index] == peer.revision, targets[peer.infoHash] != nil else { return }
		await candidates?.enqueue([Candidate(revision: revision, hash: peer.infoHash, endpoint: peer.endpoint)])
	}
	private func connect(_ candidate: Candidate) async {
		guard !closed, !updating, !Task.isCancelled, candidate.revision == revision, let target = targets[candidate.hash] else { return }
		await connect(target, candidate.endpoint)
	}
	private func drain() async {
		ticker?.cancel(); await candidates?.halt(); await ticker?.value; ticker = nil
		await candidates?.stop(); candidates = nil
	}
	func shutdown() async {
		closed = true; revision = UUID(); await drain()
		for pump in pumps { pump.cancel() }; for pump in pumps { await pump.value }; pumps.removeAll()
		for service in services { do { try await service.shutdown() } catch { failure = error.localizedDescription } }
		targets.removeAll(); generations.removeAll()
	}
}
