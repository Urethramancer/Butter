import Foundation
import ButterTorrentMetadata
import ButterTorrentNetworking

public struct SessionDHTSnapshot: Sendable {
	public let enabled: Bool
	public let contacts: Int
	public let searches: Int
	public let error: String
	static let disabled = SessionDHTSnapshot(enabled: false, contacts: 0, searches: 0, error: "")
}

struct SessionDHTTarget: Sendable {
	let id: String
	let metadata: TorrentMetadata
	let owner: ManagedTransfer
}

struct SessionMagnetTarget: Sendable {
	let id: String
	let magnet: Magnet
	let revision: UUID
	let receive: @Sendable ([NetworkEndpoint]) async -> Void
}

// One owner per listening port; queries and peer connection attempts have separate bounds.
actor SessionDHT {
	private enum Target: Sendable {
		case transfer(SessionDHTTarget), magnet(SessionMagnetTarget)
		var id: String { switch self { case .transfer(let value): value.id; case .magnet(let value): value.id } }
		var transfer: SessionDHTTarget? { if case .transfer(let value) = self { value } else { nil } }
		func matches(_ other: Self) -> Bool {
			switch (self, other) {
			case (.transfer(let a), .transfer(let b)): a.owner === b.owner
			case (.magnet(let a), .magnet(let b)): a.revision == b.revision && a.magnet.hashes == b.magnet.hashes
			default: false
			}
		}
	}
	private struct Key: Hashable, Sendable { let family: Int; let id: String }
	private struct Candidate: Hashable, Sendable { let revision: UUID; let id: String; let endpoint: NetworkEndpoint }
	private struct Policy: Hashable { let hashes: InfoHashes; let isPrivate: Bool }
	private let nodes: [DHTNode]
	private let port: UInt16
	private let clock: any TransportClock
	private let connect: @Sendable (SessionDHTTarget, NetworkEndpoint) async -> Void
	private var targets: [String: Target] = [:]
	private var policy: Set<Policy> = []
	private var next: [Key: TimeInterval] = [:]
	private var failures: [Key: Int] = [:]
	private var errors: [Key: String] = [:]
	private var jobs: [Key: Task<Void, Never>] = [:]
	private var candidates: PeerCandidateQueue<Candidate>?
	private var ticker: Task<Void, Never>?
	private var revision = UUID()
	private var updating = false
	private var closed = false
	private var hinted: [NetworkEndpoint: TimeInterval] = [:]
	init(dispatchers: [UDPDispatcher], port: UInt16, bootstrap: [NetworkEndpoint]?, filter: PeerAddressFilter,
		clock: any TransportClock, connect: @escaping @Sendable (SessionDHTTarget, NetworkEndpoint) async -> Void) throws {
		nodes = try dispatchers.map { try DHTNode(dispatcher: $0, bootstrap: bootstrap, clock: clock, addressFilter: filter) }
		self.port = port; self.clock = clock; self.connect = connect
	}
	func update(_ entries: [SessionDHTTarget], metadata: [TorrentMetadata], magnets: [SessionMagnetTarget] = []) async throws {
		guard !closed else { throw NetworkFailure.closed }
		var wanted = Dictionary(uniqueKeysWithValues: entries.filter { !$0.metadata.inspection.private }.map { ($0.id, Target.transfer($0)) })
		let forbidden = Set(metadata.lazy.filter(\.inspection.private).flatMap { Self.wireHashes($0.hashes) })
		for magnet in magnets where forbidden.isDisjoint(with: Self.wireHashes(magnet.magnet.hashes)) {
			guard wanted[magnet.id] == nil else { throw NetworkFailure.invalid("duplicate DHT target") }
			wanted[magnet.id] = .magnet(magnet)
		}
		let policy = Set(metadata.map { Policy(hashes: $0.hashes, isPrivate: $0.inspection.private) })
		let continuing = Set(wanted.compactMap { id, target in targets[id]?.matches(target) == true ? id : nil })
		if self.policy == policy, wanted.count == targets.count, continuing.count == wanted.count { return }
		updating = true; defer { updating = false }; revision = UUID()
		await drain(); targets.removeAll(); self.policy = []
		hinted.removeAll()
		let unresolved = wanted.values.compactMap { target -> InfoHashes? in if case .magnet(let item) = target { item.magnet.hashes } else { nil } }
		for node in nodes { try await node.setTorrents(metadata, unresolved: unresolved) }
		guard !closed else { throw NetworkFailure.closed }
		targets = wanted; self.policy = policy
		next = next.filter { continuing.contains($0.key.id) }; failures = failures.filter { continuing.contains($0.key.id) }; errors = errors.filter { continuing.contains($0.key.id) }
		guard !targets.isEmpty else { return }
		candidates = PeerCandidateQueue { [weak self] candidate in await self?.connect(candidate) }
		let clock = clock
		ticker = Task { [weak self] in
			while !Task.isCancelled {
				await self?.launch()
				do { try await clock.sleep(for: 1) } catch { return }
			}
		}
	}
	private static func wireHashes(_ hashes: InfoHashes) -> [Data] { [hashes.v1, hashes.v2.map { Data($0.prefix(20)) }].compactMap { $0 } }
	private func launch() {
		guard !closed, !updating else { return }
		for family in nodes.indices {
			let capacity = 2 - jobs.keys.filter { $0.family == family }.count
			guard capacity > 0 else { continue }
			let due = targets.values.filter { let key = Key(family: family, id: $0.id); return jobs[key] == nil && clock.now() >= next[key, default: 0] }
				.sorted { next[Key(family: family, id: $0.id), default: 0] < next[Key(family: family, id: $1.id), default: 0] }
			for target in due.prefix(capacity) {
				let key = Key(family: family, id: target.id), node = nodes[family], revision = revision, port = port
				jobs[key] = Task { [weak self] in
					do {
						let peers: [NetworkEndpoint]
						switch target {
						case .transfer(let entry): peers = try await node.getPeers(for: entry.metadata, announcePort: port)
						case .magnet(let entry): peers = try await node.getPeers(for: entry.magnet)
						}
						await self?.finished(key, revision: revision, peers: peers, error: nil)
					}
					catch { await self?.finished(key, revision: revision, peers: [], error: error) }
				}
			}
		}
	}
	private func finished(_ key: Key, revision: UUID, peers: [NetworkEndpoint], error: Error?) async {
		guard revision == self.revision, !closed, !updating else { return }
		defer { if revision == self.revision { jobs[key] = nil } }
		if let error {
			failures[key] = min(6, failures[key, default: 0] + 1); errors[key] = error.localizedDescription
			next[key] = clock.now() + min(900, 30 * pow(2, Double(failures[key]! - 1)))
		} else {
			failures[key] = nil; errors[key] = nil; next[key] = clock.now() + 300
			if case .magnet(let target) = targets[key.id] { if !peers.isEmpty { await target.receive(peers) } }
			else { await candidates?.enqueue(peers.map { Candidate(revision: revision, id: key.id, endpoint: $0) }) }
		}
	}
	private func connect(_ candidate: Candidate) async {
		guard !closed, !updating, candidate.revision == revision, let target = targets[candidate.id]?.transfer else { return }
		await connect(target, candidate.endpoint)
	}
	func setFilter(_ filter: PeerAddressFilter) async {
		for node in nodes { await node.setAddressFilter(filter) }
		next.removeAll(); failures.removeAll(); errors.removeAll()
	}
	func learnNode(_ endpoint: NetworkEndpoint, for target: SessionDHTTarget) async throws {
		try Task.checkCancellation()
		guard !closed, !updating, targets[target.id]?.transfer?.owner === target.owner, !target.metadata.inspection.private else { return }
		let family = endpoint.address.isIPv6 ? 1 : 0, key = Key(family: endpoint.address.isIPv6 ? 1 : 0, id: target.id), revision = revision
		hinted = hinted.filter { $0.value > clock.now() }
		guard hinted[endpoint] == nil else { return }
		guard hinted.count < 256 else { throw NetworkFailure.limit("DHT node hints") }
		hinted[endpoint] = clock.now() + 60
		do { try await nodes[family].addNode(endpoint, for: target.metadata) }
		catch { if revision == self.revision { hinted[endpoint] = nil }; throw error }
		guard !closed, !updating, revision == self.revision, targets[target.id]?.transfer?.owner === target.owner else { return }
		if let previous = jobs[key] { previous.cancel(); await previous.value }
		guard !closed, !updating, revision == self.revision else { return }
		failures[key] = nil; errors[key] = nil
		next[key] = clock.now(); launch()
	}
	func snapshot() async -> SessionDHTSnapshot {
		var contacts = 0; for node in nodes { contacts += await node.contactCount }
		return SessionDHTSnapshot(enabled: !closed, contacts: contacts, searches: jobs.count, error: errors.values.sorted().first ?? "")
	}
	private func drain() async {
		ticker?.cancel(); await candidates?.halt()
		let active = Array(jobs.values); for job in active { job.cancel() }
		await ticker?.value; ticker = nil
		for job in active { await job.value }; jobs.removeAll()
		await candidates?.stop(); candidates = nil
	}
	func shutdown() async {
		closed = true; revision = UUID(); await drain()
		for node in nodes { await node.shutdown() }
		targets.removeAll(); policy.removeAll()
	}
}
