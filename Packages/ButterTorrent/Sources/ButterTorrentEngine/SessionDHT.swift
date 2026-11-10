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

// One owner per listening port; queries and peer connection attempts have separate bounds.
actor SessionDHT {
	private struct Key: Hashable, Sendable { let family: Int; let id: String }
	private struct Candidate: Hashable, Sendable { let revision: UUID; let id: String; let endpoint: NetworkEndpoint }
	private struct Policy: Hashable { let hashes: InfoHashes; let isPrivate: Bool }
	private let nodes: [DHTNode]
	private let port: UInt16
	private let clock: any TransportClock
	private let connect: @Sendable (SessionDHTTarget, NetworkEndpoint) async -> Void
	private var targets: [String: SessionDHTTarget] = [:]
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
	init(dispatchers: [UDPDispatcher], port: UInt16, bootstrap: [NetworkEndpoint]?, filter: PeerAddressFilter,
		clock: any TransportClock, connect: @escaping @Sendable (SessionDHTTarget, NetworkEndpoint) async -> Void) throws {
		nodes = try dispatchers.map { try DHTNode(dispatcher: $0, bootstrap: bootstrap, clock: clock, addressFilter: filter) }
		self.port = port; self.clock = clock; self.connect = connect
	}
	func update(_ entries: [SessionDHTTarget], metadata: [TorrentMetadata]) async throws {
		guard !closed else { throw NetworkFailure.closed }
		let wanted = Dictionary(uniqueKeysWithValues: entries.filter { !$0.metadata.inspection.private }.map { ($0.id, $0) })
		let policy = Set(metadata.map { Policy(hashes: $0.hashes, isPrivate: $0.inspection.private) })
		if self.policy == policy, wanted.count == targets.count,
			wanted.allSatisfy({ id, target in targets[id]?.owner === target.owner }) { return }
		updating = true; defer { updating = false }; revision = UUID()
		await drain(); targets.removeAll(); self.policy = []
		for node in nodes { try await node.setTorrents(metadata) }
		guard !closed else { throw NetworkFailure.closed }
		targets = wanted; self.policy = policy
		next = next.filter { targets[$0.key.id] != nil }; failures = failures.filter { targets[$0.key.id] != nil }; errors = errors.filter { targets[$0.key.id] != nil }
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
					do { let peers = try await node.getPeers(for: target.metadata, announcePort: port); await self?.finished(key, revision: revision, peers: peers, error: nil) }
					catch { await self?.finished(key, revision: revision, peers: [], error: error) }
				}
			}
		}
	}
	private func finished(_ key: Key, revision: UUID, peers: [NetworkEndpoint], error: Error?) async {
		guard revision == self.revision, !closed, !updating else { return }; jobs[key] = nil
		if let error {
			failures[key] = min(6, failures[key, default: 0] + 1); errors[key] = error.localizedDescription
			next[key] = clock.now() + min(900, 30 * pow(2, Double(failures[key]! - 1)))
		} else {
			failures[key] = nil; errors[key] = nil; next[key] = clock.now() + 300
			await candidates?.enqueue(peers.map { Candidate(revision: revision, id: key.id, endpoint: $0) })
		}
	}
	private func connect(_ candidate: Candidate) async {
		guard !closed, !updating, candidate.revision == revision, let target = targets[candidate.id] else { return }
		await connect(target, candidate.endpoint)
	}
	func setFilter(_ filter: PeerAddressFilter) async {
		for node in nodes { await node.setAddressFilter(filter) }
		next.removeAll(); failures.removeAll(); errors.removeAll()
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
