import Foundation
import OSLog
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
	public let activity: SessionTransferActivity?
}

public enum SessionTransferActivity: Sendable, Equatable { case checking, moving, renaming }

public enum SessionExportFailure: Error, LocalizedError, Sendable {
	case stopped, timedOut
	public var errorDescription: String? {
		switch self {
		case .stopped: "The transfer stopped during export."
		case .timedOut: "Export timed out waiting for authenticated piece layers. Retry after the transfer has obtained them."
		}
	}
}

public struct SessionEvent: Sendable {
	public let kind: String
	public let id: String
	public let path: String?
	public let existingID: String?
	init(kind: String, id: String, path: String? = nil, existingID: String? = nil) { self.kind = kind; self.id = id; self.path = path; self.existingID = existingID }
}

public struct TorrentSessionSnapshot: Sendable {
	public let transfers: [SessionTransferSnapshot]
	public let magnets: [SessionMagnetSnapshot]
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
	var activity: SessionTransferActivity?
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
		trackerBaseline = TrackerCounters(uploaded: last.storage.uploaded, downloaded: last.storage.downloaded, left: 0, corrupt: last.storage.corruptBytes, redundant: last.storage.redundantBytes)
	}
}

/// TorrentSession owns native imports and serialises app commands without GUI dependencies.
public actor TorrentSession {
	private static let log = Logger(subsystem: "ButterTorrent", category: "TorrentSession")
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
	private let localDiscoveryFactory: LocalDiscoveryFactory?
	private let routerMappingRoutes: SessionRouterMapping.Routes?
	private let storageEvent: @Sendable (String, StorageEvent) -> Void
	private var trackerClient: TrackerClient?
	private var network: SessionPeerNetwork?
	private var peerSettings: SessionPeerSettings?
	private var networkError = ""
	private var networkChanging = false
	private var closed = false
	private let commands = SessionCommandGate()
	private let publication = TransferPermits(1)
	private let routing = TransferPermits(1)
	private let trackerSetup = TransferPermits(1)
	private let metadataPermits = TransferPermits(4)
	private var entries: [SessionEntry] = []
	private var pendingMagnets: [SessionPendingMagnet] = []
	private var events: [SessionEvent] = []
	private var peerHints: PeerCandidateQueue<SessionPeerHint>?
	private var exports: [UUID: (id: String, signal: AsyncStream<Void>.Continuation)] = [:]
	public init(storage: URL, configuration: TCPTransferConfiguration = .init(), resources: TransferResources = .shared, maximumPeers: Int = 200,
		loopbackOnly: Bool = false, clock: any TransportClock = ContinuousTransportClock(), httpTracker: any TrackerAnnouncing = HTTPTrackerClient(), webSeedTransport: (any HTTPTransport)? = nil, dhtBootstrap: [NetworkEndpoint]? = nil, localDiscoveryFactory: LocalDiscoveryFactory? = nil,
		routerMappingRoutes: (@Sendable () async throws -> [RouterMappingRoute])? = nil, storageEvent: @escaping @Sendable (String, StorageEvent) -> Void = { _, _ in }) {
		repository = TransferRepository(root: storage); self.configuration = configuration; self.resources = resources; budget = TCPPeerBudget(limit: maximumPeers)
		self.loopbackOnly = loopbackOnly; self.clock = clock
		self.httpTracker = httpTracker
		self.webSeedTransport = webSeedTransport
		self.dhtBootstrap = dhtBootstrap
		self.localDiscoveryFactory = localDiscoveryFactory
		self.routerMappingRoutes = routerMappingRoutes
		self.storageEvent = storageEvent
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
		return try await serial(id: id, publishing: true) {
			try self.checkAdmission(id)
			let metadata = try await self.repository.metadata(id: id, source: source, restore: restore)
			return try await self.addMetadata(id: id, metadata: metadata, destination: destination, restore: restore, selected: selected, tracker: tracker)
		}
	}
	private func checkAdmission(_ id: String) throws {
		guard !entries.contains(where: { $0.id == id }), pending(id) == nil else { throw StorageFailure.collision("transfer identifier") }
		guard entries.count + pendingMagnets.count < 10_000 else { throw PeerFailure.limit("session transfers") }
	}
	public func add(id: String, magnet: Magnet, destination: URL, restore: Bool = false, tracker: String? = nil) async throws -> SessionImport {
		try TransferRepository.validateID(id)
		guard destination.isFileURL, destination.path.hasPrefix("/"), !destination.path.utf8.contains(0) else { throw StorageFailure.invalid("absolute destination") }
		return try await serial(id: id, publishing: true) {
			try self.checkAdmission(id)
			if let stored = try await self.repository.retainedMetadata(id: id) {
				guard restore else { throw StorageFailure.collision("retained native state; restore or forget it first") }
				guard Self.matches(magnet.hashes, stored.hashes) else { throw MetadataError.invalid("retained magnet identity") }
				return try await self.addMetadata(id: id, metadata: stored, destination: destination, restore: true, selected: nil, tracker: tracker)
			}
			if let existing = self.entries.first(where: { Self.overlaps($0.metadata.hashes, magnet.hashes) }) {
				guard Self.matches(magnet.hashes, existing.metadata.hashes) else { throw MetadataError.invalid("conflicting magnet identity") }
				return SessionImport(id: existing.id, duplicate: true, hashes: [])
			}
			if let existing = self.pendingMagnets.first(where: { Self.overlaps($0.magnet.hashes, magnet.hashes) }) {
				let a = existing.magnet.hashes, b = magnet.hashes
				guard a.v1 == nil || b.v1 == nil || a.v1 == b.v1, a.v2 == nil || b.v2 == nil || a.v2 == b.v2 else { throw MetadataError.invalid("conflicting magnet identity") }
				return SessionImport(id: existing.id, duplicate: true, hashes: [])
			}
			if let tracker, !magnet.trackers.contains(tracker) { try self.validateTracker(tracker, hashes: magnet.hashes) }
			let state = try await self.repository.claimMagnet(id: id, magnet: magnet, destination: destination, restore: restore, tracker: tracker)
			self.pendingMagnets.append(SessionPendingMagnet(id: id, state: state, configuration: self.configuration))
			return SessionImport(id: id, duplicate: false, hashes: magnet.hashes.hex)
		}
	}
	private func addMetadata(id: String, metadata: TorrentMetadata, destination: URL, restore: Bool, selected: [Bool]?, tracker: String?) async throws -> SessionImport {
		var metadata = metadata
		if let selected, selected.count != metadata.inspection.files.count { throw StorageFailure.invalid("selection count") }
		if let existing = entries.first(where: { Self.overlaps($0.metadata.hashes, metadata.hashes) }) {
			guard existing.metadata.originalInfo == metadata.originalInfo else { throw MetadataError.invalid("conflicting verified swarm identity") }
			return SessionImport(id: existing.id, duplicate: true, hashes: [])
		}
		if let existing = pendingMagnets.first(where: { Self.overlaps($0.magnet.hashes, metadata.hashes) }) {
			guard Self.matches(existing.magnet.hashes, metadata.hashes) else { throw MetadataError.invalid("conflicting magnet identity") }
			return SessionImport(id: existing.id, duplicate: true, hashes: [])
		}
		if let tracker, !metadata.inspection.private { metadata = try appending(tracker, to: metadata) }
		let entry = try await publishMetadata(id: id, metadata: metadata, destination: destination, restore: restore, selected: selected, configuration: configuration)
		entries.append(entry); try await refreshRouting()
		return SessionImport(id: id, duplicate: false, hashes: metadata.hashes.hex)
	}
	private func publishMetadata(id: String, metadata: TorrentMetadata, destination: URL, restore: Bool, selected: [Bool]? = nil, configuration: TCPTransferConfiguration, pending: PendingMagnetState? = nil) async throws -> SessionEntry {
		let prepared = try await repository.prepare(id: id, restore: restore, pending: pending)
		var owner: ManagedTransfer?
		do {
			let managed = try await ManagedTransfer.open(metadata: metadata, destination: destination, stateDirectory: prepared.directory,
				selected: selected, configuration: configuration, resources: resources, budget: budget, preparedState: prepared, peerID: peerID, clock: clock, webSeedTransport: webSeedTransport, event: { [weak self, storageEvent] event in
					if event == .pieceLayersChanged { Task { await self?.signalExports(id: id) } }
					else { storageEvent(id, event) }
				}); owner = managed
			await observeDiscovery(id: id, owner: managed)
			var snapshot = try await managed.snapshot()
			if !snapshot.storage.needsRecovery { try await managed.recheck(); snapshot = try await managed.snapshot() }
			try Task.checkCancellation()
			try await repository.publish(id: id, metadata: metadata, state: prepared)
			let entry = SessionEntry(id: id, metadata: metadata, prepared: prepared, owner: managed, last: snapshot, configuration: configuration)
			if snapshot.storage.needsRecovery { entry.error = StorageFailure.recoveryRequired("a filesystem operation is pending").localizedDescription }
			return entry
		} catch {
			// Cleanup runs independently of caller cancellation and never discards a published checkpoint.
			let repository = repository, cleanup = Task { if let owner { try await owner.close() }; try await repository.abandon(prepared) }
			do { try await cleanup.value }
			catch let cleanupError { throw StorageFailure.recoveryRequired("import failed (\(error.localizedDescription)); native state cleanup also failed (\(cleanupError.localizedDescription))") }
			throw error
		}
	}
	public func run(id: String, running: Bool, downloadLimit: Int? = nil, uploadLimit: Int? = nil) async throws {
		try await serial(id: id) {
			if let pending = self.pending(id) {
				var configuration = self.configuration
				configuration.downloadLimit = downloadLimit ?? pending.downloadLimit; configuration.uploadLimit = uploadLimit ?? pending.uploadLimit
				try configuration.validate(); pending.downloadLimit = configuration.downloadLimit; pending.uploadLimit = configuration.uploadLimit
				pending.running = running && pending.error.isEmpty
				if pending.running { try await self.startMagnet(pending); await self.network?.resumeMapping() }
				else { await self.stopMagnet(pending); try await self.refreshRouting() }
				return
			}
			let entry = try self.entry(id)
			if downloadLimit != nil || uploadLimit != nil {
				let down = downloadLimit ?? entry.downloadLimit, up = uploadLimit ?? entry.uploadLimit
				try await entry.owner.setLimits(download: down, upload: up); entry.downloadLimit = down; entry.uploadLimit = up
			}
			if running && entry.error.isEmpty {
				try await entry.owner.start(); entry.running = true
				do { try await self.refreshRouting() } catch { entry.running = false; try? await entry.owner.pause(); throw error }
				await self.network?.resumeMapping()
				await self.startTracker(entry)
			} else { try await self.pauseEntry(entry) }
		}
	}
	public func pause(id: String) async throws {
		try await serial(id: id) {
			if let pending = self.pending(id) { pending.running = false; await self.stopMagnet(pending); try await self.refreshRouting() }
			else { try await self.pauseEntry(self.entry(id)) }
		}
	}
	public func save(id: String) async throws { try await serial(id: id) { if self.pending(id) == nil { try await self.entry(id).owner.save() } } }
	public func recheck(id: String) async throws {
		try await serial(id: id) {
			let entry = try self.entry(id); entry.activity = .checking; defer { entry.activity = nil }
			try await entry.owner.recheck(); entry.error = ""
		}
	}
	public func retry(id: String) async throws {
		try await serial(id: id) {
			if let pending = self.pending(id) { await self.stopMagnet(pending); pending.running = false; pending.error = ""; try await self.refreshRouting(); return }
			let entry = try self.entry(id)
			if !entry.closed { try await self.pauseEntry(entry) }
			if entry.closed {
				entry.owner = try await ManagedTransfer.open(metadata: entry.metadata, destination: entry.last.storage.destination,
					stateDirectory: entry.prepared.directory, configuration: self.configuration, resources: self.resources, budget: self.budget, preparedState: entry.prepared, peerID: self.peerID, clock: self.clock, webSeedTransport: self.webSeedTransport, event: { self.storageEvent(id, $0) })
				await self.observeDiscovery(id: id, owner: entry.owner)
				entry.closed = false
			}
			try await entry.owner.pause()
			if try await entry.owner.snapshot().storage.needsRecovery { try await entry.owner.changeStorage(.recover(acceptMatchingCopies: false)) }
			entry.error = ""
		}
	}
	public func changeStorage(id: String, change: TransferStorageChange) async throws {
		try await serial(id: id) {
			if let pending = self.pending(id), case .move(let destination) = change {
				try await self.repository.updateMagnet(pending.state, magnet: pending.magnet, destination: destination)
				pending.destination = destination; self.emit(SessionEvent(kind: "moved", id: id, path: destination.path)); return
			}
			let entry = try self.entry(id)
			switch change { case .move: entry.activity = .moving; case .rename: entry.activity = .renaming; default: break }
			defer { entry.activity = nil }
			do {
				try await entry.owner.changeStorage(change)
				entry.last = try await entry.owner.snapshot(); entry.error = ""
				if case .move = change { self.emit(SessionEvent(kind: "moved", id: id, path: entry.last.storage.destination.path)) }
			} catch { entry.error = error.localizedDescription; throw error }
		}
	}
	public func export(id: String) async throws -> Data {
		guard exports.count < 64 else { throw StorageFailure.limit("pending exports") }
		let key = UUID(), update = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
		exports[key] = (id, update.continuation)
		defer { exports.removeValue(forKey: key)?.signal.finish() }
		if let data = try await exportIfReady(id: id, key: key) { return data }
		let clock = clock
		return try await withThrowingTaskGroup(of: Data.self) { group in
			group.addTask {
				for await _ in update.stream {
					if let data = try await self.exportIfReady(id: id, key: key) { return data }
				}
				try Task.checkCancellation()
				throw SessionExportFailure.stopped
			}
			group.addTask {
				try await clock.sleep(for: 15)
				throw SessionExportFailure.timedOut
			}
			defer { group.cancelAll() }
			return try await group.next()!
		}
	}
	private func exportIfReady(id: String, key: UUID) async throws -> Data? {
		try await serial(id: id) {
			guard self.exports[key] != nil else { throw SessionExportFailure.stopped }
			let entry = try self.entry(id)
			do {
				let data = try await entry.owner.exportMetadata(), metadata = try TorrentMetadata(data)
				return metadata.trackerTiers == entry.metadata.trackerTiers ? data : try metadata.withTrackerTiers(entry.metadata.trackerTiers)
			} catch MetadataError.invalid("piece layers are incomplete") where entry.running { return nil }
		}
	}
	private func signalExports(id: String) {
		for export in exports.values where export.id == id { export.signal.yield(()) }
	}
	private func stopExports(id: String? = nil) {
		let keys = exports.filter { id == nil || $0.value.id == id }.keys
		for key in keys { exports.removeValue(forKey: key)?.signal.finish() }
	}
	public func appendTracker(id: String, tracker: String) async throws {
		try await serial(id: id, publishing: true) {
			if let pending = self.pending(id) {
				guard pending.verified?.0.inspection.private != true else { throw MetadataError.invalid("private trackers cannot be appended") }
				try self.validateTracker(tracker, hashes: pending.magnet.hashes)
				if !pending.magnet.trackers.contains(tracker) {
					guard pending.tracker == nil || pending.magnet.trackers.count < 32 else { throw HTTPServiceError.limit("tracker count") }
					var updated = pending.magnet; updated.trackers.append(tracker)
					try await self.repository.updateMagnet(pending.state, magnet: updated, destination: pending.destination)
					pending.magnet = updated
					if let service = pending.tracker, let url = URL(string: tracker) { try await service.append(url) }
					if let resolver = pending.resolver, pending.tracker == nil { await self.startMagnetTracker(pending, resolver: resolver) }
				}
				return
			}
			let entry = try self.entry(id)
			guard !entry.metadata.inspection.private else { throw MetadataError.invalid("private trackers cannot be appended") }
			let candidate = try self.appending(tracker, to: entry.metadata)
			try await self.repository.publish(id: id, metadata: candidate, state: entry.prepared); entry.metadata = candidate
			if let service = entry.tracker, let url = URL(string: tracker) { try await service.append(url) }
			else if entry.running { await self.startTracker(entry) }
		}
	}
	public func magnet(id: String) async throws -> String {
		try await serial(id: id) {
			if let pending = self.pending(id) { return pending.magnet.uri }
			let entry = try self.entry(id); return Magnet(hashes: entry.metadata.hashes, name: entry.metadata.inspection.name, trackers: entry.metadata.trackerTiers.flatMap({ $0 })).uri
		}
	}
	@discardableResult public func connect(id: String, to endpoint: NetworkEndpoint, utp: UTPTransport? = nil) async throws -> UUID {
		guard !closed, !networkChanging else { throw NetworkFailure.busy }
		guard configuration.addressFilter.allows(endpoint.address) else { throw PeerFailure.invalid("blocked peer") }
		if let pending = pending(id), pending.running, let resolver = pending.resolver {
			if utp != nil, peerSettings?.utp == false { throw NetworkFailure.invalid("µTP is disabled") }
			await resolver.enqueue([endpoint], utp: utp); return resolver.id
		}
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
		try await serial(id: id, publishing: true) {
			if let pending = self.pending(id) {
				guard !trash else { throw StorageFailure.invalid("cannot delete files without metadata") }
				pending.running = false; await self.stopMagnet(pending)
				if !retainState { try await self.repository.discard(id: id, pending: pending.state) }
				self.pendingMagnets.removeAll { $0 === pending }; try await self.refreshRouting(); return []
			}
			let entry = try self.entry(id)
			do {
				self.stopExports(id: id)
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
		try await serial(id: id, publishing: true) { guard !self.entries.contains(where: { $0.id == id }), self.pending(id) == nil else { throw StorageFailure.invalid("cannot forget a live transfer") }; try await self.repository.discard(id: id) }
	}
	public func shutdown() async throws {
		try await serial {
			self.stopExports()
			var failure: Error?
			for pending in self.pendingMagnets { pending.running = false; await self.stopMagnet(pending) }
			for entry in self.entries { entry.running = false }; try await self.refreshRouting()
			await self.drainPeerHints()
			for entry in self.entries { await entry.tracker?.halt() }
			for entry in self.entries where !entry.closed {
				do { try await entry.owner.pause() } catch { entry.error = error.localizedDescription; failure = failure ?? error }
			}
			await self.stopTrackers(self.entries)
			await self.network?.suspendMapping()
			if let failure { throw failure }
		}
	}
	public func snapshot() async throws -> TorrentSessionSnapshot {
		try Task.checkCancellation(); guard !closed else { throw PeerFailure.closed }
		var snapshots: [SessionTransferSnapshot] = []
		for entry in self.entries {
			var sampled = false
			if !entry.closed, pending(entry.id) == nil, let token = await commands.tryAcquire(entry.id) {
				guard !entry.closed, entries.contains(where: { $0 === entry }) else { await commands.release(token); continue }
				do { entry.last = try await entry.owner.snapshot(); sampled = true; await commands.release(token) }
				catch { await commands.release(token); throw error }
			}
			let messages = await entry.tracker?.messages() ?? entry.trackerMessages
			let fallback = await entry.tracker?.failure() ?? entry.trackerFailure
			let trackers = entry.metadata.trackerTiers.flatMap({ $0 }).map { url in SessionTrackerSnapshot(url: url, message: URL(string: url).flatMap { messages[$0] } ?? fallback) }
			let state = sampled ? entry.last : ManagedTransferSnapshot(storage: entry.last.storage, transfer: entry.running ? entry.last.transfer : nil, running: entry.running && !entry.closed)
			snapshots.append(SessionTransferSnapshot(id: entry.id, metadata: entry.metadata, state: state, error: entry.error, trackers: trackers, activity: entry.activity))
		}
		let wire = await self.network?.snapshot()
		let status = SessionNetworkSnapshot(port: wire?.port ?? 0, udp: wire?.udp ?? false, error: wire?.error.isEmpty == false ? wire!.error : self.networkError,
			pendingHandshakes: wire?.pendingHandshakes ?? 0, peers: self.budget.count, discovery: wire?.discovery ?? .disabled, localDiscovery: wire?.localDiscovery ?? false, routerMapped: wire?.routerMapped ?? false)
		let ready = Set(snapshots.map(\.id))
		var magnets: [SessionMagnetSnapshot] = []
		for pending in pendingMagnets where !ready.contains(pending.id) {
			let messages = await pending.tracker?.messages() ?? pending.trackerMessages
			let fallback = await pending.tracker?.failure() ?? pending.trackerFailure
			magnets.append(pending.snapshot(messages: messages, fallback: fallback))
		}
		let result = TorrentSessionSnapshot(transfers: snapshots, magnets: magnets, events: self.events, network: status); self.events.removeAll(); return result
	}
	@discardableResult public func configurePeers(_ settings: SessionPeerSettings) async throws -> UInt16 {
		try settings.validate()
		return try await serial {
			if settings.port != 0, settings == self.peerSettings, let network = self.network {
				let state = await network.snapshot()
				if state.port == settings.port && state.error.isEmpty && state.discovery.enabled == settings.dht && state.localDiscovery == settings.lsd { await network.resumeMapping(); return state.port }
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
					filter: self.configuration.addressFilter, loopbackOnly: self.loopbackOnly, clock: self.clock, bootstrap: self.dhtBootstrap, localDiscoveryFactory: self.localDiscoveryFactory, mappingRoutes: self.routerMappingRoutes) { [weak self] target, endpoint in
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
			try await self.restartMagnets()
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
			try await self.restartMagnets()
		}
	}
	public func close() async throws {
		let token = try await commands.acquire()
		do {
			if !closed {
				stopExports()
				networkChanging = true; defer { networkChanging = false }
				for pending in pendingMagnets { pending.running = false; await stopMagnet(pending) }
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
				if let failure { throw failure }; pendingMagnets.removeAll(); closed = true
			}
			await commands.release(token)
		} catch { await commands.release(token); throw error }
	}
	private func refreshRouting() async throws {
		try await routing.acquire()
		do { try await updateRouting(); await routing.release() }
		catch { await routing.release(); throw error }
	}
	private func updateRouting() async throws {
		guard let network else { return }
		var targets = entries.filter { $0.running && !$0.closed && $0.error.isEmpty }.map {
			SessionPeerTarget(id: $0.id, hashes: Self.wireHashes($0.metadata.hashes), owner: .transfer($0.owner))
		}
		if !networkChanging {
			for pending in pendingMagnets {
				guard pending.running, pending.error.isEmpty, pending.verified == nil, let resolver = pending.resolver else { continue }
				targets.append(SessionPeerTarget(id: pending.id, hashes: Self.wireHashes(pending.magnet.hashes), owner: .magnet(resolver, peerID: peerID)))
			}
		}
		do {
			try await network.setTargets(targets)
			let publicEntries = networkChanging ? [] : entries.filter { $0.running && !$0.closed && $0.error.isEmpty && !$0.metadata.inspection.private }
			let discovery = publicEntries.map { SessionDHTTarget(id: $0.id, metadata: $0.metadata, owner: $0.owner) }
			let magnets: [SessionMagnetTarget] = networkChanging ? [] : pendingMagnets.compactMap { pending in
				guard pending.running, pending.error.isEmpty, pending.verified == nil, let resolver = pending.resolver else { return nil }
				return SessionMagnetTarget(id: pending.id, magnet: pending.magnet, revision: pending.revision) { await resolver.enqueue($0) }
			}
			var seen = Set(entries.map { $0.metadata.hashes })
			let verifiedPrivate = pendingMagnets.compactMap { $0.verified?.0 }.filter { $0.inspection.private && seen.insert($0.hashes).inserted }
			await network.updateDiscovery(discovery, metadata: publicEntries.map(\.metadata) + entries.filter { $0.metadata.inspection.private }.map(\.metadata) + verifiedPrivate, magnets: magnets)
		}
		catch NetworkFailure.closed { let state = await network.snapshot(); networkError = state.error.isEmpty ? NetworkFailure.closed.localizedDescription : state.error }
	}
	private func pending(_ id: String) -> SessionPendingMagnet? { pendingMagnets.first { $0.id == id } }

	private func startMagnet(_ pending: SessionPendingMagnet, refresh: Bool = true) async throws {
		guard pending.running, pending.error.isEmpty, pending.resolver == nil else { return }
		if pending.verified != nil { schedulePromotion(pending); return }
		let id = pending.id, revision = pending.revision, settings = peerSettings, network = network
		let resolver = SessionMagnetResolver(magnet: pending.magnet, budget: budget, permits: metadataPermits, configuration: configuration, clock: clock, transport: { endpoint in
			if settings?.tcp != false { return nil }
			guard settings?.utp == true, let network else { throw NetworkFailure.closed }
			return try await network.transport(for: endpoint)
		}) { [weak self] metadata, endpoint in
			await self?.receivedMetadata(id, revision: revision, metadata: metadata, endpoint: endpoint)
		}
		pending.resolver = resolver
		if refresh { try await refreshRouting() }
		await startMagnetTracker(pending, resolver: resolver)
		await resolver.enqueue(pending.magnet.peers.compactMap(SessionMagnetResolver.endpoint))
	}

	private func startMagnetTracker(_ pending: SessionPendingMagnet, resolver: SessionMagnetResolver) async {
		guard pending.running, pending.verified == nil, pending.tracker == nil, !pending.magnet.trackers.isEmpty else { return }
		do {
			let endpoint = try await trackerEndpoint()
			guard pending.verified == nil else { return }
			let service = try SessionTracker(magnet: pending.magnet, resolver: resolver, peerID: peerID, port: endpoint.port, preferV2: configuration.preferV2, client: endpoint.client, clock: clock)
			pending.tracker = service; pending.trackerMessages = [:]; pending.trackerFailure = ""; await service.start()
		} catch { pending.trackerFailure = error.localizedDescription }
	}

	private func restartMagnets() async throws {
		guard pendingMagnets.contains(where: \.running) else { return }
		for pending in pendingMagnets where pending.running { try await startMagnet(pending, refresh: false) }
		try await refreshRouting()
	}

	private func stopMagnet(_ pending: SessionPendingMagnet, cancelPromotion: Bool = true) async {
		let resolver = pending.resolver; pending.resolver = nil
		let tracker = pending.tracker; pending.tracker = nil
		let task = cancelPromotion ? pending.promotion : nil
		if cancelPromotion { pending.revision = UUID(); pending.promotion = nil; task?.cancel() }
		await tracker?.halt(); await resolver?.stop()
		if let tracker { await tracker.stop(); pending.trackerMessages = await tracker.messages(); pending.trackerFailure = await tracker.failure() }
		await task?.value
	}

	private func receivedMetadata(_ id: String, revision: UUID, metadata: TorrentMetadata, endpoint: NetworkEndpoint?) {
		guard !closed, !networkChanging, let pending = pending(id), pending.revision == revision, pending.running, pending.verified == nil else { return }
		pending.verified = (metadata, endpoint); schedulePromotion(pending)
	}

	private func schedulePromotion(_ pending: SessionPendingMagnet) {
		guard pending.promotion == nil else { return }
		let id = pending.id, revision = pending.revision
		pending.promotion = Task { [weak self] in await self?.promoteMagnet(id, revision: revision) }
	}

	private func promoteMagnet(_ id: String, revision: UUID) async {
		do {
			// Retire discovery immediately, even if repository publication is busy.
			try await refreshRouting()
			try await serial(id: id, publishing: true) {
				guard let source = self.pending(id), source.revision == revision, let verified = source.verified else { return }
				let aliases = self.pendingMagnets.filter { Self.matches($0.magnet.hashes, verified.0.hashes) }
				guard let winner = aliases.first else { throw MetadataError.invalid("resolved magnet identity") }
				for alias in aliases { alias.verified = verified; await self.stopMagnet(alias, cancelPromotion: alias !== source) }
				try await self.refreshRouting()
				let existing = self.entries.first { Self.overlaps($0.metadata.hashes, verified.0.hashes) }
				let entry: SessionEntry
				if let existing {
					guard existing.metadata.originalInfo == verified.0.originalInfo else { throw MetadataError.invalid("conflicting verified swarm identity") }
					entry = existing
				} else {
					var metadata = verified.0
					if winner.magnet.trackers != metadata.trackerTiers.flatMap({ $0 }) || winner.magnet.webSeeds != metadata.webSeeds {
						metadata = try TorrentMetadata(infoBytes: metadata.originalInfo, expected: metadata.hashes, trackers: winner.magnet.trackers, webSeeds: winner.magnet.webSeeds)
					}
					var configuration = self.configuration; configuration.downloadLimit = winner.downloadLimit; configuration.uploadLimit = winner.uploadLimit
					let stored = try await self.repository.retainedMetadata(id: winner.id)
					guard stored == nil || stored?.originalInfo == metadata.originalInfo else { throw MetadataError.invalid("retained magnet identity") }
					entry = try await self.publishMetadata(id: winner.id, metadata: metadata, destination: winner.destination, restore: stored != nil, configuration: configuration, pending: winner.state)
					if winner.running, entry.error.isEmpty {
						do {
							try await entry.owner.start()
							entry.last = try await entry.owner.snapshot(); entry.running = true
						} catch { try? await entry.owner.pause(); entry.error = error.localizedDescription }
					}
				}
				let resolved = Set(aliases.map(\.id))
				// Published metadata is authoritative even if retirement of a pending record fails.
				for alias in aliases {
					do { try await self.repository.retireMagnet(alias.state) }
					catch { Self.log.error("Could not retire pending magnet state: \(error.localizedDescription)") }
				}
				if existing == nil { self.entries.append(entry) }
				self.pendingMagnets.removeAll { resolved.contains($0.id) }
				for alias in aliases where alias.id != entry.id { self.emit(SessionEvent(kind: "duplicate", id: alias.id, existingID: entry.id)) }
				try await self.refreshRouting()
				if existing == nil, entry.running {
					await self.startTracker(entry)
					if !entry.metadata.inspection.private, let endpoint = verified.1 { _ = try? await self.connect(id: entry.id, to: endpoint) }
				}
			}
		} catch {
			if let pending = pending(id), pending.revision == revision {
				pending.promotion = nil
				if !(error is CancellationError) { pending.error = error.localizedDescription; pending.running = false }
			}
		}
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
		for pending in pendingMagnets { await stopMagnet(pending) }
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
			try? await restartMagnets()
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
			let endpoint = try await trackerEndpoint(), initial = try await entry.owner.snapshot(), id = entry.id
			let service = try SessionTracker(metadata: entry.metadata, owner: entry.owner, peerID: peerID, port: endpoint.port, preferV2: configuration.preferV2,
				initial: initial, baseline: entry.trackerBaseline, client: endpoint.client, clock: clock) { [weak self] peer in _ = try? await self?.connect(id: id, to: NetworkEndpoint(peer.address, port: peer.port)) }
			entry.tracker = service; entry.trackerFailure = ""; entry.trackerMessages = [:]; await service.start()
		} catch { entry.trackerFailure = error.localizedDescription }
	}
	private func trackerEndpoint() async throws -> (client: TrackerClient, port: UInt16) {
		try await trackerSetup.acquire()
		do {
			try Task.checkCancellation()
			if network == nil && peerSettings == nil {
				let settings = currentPeerSettings
				network = try await SessionPeerNetwork.open(settings: settings, budget: budget, encryption: configuration.encryption,
					filter: configuration.addressFilter, loopbackOnly: loopbackOnly, clock: clock, bootstrap: dhtBootstrap, localDiscoveryFactory: localDiscoveryFactory) { [weak self] target, endpoint in
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
			let result = (trackerClient!, await network.snapshot().port)
			await trackerSetup.release(); return result
		} catch { await trackerSetup.release(); throw error }
	}
	private func entry(_ id: String) throws -> SessionEntry {
		if let entry = entries.first(where: { $0.id == id }) { return entry }
		if pending(id) != nil { throw MetadataError.invalid("metadata is still resolving") }
		throw StorageFailure.invalid("transfer no longer exists")
	}
	private func validateTracker(_ tracker: String, hashes: InfoHashes) throws {
		guard let url = URL(string: tracker), ["http", "https", "udp"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil else { throw MetadataError.invalid("tracker URL") }
		let hash = hashes.v1 ?? Data(hashes.v2!.prefix(20))
		try TrackerAnnouncer.validate(tracker: url, request: TrackerRequest(infoHash: hash, peerID: peerID, port: max(1, configuration.listenPort), counters: TrackerCounters(left: 0)))
	}
	private func appending(_ tracker: String, to metadata: TorrentMetadata) throws -> TorrentMetadata {
		try validateTracker(tracker, hashes: metadata.hashes)
		if metadata.trackerTiers.flatMap({ $0 }).contains(tracker) { return metadata }
		return try TorrentMetadata(metadata.withTrackerTiers(metadata.trackerTiers + [[tracker]]))
	}
	private func emit(_ event: SessionEvent) { if events.count >= 1024 { events.removeFirst() }; events.append(event) }
	private static func overlaps(_ a: InfoHashes, _ b: InfoHashes) -> Bool { (a.v1 != nil && a.v1 == b.v1) || (a.v2 != nil && a.v2 == b.v2) }
	private static func wireHashes(_ hashes: InfoHashes) -> [Data] {
		[hashes.v1, hashes.v2.map { Data($0.prefix(20)) }].compactMap { $0 }
	}
	private static func matches(_ expected: InfoHashes, _ actual: InfoHashes) -> Bool { (expected.v1 == nil || expected.v1 == actual.v1) && (expected.v2 == nil || expected.v2 == actual.v2) }
	private func serial<T: Sendable>(id: String? = nil, publishing: Bool = false, _ body: () async throws -> T) async throws -> T {
		let token = try await commands.acquire(id); var ownsPublication = false
		do {
			try Task.checkCancellation(); guard !closed else { throw PeerFailure.closed }
			if publishing || id.map({ pending($0) != nil }) == true { try await publication.acquire(); ownsPublication = true }
			try Task.checkCancellation()
			let result = try await body()
			if let id { await cache(id) }
			if ownsPublication { await publication.release() }; await commands.release(token); return result
		} catch {
			if ownsPublication { await publication.release() }; await commands.release(token); throw error
		}
	}
	private func cache(_ id: String) async {
		guard let entry = entries.first(where: { $0.id == id }), !entry.closed else { return }
		do { entry.last = try await entry.owner.snapshot() }
		catch is CancellationError { }
		catch { entry.error = error.localizedDescription }
	}
	deinit { if let network { Task { await network.shutdown() } } }
}
