import Foundation
import ButterTorrentMetadata

/// DHTNode owns a bounded BEP 5/32/42 node on one address family's shared UDP port.
/// Register verified metadata before starting discovery; unknown magnets have no discovery API.
public actor DHTNode {
	let dispatcher: UDPDispatcher
	let clock: any TransportClock
	let resolver: any AddressResolving
	let bootstrap: [NetworkEndpoint]?
	var table: DHTRoutingTable
	var permitted: Set<Data> = [], forbidden: Set<Data> = []
	var pump: Task<Void, Never>?
	var closed = false
	var updating = false
	var jobs: [UUID: Task<[NetworkEndpoint], Error>] = [:]
	var activeHashes: Set<Data> = []
	var queries = 0
	var transactions: Set<Data> = []
	var tokens = DHTTokens()
	var peerCache: [Data: [NetworkEndpoint: TimeInterval]] = [:]
	var results: [Data: (TimeInterval, [NetworkEndpoint])] = [:]
	var announced: [Data: TimeInterval] = [:]
	var rateEpoch: Int64 = -1, rateCount = 0
	var rates: [IPAddress: Int] = [:]
	var votes: [Data: IPAddress] = [:]
	var fixedAddress: Bool
	public internal(set) var lastFailure: String?
	public var nodeID: Data { table.id }
	public var contactCount: Int { table.closest(table.id, now: clock.now(), count: 1280).count }
	public init(dispatcher: UDPDispatcher, externalAddress: IPAddress? = nil, bootstrap: [NetworkEndpoint]? = nil,
		resolver: any AddressResolving = SystemAddressResolver(), clock: any TransportClock = ContinuousTransportClock()) throws {
		guard bootstrap?.count ?? 0 <= 16, externalAddress == nil || externalAddress!.isIPv6 == dispatcher.localEndpoint.address.isIPv6 else { throw NetworkFailure.invalid("DHT configuration") }
		self.dispatcher = dispatcher; self.bootstrap = bootstrap; self.resolver = resolver; self.clock = clock
		let local = dispatcher.localEndpoint.address
		table = DHTRoutingTable(id: try DHTIdentity.make(address: externalAddress ?? (local.isUnspecified ? nil : local)))
		fixedAddress = externalAddress != nil || !local.isUnspecified
	}
	public func setTorrents(_ metadata: [TorrentMetadata]) async throws {
		guard !closed else { throw NetworkFailure.closed }; guard !updating else { throw NetworkFailure.busy }
		updating = true; defer { updating = false }
		guard metadata.count <= 2048 else { throw NetworkFailure.limit("DHT registered swarms") }
		var allowed: Set<Data> = [], blocked: Set<Data> = []
		for item in metadata {
			for hash in [item.hashes.v1, item.hashes.v2.map { Data($0.prefix(20)) }].compactMap({ $0 }) {
				if item.inspection.private { blocked.insert(hash) } else { allowed.insert(hash) }
			}
		}
		permitted = allowed.subtracting(blocked); forbidden = blocked
		results = results.filter { permitted.contains($0.key) }; announced = announced.filter { permitted.contains($0.key) }
		for hash in blocked { peerCache[hash] = nil; results[hash] = nil; announced[hash] = nil }
		// Any registration change cancels lookups before another packet can be sent.
		for job in jobs.values { job.cancel() }
		if permitted.isEmpty { pump?.cancel(); pump = nil; return }
		if pump == nil {
			let stream = try await dispatcher.subscribe(.dht)
			guard !closed else { throw NetworkFailure.closed }
			pump = Task { [weak self] in for await packet in stream { if Task.isCancelled { break }; await self?.receiveQuery(packet) } }
		}
	}
	/// Queries only identities from registered public metadata. An optional port announces this peer.
	public func getPeers(for metadata: TorrentMetadata, announcePort: UInt16? = nil) async throws -> [NetworkEndpoint] {
		try Task.checkCancellation(); guard !closed else { throw NetworkFailure.closed }
		if metadata.inspection.private { return [] }
		let hashes = Array(Set([metadata.hashes.v1, metadata.hashes.v2.map { Data($0.prefix(20)) }].compactMap { $0 }))
		guard hashes.allSatisfy({ permitted.contains($0) }), announcePort != 0 else { throw NetworkFailure.invalid("unregistered DHT swarm or announce port") }
		guard jobs.count < 4 else { throw NetworkFailure.limit("DHT searches") }
		guard activeHashes.isDisjoint(with: hashes) else { throw NetworkFailure.busy }
		activeHashes.formUnion(hashes)
		let id = UUID(), job = Task { try await self.search(hashes: hashes, announcePort: announcePort) }; jobs[id] = job
		defer { jobs[id] = nil; activeHashes.subtract(hashes) }
		return try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
	}
	/// Challenges a node learned from a connected peer's PORT message before routing through it.
	public func addNode(_ endpoint: NetworkEndpoint, for metadata: TorrentMetadata) async throws {
		guard !metadata.inspection.private, let hash = metadata.hashes.v1 ?? metadata.hashes.v2.map({ Data($0.prefix(20)) }) else { return }
		_ = try await query("ping", arguments: [:], peer: endpoint, deadline: clock.now() + 3, hash: hash)
	}
	func authorised(_ hash: Data) throws {
		try Task.checkCancellation()
		guard !closed else { throw NetworkFailure.closed }
		guard permitted.contains(hash), !forbidden.contains(hash) else { throw NetworkFailure.invalid("private or unregistered DHT swarm") }
	}
	func query(_ name: String, arguments: [String: BencodeValue], peer: NetworkEndpoint, deadline: TimeInterval, hash: Data) async throws -> BencodeValue {
		try authorised(hash)
		guard queries < 16, peer.port > 0, peer.address.isIPv6 == dispatcher.localEndpoint.address.isIPv6, !peer.address.isUnspecified, !peer.address.isMulticast else { throw NetworkFailure.invalid("DHT query endpoint or admission") }
		let remaining = deadline - clock.now(); guard remaining > 0 else { throw NetworkFailure.timedOut }
		var transaction = Data()
		repeat { transaction = Data((0..<4).map { _ in UInt8.random(in: 0...255) }) } while transactions.contains(transaction)
		transactions.insert(transaction); queries += 1
		defer { queries -= 1; transactions.remove(transaction) }
		var args = arguments; args["id"] = .bytes(table.id)
		var fields: [String: BencodeValue] = ["t": .bytes(transaction), "y": .bytes(Data("q".utf8)), "q": .bytes(Data(name.utf8)), "a": DHTWire.dictionary(args)]
		if !fixedAddress { fields["ro"] = .integer(1) }
		let bytes = try DHTWire.encode(fields)
		do {
			let packet = try await dispatcher.exchange(bytes, with: peer, reply: .dht(transaction), timeout: min(3, remaining))
			try authorised(hash)
			let root = try DHTWire.decode(packet.payload)
			observe(root["ip"]?.bytes, source: peer)
			guard root["y"]?.text == "r", let response = root["r"], response.dictionary != nil, let id = response["id"]?.bytes, DHTIdentity.valid(id, address: peer.address) else { throw NetworkFailure.invalid("DHT error or invalid responder identity") }
			table.insert(DHTContact(id: id, endpoint: peer), now: clock.now()); return response
		} catch { table.failed(peer); throw error }
	}
	func observe(_ compact: Data?, source: NetworkEndpoint) {
		guard !fixedAddress, !source.address.isLocal, let compact, let endpoint = try? DHTWire.endpoint(compact), !endpoint.address.isLocal,
			endpoint.address.isIPv6 == dispatcher.localEndpoint.address.isIPv6 else { return }
		let prefix = Data(source.address.bytes.prefix(source.address.isIPv6 ? 8 : 3))
		guard votes[prefix] != nil || votes.count < 32 else { return }; votes[prefix] = endpoint.address
		if votes.values.filter({ $0 == endpoint.address }).count >= 3, let id = try? DHTIdentity.make(address: endpoint.address) {
			table = DHTRoutingTable(id: id); fixedAddress = true; votes.removeAll()
		}
	}
	private func search(hashes: [Data], announcePort: UInt16?) async throws -> [NetworkEndpoint] {
		let deadline = clock.now() + 30
		var peers: Set<NetworkEndpoint> = []
		for hash in hashes {
			try authorised(hash)
			if let cached = results[hash], clock.now() - cached.0 < 60, announcePort == nil { peers.formUnion(cached.1); continue }
			let found = try await lookup(hash: hash, announcePort: announcePort, deadline: deadline)
			if results[hash] != nil || results.count < 4096 { results[hash] = (clock.now(), found) }
			peers.formUnion(found)
		}
		return Array(peers.prefix(256))
	}
	private func lookup(hash: Data, announcePort: UInt16?, deadline: TimeInterval) async throws -> [NetworkEndpoint] {
		let family = dispatcher.localEndpoint.address.isIPv6
		var candidates = table.closest(hash, now: clock.now(), count: 32)
		if candidates.isEmpty {
			let endpoints: [NetworkEndpoint]
			if let bootstrap { endpoints = bootstrap } else { endpoints = try await resolver.resolve(host: "dht.libtorrent.org", port: 25401, timeout: min(5, max(0.1, deadline - clock.now()))) }
			try authorised(hash)
			candidates = endpoints.filter { $0.address.isIPv6 == family }.map { DHTContact(id: Data(repeating: 0, count: 20), endpoint: $0) }
		}
		var visited: Set<NetworkEndpoint> = [], peers: Set<NetworkEndpoint> = []
		var responders: [(DHTContact, Data)] = [], successful = 0, failure: Error?
		while !candidates.isEmpty && visited.count < 32 && clock.now() < deadline {
			try authorised(hash)
			let batch = Array(candidates.prefix(min(3, 32 - visited.count))); candidates.removeFirst(batch.count)
			for contact in batch { visited.insert(contact.endpoint) }
			let replies = await withTaskGroup(of: (DHTContact, Result<BencodeValue, Error>).self) { group in
				for contact in batch { group.addTask { do { return (contact, .success(try await self.query("get_peers", arguments: ["info_hash": .bytes(hash), "want": .list([.bytes(Data((family ? "n6" : "n4").utf8))])], peer: contact.endpoint, deadline: deadline, hash: hash))) } catch { return (contact, .failure(error)) } } }
				var replies: [(DHTContact, Result<BencodeValue, Error>)] = []; for await result in group { replies.append(result) }; return replies
			}
			for (contact, result) in replies {
				do {
					let response = try result.get(); successful += 1
					if let values = response["values"] {
						guard let list = values.list, list.count <= 50 else { throw NetworkFailure.limit("DHT peer list") }
						for value in list {
							guard let bytes = value.bytes else { throw NetworkFailure.invalid("DHT peer") }
							let peer = try DHTWire.endpoint(bytes)
							if (contact.endpoint.address.isLocal || !peer.address.isLocal), peers.count < 256 { peers.insert(peer) }
						}
					}
					if let token = response["token"]?.bytes, !token.isEmpty, token.count <= 64, let id = response["id"]?.bytes { responders.append((DHTContact(id: id, endpoint: contact.endpoint), token)) }
					for referral in try DHTWire.contacts(response, source: contact.endpoint) where referral.endpoint.address.isIPv6 == family && !visited.contains(referral.endpoint) && !candidates.contains(where: { $0.endpoint == referral.endpoint }) {
						if candidates.count < 64 { candidates.append(referral) }
					}
				} catch { failure = error }
			}
			candidates.sort { DHTRoutingTable.nearer($0.id, $1.id, to: hash) }
		}
		try authorised(hash)
		if successful == 0, let failure { throw failure }
		if let port = announcePort, clock.now() - (announced[hash] ?? -.infinity) >= 900 {
			var sent = false
			for (contact, token) in responders.sorted(by: { DHTRoutingTable.nearer($0.0.id, $1.0.id, to: hash) }).prefix(8) where clock.now() < deadline {
				do { _ = try await query("announce_peer", arguments: ["info_hash": .bytes(hash), "port": .integer(Int64(port)), "token": .bytes(token)], peer: contact.endpoint, deadline: deadline, hash: hash); sent = true }
				catch { try authorised(hash); lastFailure = String(describing: error) }
			}
			if sent { announced[hash] = clock.now() }
		}
		return Array(peers)
	}
	public func shutdown() async {
		closed = true; permitted.removeAll(); pump?.cancel()
		let active = Array(jobs.values); for job in active { job.cancel() }; for job in active { _ = try? await job.value }
		if let pump { await pump.value }; pump = nil
		peerCache.removeAll(); results.removeAll(); announced.removeAll()
	}
}
