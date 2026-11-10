import Foundation
import ButterTorrentMetadata
import ButterTorrentNetworking
import ButterTorrentStorage

public struct SessionImport: Sendable {
	public let id: String
	public let duplicate: Bool
	public let hashes: [String]
}

public struct SessionTransferSnapshot: Sendable {
	public let id: String
	public let metadata: TorrentMetadata
	public let state: ManagedTransferSnapshot
	public let error: String
	public let trackers: [SessionTrackerSnapshot]
}

public struct SessionEvent: Sendable {
	public let kind: String
	public let id: String
	public let path: String?
}

public struct TorrentSessionSnapshot: Sendable {
	public let transfers: [SessionTransferSnapshot]
	public let events: [SessionEvent]
	public let network: SessionNetworkSnapshot
}

private final class SessionEntry {
	let id: String
	let prepared: PreparedTransferState
	var metadata: TorrentMetadata
	var owner: ManagedTransfer
	var last: ManagedTransferSnapshot
	var error = ""
	var closed = false
	var running = false
	var receipts: [URL] = []
	var downloadLimit: Int
	var uploadLimit: Int
	var tracker: SessionTracker?
	var trackerMessages: [URL: String] = [:]
	var trackerFailure = ""
	let trackerBaseline: TrackerCounters
	init(id: String, metadata: TorrentMetadata, prepared: PreparedTransferState, owner: ManagedTransfer, last: ManagedTransferSnapshot, configuration: TCPTransferConfiguration) {
		self.id = id; self.metadata = metadata; self.prepared = prepared; self.owner = owner; self.last = last
		downloadLimit = configuration.downloadLimit; uploadLimit = configuration.uploadLimit
		trackerBaseline = TrackerCounters(uploaded: last.storage.uploaded, downloaded: last.storage.downloaded, left: 0)
	}
}

