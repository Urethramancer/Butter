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
}

public struct SessionEvent: Sendable {
	public let kind: String
	public let id: String
	public let path: String?
}

public struct TorrentSessionSnapshot: Sendable {
	public let transfers: [SessionTransferSnapshot]
	public let events: [SessionEvent]
}

private final class SessionEntry {
	let id: String
	let prepared: PreparedTransferState
	var metadata: TorrentMetadata
	var owner: ManagedTransfer
	var last: ManagedTransferSnapshot
	var error = ""
	var closed = false
	var receipts: [URL] = []
	var downloadLimit: Int
	var uploadLimit: Int
	init(id: String, metadata: TorrentMetadata, prepared: PreparedTransferState, owner: ManagedTransfer, last: ManagedTransferSnapshot, configuration: TCPTransferConfiguration) {
		self.id = id; self.metadata = metadata; self.prepared = prepared; self.owner = owner; self.last = last
		downloadLimit = configuration.downloadLimit; uploadLimit = configuration.uploadLimit
	}
}

/// TorrentSession owns native imports and serialises app commands without GUI dependencies.
public actor TorrentSession {
	private let repository: TransferRepository
	private let resources: TransferResources
	private let configuration: TCPTransferConfiguration
	private let budget: TCPPeerBudget
	private let commands = TransferPermits(1)
	private var entries: [SessionEntry] = []
	private var events: [SessionEvent] = []
	public init(storage: URL, configuration: TCPTransferConfiguration = .init(), resources: TransferResources = .shared, maximumPeers: Int = 200) {
		repository = TransferRepository(root: storage); self.configuration = configuration; self.resources = resources; budget = TCPPeerBudget(limit: maximumPeers)
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
					selected: selected, configuration: self.configuration, resources: self.resources, budget: self.budget, preparedState: prepared); owner = managed
				var snapshot = try await managed.snapshot()
				if !snapshot.storage.needsRecovery { try await managed.recheck(); snapshot = try await managed.snapshot() }
				try Task.checkCancellation()
				try await self.repository.publish(id: id, metadata: metadata, state: prepared)
				let entry = SessionEntry(id: id, metadata: metadata, prepared: prepared, owner: managed, last: snapshot, configuration: self.configuration)
				if snapshot.storage.needsRecovery { entry.error = StorageFailure.recoveryRequired("a filesystem operation is pending").localizedDescription }
				self.entries.append(entry)
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
			if running && entry.error.isEmpty { try await entry.owner.start() } else { try await entry.owner.pause() }
		}
	}
	public func pause(id: String) async throws { try await serial { try await self.entry(id).owner.pause() } }
	public func save(id: String) async throws { try await serial { try await self.entry(id).owner.save() } }
	public func recheck(id: String) async throws {
		try await serial { let entry = try self.entry(id); try await entry.owner.recheck(); entry.error = "" }
	}
	public func retry(id: String) async throws {
		try await serial {
			let entry = try self.entry(id)
			if entry.closed {
				entry.owner = try await ManagedTransfer.open(metadata: entry.metadata, destination: entry.last.storage.destination,
					stateDirectory: entry.prepared.directory, configuration: self.configuration, resources: self.resources, budget: self.budget, preparedState: entry.prepared)
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
		}
	}
	public func magnet(id: String) async throws -> String {
		try await serial { let entry = try self.entry(id); return Magnet(hashes: entry.metadata.hashes, name: entry.metadata.inspection.name, trackers: entry.metadata.trackerTiers.flatMap({ $0 })).uri }
	}
	@discardableResult public func connect(id: String, to endpoint: NetworkEndpoint, utp: UTPTransport? = nil) async throws -> UUID {
		let owner = try entry(id).owner; return try await owner.connect(to: endpoint, utp: utp)
	}
	public func remove(id: String, trash: Bool = false, retainState: Bool = false, trashDirectory: URL? = nil) async throws -> [URL] {
		try await serial {
			let entry = try self.entry(id)
			do {
				if !entry.closed {
					try await entry.owner.pause()
					if trash { entry.receipts = try await entry.owner.trash(directory: trashDirectory) }
					entry.last = try await entry.owner.snapshot(); try await entry.owner.close(); entry.closed = true
				}
				if !retainState { try await self.repository.discard(id: id) }
				self.entries.removeAll { $0.id == id }; return entry.receipts
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
			for entry in self.entries where !entry.closed {
				do { try await entry.owner.pause() } catch { entry.error = error.localizedDescription; failure = failure ?? error }
			}
			if let failure { throw failure }
		}
	}
	public func snapshot() async throws -> TorrentSessionSnapshot {
		try await serial {
			var snapshots: [SessionTransferSnapshot] = []
			for entry in self.entries {
				if !entry.closed { entry.last = try await entry.owner.snapshot() }
				snapshots.append(SessionTransferSnapshot(id: entry.id, metadata: entry.metadata, state: entry.last, error: entry.error))
			}
			let result = TorrentSessionSnapshot(transfers: snapshots, events: self.events); self.events.removeAll(); return result
		}
	}
	private func entry(_ id: String) throws -> SessionEntry {
		guard let entry = entries.first(where: { $0.id == id }) else { throw StorageFailure.invalid("transfer no longer exists") }; return entry
	}
	private func appending(_ tracker: String, to metadata: TorrentMetadata) throws -> TorrentMetadata {
		guard let url = URL(string: tracker), ["http", "https", "udp"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil else { throw MetadataError.invalid("tracker URL") }
		if metadata.trackerTiers.flatMap({ $0 }).contains(tracker) { return metadata }
		return try TorrentMetadata(metadata.withTrackerTiers(metadata.trackerTiers + [[tracker]]))
	}
	private func emit(_ event: SessionEvent) { if events.count >= 1024 { events.removeFirst() }; events.append(event) }
	private static func overlaps(_ a: InfoHashes, _ b: InfoHashes) -> Bool { (a.v1 != nil && a.v1 == b.v1) || (a.v2 != nil && a.v2 == b.v2) }
	private func serial<T: Sendable>(_ body: () async throws -> T) async throws -> T {
		try await commands.acquire()
		do { try Task.checkCancellation(); let result = try await body(); await commands.release(); return result }
		catch { await commands.release(); throw error }
	}
}