/// TorrentSession owns native imports and serialises app commands without GUI dependencies.
public actor TorrentSession {
	private let repository: TransferRepository
	private let resources: TransferResources
	private var configuration: TCPTransferConfiguration
	private let budget: TCPPeerBudget
	public nonisolated let peerID: Data
	private let clock: any TransportClock
	private let loopbackOnly: Bool
	private let httpTracker: any TrackerAnnouncing
	private let webSeedTransport: (any HTTPTransport)?
	private let dhtBootstrap: [NetworkEndpoint]?
	private var trackerClient: TrackerClient?
	private var network: SessionPeerNetwork?
	private var peerSettings: SessionPeerSettings?
	private var networkError = ""
	private var networkChanging = false
	private var closed = false
	private let commands = TransferPermits(1)
	private var entries: [SessionEntry] = []
	private var events: [SessionEvent] = []
	private var peerHints: PeerCandidateQueue<SessionPeerHint>?
	public init(storage: URL, configuration: TCPTransferConfiguration = .init(), resources: TransferResources = .shared, maximumPeers: Int = 200,
		loopbackOnly: Bool = false, clock: any TransportClock = ContinuousTransportClock(), httpTracker: any TrackerAnnouncing = HTTPTrackerClient(), webSeedTransport: (any HTTPTransport)? = nil, dhtBootstrap: [NetworkEndpoint]? = nil) {
		repository = TransferRepository(root: storage); self.configuration = configuration; self.resources = resources; budget = TCPPeerBudget(limit: maximumPeers)
		self.loopbackOnly = loopbackOnly; self.clock = clock
		self.httpTracker = httpTracker
		self.webSeedTransport = webSeedTransport
		self.dhtBootstrap = dhtBootstrap
		peerID = Data("-BT0001-".utf8) + Data((0..<12).map { _ in UInt8.random(in: 0...255) })
	}
	public var currentPeerSettings: SessionPeerSettings {
		if let peerSettings { return peerSettings }
		var settings = SessionPeerSettings(); settings.maximumPeers = budget.limit; settings.torrentPeers = configuration.maximumPeers
		settings.pex = configuration.enablePEX; settings.allowSameIP = configuration.allowSameIP; return settings
	}
	public func add(id: String, source: URL, destination: URL, restore: Bool = false, selected: [Bool]? = nil, tracker: String? = nil) async throws -> SessionImport {
		try TransferRepository.validateID(id)
		let selected = selected?.isEmpty == true ? nil : selected
		guard destination.isFileURL, destination.path.hasPrefix("/"), !destination.path.utf8.contains(0) else { throw StorageFailure.invalid("absolute destination") }
		return try await serial {
			guard !self.entries.contains(where: { $0.id == id }) else { throw StorageFailure.collision("transfer identifier") }
			guard self.entries.count < 10_000 else { throw PeerFailure.limit("session transfers") }
			var metadata = try await self.repository.metadata(id: id, source: source, restore: restore)
			if let selected, selected.count != metadata.inspection.files.count { throw StorageFailure.invalid("selection count") }
			if let existing = self.entries.first(where: { Self.overlaps($0.metadata.hashes, metadata.hashes) }) {
				guard existing.metadata.originalInfo == metadata.originalInfo else { throw MetadataError.invalid("conflicting verified swarm identity") }
				return SessionImport(id: existing.id, duplicate: true, hashes: [])
			}
			if let tracker, !metadata.inspection.private { metadata = try self.appending(tracker, to: metadata) }
			let prepared = try await self.repository.prepare(id: id, restore: restore)
			var owner: ManagedTransfer?
			do {
				let managed = try await ManagedTransfer.open(metadata: metadata, destination: destination, stateDirectory: prepared.directory,
					selected: selected, configuration: self.configuration, resources: self.resources, budget: self.budget, preparedState: prepared, peerID: self.peerID, clock: self.clock, webSeedTransport: self.webSeedTransport); owner = managed
				await self.observeDiscovery(id: id, owner: managed)
				var snapshot = try await managed.snapshot()
				if !snapshot.storage.needsRecovery { try await managed.recheck(); snapshot = try await managed.snapshot() }
				try Task.checkCancellation()
				try await self.repository.publish(id: id, metadata: metadata, state: prepared)
				let entry = SessionEntry(id: id, metadata: metadata, prepared: prepared, owner: managed, last: snapshot, configuration: self.configuration)
				if snapshot.storage.needsRecovery { entry.error = StorageFailure.recoveryRequired("a filesystem operation is pending").localizedDescription }
				self.entries.append(entry)
				try await self.refreshRouting()
				return SessionImport(id: id, duplicate: false, hashes: metadata.hashes.hex)
			} catch {
				// Cleanup runs independently of caller cancellation and never discards a published checkpoint.
				let repository = self.repository, cleanup = Task { if let owner { try await owner.close() }; try await repository.abandon(prepared) }
				do { try await cleanup.value }
				catch let cleanupError { throw StorageFailure.recoveryRequired("import failed (\(error.localizedDescription)); native state cleanup also failed (\(cleanupError.localizedDescription))") }
				throw error
			}
		}
	}
	public func run(id: String, running: Bool, downloadLimit: Int? = nil, uploadLimit: Int? = nil) async throws {
		try await serial {
			let entry = try self.entry(id)
			if downloadLimit != nil || uploadLimit != nil {
				let down = downloadLimit ?? entry.downloadLimit, up = uploadLimit ?? entry.uploadLimit
				try await entry.owner.setLimits(download: down, upload: up); entry.downloadLimit = down; entry.uploadLimit = up
			}
			if running && entry.error.isEmpty {
				try await entry.owner.start(); entry.running = true
				do { try await self.refreshRouting() } catch { entry.running = false; try? await entry.owner.pause(); throw error }
				await self.startTracker(entry)
			} else { try await self.pauseEntry(entry) }
		}
	}
	public func pause(id: String) async throws {
		try await serial { try await self.pauseEntry(self.entry(id)) }
	}
	public func save(id: String) async throws { try await serial { try await self.entry(id).owner.save() } }
	public func recheck(id: String) async throws {
		try await serial { let entry = try self.entry(id); try await entry.owner.recheck(); entry.error = "" }
	}
	public func retry(id: String) async throws {
		try await serial {
			let entry = try self.entry(id)
			if !entry.closed { try await self.pauseEntry(entry) }
			if entry.closed {
				entry.owner = try await ManagedTransfer.open(metadata: entry.metadata, destination: entry.last.storage.destination,
					stateDirectory: entry.prepared.directory, configuration: self.configuration, resources: self.resources, budget: self.budget, preparedState: entry.prepared, peerID: self.peerID, clock: self.clock, webSeedTransport: self.webSeedTransport)
				await self.observeDiscovery(id: id, owner: entry.owner)
				entry.closed = false
			}
			try await entry.owner.pause()
			if try await entry.owner.snapshot().storage.needsRecovery { try await entry.owner.changeStorage(.recover(acceptMatchingCopies: false)) }
			entry.error = ""
		}
	}
	public func changeStorage(id: String, change: TransferStorageChange) async throws {
		try await serial {
			let entry = try self.entry(id)
			do {
				try await entry.owner.changeStorage(change)
				entry.last = try await entry.owner.snapshot(); entry.error = ""
				if case .move = change { self.emit(SessionEvent(kind: "moved", id: id, path: entry.last.storage.destination.path)) }
			} catch { entry.error = error.localizedDescription; throw error }
		}
	}
	public func export(id: String) async throws -> Data {
		try await serial {
			let entry = try self.entry(id)
			let data = try await entry.owner.exportMetadata(), metadata = try TorrentMetadata(data)
			return metadata.trackerTiers == entry.metadata.trackerTiers ? data : try metadata.withTrackerTiers(entry.metadata.trackerTiers)
		}
	}
	public func appendTracker(id: String, tracker: String) async throws {
		try await serial {
			let entry = try self.entry(id)
			guard !entry.metadata.inspection.private else { throw MetadataError.invalid("private trackers cannot be appended") }
			let candidate = try self.appending(tracker, to: entry.metadata)
			try await self.repository.publish(id: id, metadata: candidate, state: entry.prepared); entry.metadata = candidate
			if let service = entry.tracker, let url = URL(string: tracker) { try await service.append(url) }
			else if entry.running { await self.startTracker(entry) }
		}
	}
	public func magnet(id: String) async throws -> String {
		try await serial { let entry = try self.entry(id); return Magnet(hashes: entry.metadata.hashes, name: entry.metadata.inspection.name, trackers: entry.metadata.trackerTiers.flatMap({ $0 })).uri }
	}
	@discardableResult public func connect(id: String, to endpoint: NetworkEndpoint, utp: UTPTransport? = nil) async throws -> UUID {
		guard !closed, !networkChanging else { throw NetworkFailure.busy }
		guard configuration.addressFilter.allows(endpoint.address) else { throw PeerFailure.invalid("blocked peer") }
		let entry = try entry(id); guard entry.running, !entry.closed else { throw PeerFailure.closed }; let owner = entry.owner
		if let settings = peerSettings {
			if let utp { guard settings.utp else { throw NetworkFailure.invalid("µTP is disabled") }; return try await owner.connect(to: endpoint, utp: utp) }
			if settings.tcp { return try await owner.connect(to: endpoint) }
			guard settings.utp, let network else { throw NetworkFailure.closed }
			return try await owner.connect(to: endpoint, utp: network.transport(for: endpoint))
		}
		return try await owner.connect(to: endpoint, utp: utp)
	}
	public func remove(id: String, trash: Bool = false, retainState: Bool = false, trashDirectory: URL? = nil) async throws -> [URL] {
		try await serial {
			let entry = try self.entry(id)
			do {
				entry.running = false; try await self.refreshRouting()
				if !entry.closed {
					try await self.pauseEntry(entry)
					if trash { entry.receipts = try await entry.owner.trash(directory: trashDirectory) }
					entry.last = try await entry.owner.snapshot(); try await entry.owner.close(); entry.closed = true
				}
				if !retainState { try await self.repository.discard(id: id) }
				self.entries.removeAll { $0.id == id }; try await self.refreshRouting(); return entry.receipts
			} catch { entry.error = error.localizedDescription; throw error }
		}
	}
	public func forget(id: String) async throws {
		try TransferRepository.validateID(id)
		try await serial { guard !self.entries.contains(where: { $0.id == id }) else { throw StorageFailure.invalid("cannot forget a live transfer") }; try await self.repository.discard(id: id) }
	}
	public func shutdown() async throws {
		try await serial {
			var failure: Error?
			for entry in self.entries { entry.running = false }; try await self.refreshRouting()
			await self.drainPeerHints()
			for entry in self.entries { await entry.tracker?.halt() }
			for entry in self.entries where !entry.closed {
				do { try await entry.owner.pause() } catch { entry.error = error.localizedDescription; failure = failure ?? error }
			}
			await self.stopTrackers(self.entries)
			if let failure { throw failure }
		}
	}
	public func snapshot() async throws -> TorrentSessionSnapshot {
		try await serial {
			var snapshots: [SessionTransferSnapshot] = []
			for entry in self.entries {
				if !entry.closed { entry.last = try await entry.owner.snapshot() }
				let messages = await entry.tracker?.messages() ?? entry.trackerMessages
				let fallback = await entry.tracker?.failure() ?? entry.trackerFailure
				let trackers = entry.metadata.trackerTiers.flatMap({ $0 }).map { url in SessionTrackerSnapshot(url: url, message: URL(string: url).flatMap { messages[$0] } ?? fallback) }
				snapshots.append(SessionTransferSnapshot(id: entry.id, metadata: entry.metadata, state: entry.last, error: entry.error, trackers: trackers))
			}
			let wire = await self.network?.snapshot()
			let status = SessionNetworkSnapshot(port: wire?.port ?? 0, udp: wire?.udp ?? false, error: wire?.error.isEmpty == false ? wire!.error : self.networkError,
				pendingHandshakes: wire?.pendingHandshakes ?? 0, peers: self.budget.count, discovery: wire?.discovery ?? .disabled)
			let result = TorrentSessionSnapshot(transfers: snapshots, events: self.events, network: status); self.events.removeAll(); return result
		}
	}
	@discardableResult public func configurePeers(_ settings: SessionPeerSettings) async throws -> UInt16 {
		try settings.validate()
		return try await serial {
			if settings.port != 0, settings == self.peerSettings, let network = self.network {
				let state = await network.snapshot()
				if state.port == settings.port && state.error.isEmpty && state.discovery.enabled == settings.dht { return state.port }
			}
			self.networkChanging = true; defer { self.networkChanging = false }
			let running = try await self.pauseForSettings()
			await self.network?.shutdown(); self.network = nil; self.trackerClient = nil
			try self.budget.setLimit(settings.maximumPeers)
			self.configuration.maximumPeers = min(settings.maximumPeers, settings.torrentPeers)
			self.configuration.enablePEX = settings.pex; self.configuration.allowSameIP = settings.allowSameIP
			self.peerSettings = settings; self.networkError = ""
			var bindError: Error?
			do {
				self.network = try await SessionPeerNetwork.open(settings: settings, budget: self.budget, encryption: self.configuration.encryption,
					filter: self.configuration.addressFilter, loopbackOnly: self.loopbackOnly, clock: self.clock, bootstrap: self.dhtBootstrap) { [weak self] target, endpoint in
						await self?.connectDiscovered(target, to: endpoint)
					}
			} catch { self.networkError = error.localizedDescription; bindError = error }
			let port = await self.network?.snapshot().port ?? 0; self.configuration.listenPort = port
			self.configuration.dhtPort = settings.dht ? port : 0
			for entry in self.entries where !entry.closed {
				try await entry.owner.configurePeers(maximum: self.configuration.maximumPeers, pex: settings.pex, port: port, allowSameIP: settings.allowSameIP, addressFilter: self.configuration.addressFilter, dhtPort: self.configuration.dhtPort)
			}
			for entry in running { try await entry.owner.start() }
			try await self.refreshRouting()
			self.networkChanging = false
			try await self.refreshRouting()
			for entry in running { await self.startTracker(entry) }
			if let bindError { throw bindError }; return port
		}
	}
	public func setBlocklist(_ ranges: [PeerAddressRange]) async throws {
		let filter = try PeerAddressFilter(ranges: ranges)
		try await serial {
			self.networkChanging = true; defer { self.networkChanging = false }
			let running = try await self.pauseForSettings()
			self.configuration.addressFilter = filter; await self.network?.setFilter(filter)
			for entry in self.entries where !entry.closed {
				try await entry.owner.configurePeers(maximum: self.configuration.maximumPeers, pex: self.configuration.enablePEX,
					port: self.configuration.listenPort, allowSameIP: self.configuration.allowSameIP, addressFilter: filter, dhtPort: self.configuration.dhtPort)
			}
			for entry in running { try await entry.owner.start() }; try await self.refreshRouting()
			self.networkChanging = false
			try await self.refreshRouting()
			for entry in running { await self.startTracker(entry) }
		}
	}
	public func close() async throws {
		try await commands.acquire()
		do {
			if !closed {
				networkChanging = true; defer { networkChanging = false }
				for entry in entries { entry.running = false; await entry.tracker?.halt() }
				var failure: Error?
				try? await refreshRouting()
				await drainPeerHints()
				for entry in entries where !entry.closed {
					do { try await entry.owner.pause() } catch { entry.error = error.localizedDescription; failure = failure ?? error }
				}
				await stopTrackers(entries); await network?.shutdown(); network = nil; trackerClient = nil
				for entry in entries where !entry.closed {
					do { try await entry.owner.close(); entry.closed = true; entry.running = false }
					catch { entry.error = error.localizedDescription; failure = failure ?? error }
				}
				if let failure { throw failure }; closed = true
			}
			await commands.release()
		} catch { await commands.release(); throw error }
	}
	private func refreshRouting() async throws {
		guard let network else { return }
		let targets = entries.filter { $0.running && !$0.closed && $0.error.isEmpty }.map {
			SessionPeerTarget(id: $0.id, hashes: [$0.metadata.hashes.v1, $0.metadata.hashes.v2.map { Data($0.prefix(20)) }].compactMap({ $0 }), owner: $0.owner)
		}
		do {
			try await network.setTargets(targets)
			let publicEntries = networkChanging ? [] : entries.filter { $0.running && !$0.closed && $0.error.isEmpty && !$0.metadata.inspection.private }
			let discovery = publicEntries.map { SessionDHTTarget(id: $0.id, metadata: $0.metadata, owner: $0.owner) }
			await network.updateDiscovery(discovery, metadata: publicEntries.map(\.metadata) + entries.filter { $0.metadata.inspection.private }.map(\.metadata))
		}
		catch NetworkFailure.closed { let state = await network.snapshot(); networkError = state.error.isEmpty ? NetworkFailure.closed.localizedDescription : state.error }
	}
	private func connectDiscovered(_ target: SessionDHTTarget, to endpoint: NetworkEndpoint) async {
		guard !closed, !networkChanging, let entry = entries.first(where: { $0.id == target.id }), entry.owner === target.owner,
			entry.running, !entry.closed, entry.error.isEmpty, !entry.metadata.inspection.private else { return }
		_ = try? await connect(id: entry.id, to: endpoint)
	}
	private func observeDiscovery(id: String, owner: ManagedTransfer) async {
		await owner.setDiscoveryHandler { [weak self, weak owner] notice in
			guard let self, let owner else { return }; await self.receiveDiscovery(id: id, owner: owner, notice: notice)
		}
	}
	private func receiveDiscovery(id: String, owner: ManagedTransfer, notice: ManagedDiscoveryNotice) async {
		guard await owner.acceptsDiscovery(notice.revision), !closed, !networkChanging,
			let entry = entries.first(where: { $0.id == id }), entry.owner === owner,
			entry.running, entry.error.isEmpty, !entry.metadata.inspection.private else { return }
		switch notice.hint {
		case .peer(let peer):
			guard configuration.enablePEX else { return }
			if peerHints == nil { peerHints = PeerCandidateQueue { [weak self] hint in await self?.connectHint(hint) } }
			await peerHints?.enqueue([SessionPeerHint(id: id, owner: owner, revision: notice.revision, endpoint: peer.endpoint, flags: peer.flags)])
		case .node(let endpoint):
			guard peerSettings?.dht == true, configuration.addressFilter.allows(endpoint.address) else { return }
			try? await network?.learnNode(endpoint, for: SessionDHTTarget(id: id, metadata: entry.metadata, owner: owner))
		}
	}
	private func connectHint(_ hint: SessionPeerHint) async {
		guard !closed, !networkChanging, configuration.enablePEX, configuration.addressFilter.allows(hint.endpoint.address),
			let entry = entries.first(where: { $0.id == hint.id }), entry.owner === hint.owner, entry.running, !entry.closed,
			entry.error.isEmpty, !entry.metadata.inspection.private else { return }
		do {
			var utp: UTPTransport?
			if peerSettings?.utp == true && (hint.flags & 4 != 0 || peerSettings?.tcp == false) { utp = try await network?.transport(for: hint.endpoint) }
			else if peerSettings?.tcp == false { return }
			_ = try await hint.owner.connectDiscovered(to: hint.endpoint, revision: hint.revision, utp: utp)
		} catch { }
	}
	private func drainPeerHints() async { let previous = peerHints; peerHints = nil; await previous?.stop() }
	private func pauseForSettings() async throws -> [SessionEntry] {
		await drainPeerHints()
		let running = entries.filter { $0.running && !$0.closed && $0.error.isEmpty }
		if let network { do { await network.suspendDiscovery(); try await network.setTargets([]) } catch NetworkFailure.closed { } }
		for entry in entries { await entry.tracker?.halt() }
		var failure: Error?
		for entry in entries where !entry.closed {
			do { try await entry.owner.pause() } catch { entry.error = error.localizedDescription; failure = failure ?? error }
		}
		await stopTrackers(entries)
		if let failure {
			for entry in running where entry.error.isEmpty { try? await entry.owner.start() }; try? await refreshRouting()
			networkChanging = false
			try? await refreshRouting()
			for entry in running where entry.error.isEmpty { await startTracker(entry) }
			throw failure
		}
		return running
	}
	private func pauseEntry(_ entry: SessionEntry) async throws {
		entry.running = false; await entry.tracker?.halt(); try await refreshRouting()
		var failure: Error?
		do { try await entry.owner.pause() } catch { failure = error }
		await stopTrackers([entry]); if let failure { throw failure }
	}
	private func stopTrackers(_ entries: [SessionEntry]) async {
		let services = entries.compactMap(\.tracker)
		await withTaskGroup(of: Void.self) { group in
			for service in services { group.addTask { await service.stop() } }; await group.waitForAll()
		}
		for entry in entries {
			if let service = entry.tracker { entry.trackerMessages = await service.messages(); entry.trackerFailure = await service.failure(); entry.tracker = nil }
		}
	}
	private func startTracker(_ entry: SessionEntry) async {
		guard entry.tracker == nil, entry.running, !entry.closed, !entry.metadata.trackerTiers.isEmpty else { return }
		do {
			if network == nil && peerSettings == nil {
				let settings = currentPeerSettings
				network = try await SessionPeerNetwork.open(settings: settings, budget: budget, encryption: configuration.encryption,
					filter: configuration.addressFilter, loopbackOnly: loopbackOnly, clock: clock, bootstrap: dhtBootstrap) { [weak self] target, endpoint in
						await self?.connectDiscovered(target, to: endpoint)
					}
				configuration.listenPort = await network!.snapshot().port; peerSettings = settings
				for existing in entries where !existing.closed {
					try await existing.owner.configurePeers(maximum: configuration.maximumPeers, pex: configuration.enablePEX, port: configuration.listenPort,
						allowSameIP: configuration.allowSameIP, addressFilter: configuration.addressFilter, dhtPort: configuration.dhtPort)
				}
				try await refreshRouting()
			}
			guard let network else { throw NetworkFailure.closed }
			if trackerClient == nil { trackerClient = try await network.trackers(http: httpTracker) }
			let initial = try await entry.owner.snapshot(), port = await network.snapshot().port, id = entry.id
			let service = try SessionTracker(metadata: entry.metadata, owner: entry.owner, peerID: peerID, port: port, preferV2: configuration.preferV2,
				initial: initial, baseline: entry.trackerBaseline, client: trackerClient!, clock: clock) { [weak self] peer in _ = try? await self?.connect(id: id, to: NetworkEndpoint(peer.address, port: peer.port)) }
			entry.tracker = service; entry.trackerFailure = ""; entry.trackerMessages = [:]; await service.start()
		} catch { entry.trackerFailure = error.localizedDescription }
	}
	private func entry(_ id: String) throws -> SessionEntry {
		guard let entry = entries.first(where: { $0.id == id }) else { throw StorageFailure.invalid("transfer no longer exists") }; return entry
	}
	private func appending(_ tracker: String, to metadata: TorrentMetadata) throws -> TorrentMetadata {
		guard let url = URL(string: tracker), ["http", "https", "udp"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil else { throw MetadataError.invalid("tracker URL") }
		let hash = metadata.hashes.v1 ?? Data(metadata.hashes.v2!.prefix(20))
		try TrackerAnnouncer.validate(tracker: url, request: TrackerRequest(infoHash: hash, peerID: peerID, port: max(1, configuration.listenPort), counters: TrackerCounters(left: 0)))
		if metadata.trackerTiers.flatMap({ $0 }).contains(tracker) { return metadata }
		return try TorrentMetadata(metadata.withTrackerTiers(metadata.trackerTiers + [[tracker]]))
	}
	private func emit(_ event: SessionEvent) { if events.count >= 1024 { events.removeFirst() }; events.append(event) }
	private static func overlaps(_ a: InfoHashes, _ b: InfoHashes) -> Bool { (a.v1 != nil && a.v1 == b.v1) || (a.v2 != nil && a.v2 == b.v2) }
	private func serial<T: Sendable>(_ body: () async throws -> T) async throws -> T {
		try await commands.acquire()
		do { try Task.checkCancellation(); guard !closed else { throw PeerFailure.closed }; let result = try await body(); await commands.release(); return result }
		catch { await commands.release(); throw error }
	}
	deinit { if let network { Task { await network.shutdown() } } }
}
