import Foundation
import Darwin
import ButterTorrentMetadata
import ButterTorrentNetworking
import ButterTorrentStorage

public struct ManagedTransferSnapshot: Sendable {
	public let storage: StorageSnapshot
	public let transfer: TCPTransferSnapshot?
	public let running: Bool
}

public enum TransferStorageChange: Sendable {
	case select([Bool])
	case rename([Int: String])
	case move(URL)
	case recover(acceptMatchingCopies: Bool)
}

/// ManagedTransfer drains peer I/O before changing storage, and reopens only safe storage.
public actor ManagedTransfer {
	public nonisolated let metadata: TorrentMetadata
	private let storage: TorrentStorage
	private let resources: TransferResources
	private let budget: TCPPeerBudget?
	private let clock: any TransportClock
	private let peerID: Data
	private let webClient: WebSeedClient
	private let nativeWebTransport: NetworkHTTPTransport?
	private let commands = TransferPermits(1)
	private var configuration: TCPTransferConfiguration
	var transfer: TCPTransfer?
	var closed = false
	var pauseFailed = false
	private var observedGeneration: UInt64?
	private var automaticRecovery: Task<Void, Never>?
	private var automaticRecoveryID: UUID?
	private var automaticResume = false
	private var automaticError: (any Error)?
	var discoveryHandler: (@Sendable (ManagedDiscoveryNotice) async -> Void)?
	var discoveryRevision = UUID()
	var discoveryPumps: [Task<Void, Never>] = []
	private init(metadata: TorrentMetadata, storage: TorrentStorage, configuration: TCPTransferConfiguration,
		resources: TransferResources, budget: TCPPeerBudget?, peerID: Data, clock: any TransportClock, webSeedTransport: (any HTTPTransport)?) {
		self.metadata = metadata; self.storage = storage; self.configuration = configuration
		self.resources = resources; self.budget = budget; self.clock = clock
		self.peerID = peerID
		let native = webSeedTransport == nil ? NetworkHTTPTransport(clock: clock, addressFilter: configuration.addressFilter) : nil
		nativeWebTransport = native
		webClient = WebSeedClient(transport: webSeedTransport ?? native!, clock: clock, maximumBytes: 16384)
	}
	public static func open(metadata: TorrentMetadata, destination: URL, stateDirectory: URL, selected: [Bool]? = nil,
		configuration: TCPTransferConfiguration = .init(), resources: TransferResources = .shared,
		budget: TCPPeerBudget? = nil, preparedState: PreparedTransferState? = nil, peerID: Data? = nil, clock: any TransportClock = ContinuousTransportClock(), webSeedTransport: (any HTTPTransport)? = nil, event: @escaping @Sendable (StorageEvent) -> Void = { _ in }) async throws -> ManagedTransfer {
		try configuration.validate()
		let identity = peerID ?? Data("-BT0001-".utf8) + Data((0..<12).map { _ in UInt8.random(in: 0...255) })
		guard identity.count == 20 else { throw PeerFailure.invalid("peer identifier") }
		let storage = try await TorrentStorage.open(metadata: metadata, destination: destination, stateDirectory: stateDirectory, selected: selected, preparedState: preparedState,
			checkpointPolicy: .managed, verificationPolicy: .deferred, checkpointClock: TransferCheckpointClock(clock: clock), event: event)
		return ManagedTransfer(metadata: metadata, storage: storage, configuration: configuration, resources: resources, budget: budget, peerID: identity, clock: clock, webSeedTransport: webSeedTransport)
	}
	public func start() async throws {
		try await serial {
			guard !self.pauseFailed else { throw StorageFailure.recoveryRequired("retry pausing before restarting") }
			if let error = self.automaticError { throw error }
			if self.automaticResume { return }
			if self.transfer == nil { try await self.resume() }
		}
	}
	public func pause() async throws {
		_ = await cancelAutomaticRecovery()
		try await serial { try await self.quiesce() }
	}
	func disconnectPeers() async throws { try await serial { await self.transfer?.disconnectPeers() } }
	public func setLimits(download: Int, upload: Int) async throws {
		try await serial {
			var candidate = self.configuration; candidate.downloadLimit = download; candidate.uploadLimit = upload; try candidate.validate()
			try await self.transfer?.setLimits(download: download, upload: upload); self.configuration = candidate
		}
	}
	public func configurePeers(maximum: Int, pex: Bool, port: UInt16, allowSameIP: Bool, addressFilter: PeerAddressFilter = .init(), dhtPort: UInt16 = 0) async throws {
		try await serial {
			var candidate = self.configuration; candidate.maximumPeers = maximum; candidate.enablePEX = pex; candidate.listenPort = port; candidate.allowSameIP = allowSameIP
			candidate.addressFilter = addressFilter
			candidate.dhtPort = dhtPort
			try candidate.validate(); let running = self.transfer != nil
			try await self.quiesce(); self.configuration = candidate
			await self.nativeWebTransport?.setAddressFilter(addressFilter)
			if running { try await self.resume() }
		}
	}
	@discardableResult public func connect(to endpoint: NetworkEndpoint, utp: UTPTransport? = nil) async throws -> UUID {
		guard !closed, !pauseFailed, let transfer else { throw PeerFailure.closed }
		return try await transfer.connect(to: endpoint, utp: utp)
	}
	@discardableResult public func attach(_ stream: any PeerByteStream) async throws -> UUID {
		guard !closed, !pauseFailed, let transfer else { stream.close(); throw PeerFailure.closed }
		return try await transfer.attach(stream)
	}
	@discardableResult public func attach(_ channel: PeerStream) async throws -> UUID {
		guard !closed, !pauseFailed, let transfer else { channel.close(); throw PeerFailure.closed }; return try await transfer.attach(channel)
	}
	public func snapshot() async throws -> ManagedTransferSnapshot {
		try await serial {
			if let error = self.automaticError { throw error }
			// Sample the picker before disk stamps so newly verified pieces cannot look
			// like invalidation. External file changes must retire the old advertisements.
			var wire = await self.transfer?.snapshot(), disk = try await self.storage.snapshot()
			let changed = self.observedGeneration.map { $0 != disk.integrityGeneration } ?? false
			let invalidated = wire.map { !$0.verifiedPieces.isSubset(of: disk.verifiedPieces) } ?? false
			self.observedGeneration = disk.integrityGeneration
			if self.transfer != nil, !self.pauseFailed, changed || invalidated {
				try await self.quiesce()
				wire = nil; disk = try await self.storage.snapshot()
				self.beginAutomaticRecovery(generation: disk.integrityGeneration)
			}
			return ManagedTransferSnapshot(storage: disk, transfer: wire, running: (self.transfer != nil || self.automaticResume) && !self.pauseFailed)
		}
	}
	public func changeStorage(_ change: TransferStorageChange) async throws {
		try await mutate { storage in
			switch change {
			case .select(let selected): try await storage.select(selected)
			case .rename(let changes): try await storage.rename(changes)
			case .move(let destination): try await storage.move(to: destination)
			case .recover(let matching): try await storage.recover(acceptMatchingCopies: matching)
			}
		}
	}
	public func recheck() async throws {
		try await mutate { storage in
			for piece in 0..<storage.layout.pieceCount {
				try Task.checkCancellation()
				do { _ = try await storage.verify(piece: piece) }
				catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { }
				catch StorageFailure.invalid("short payload read") { }
				catch StorageFailure.missingHashes { }
			}
			try await storage.flush()
		}
	}
	public func repairFile(_ index: Int, from source: URL) async throws -> StorageRepairResult {
		try await mutate { try await $0.repairFile(index, from: source) }
	}
	public func repairFolder(from folder: URL) async throws -> StorageRepairResult {
		try await mutate { try await $0.repairFolder(from: folder) }
	}
	public func exportMetadata() async throws -> Data {
		try await serial {
			// Exporting does not mutate payload or picker state and need not disconnect peers.
			let data = try await self.storage.exportMetadata()
			try await self.checkpoint()
			return data
		}
	}
	public func save() async throws { try await serial { try await self.checkpoint() } }
	private func checkpoint() async throws {
		if let transfer {
			try await transfer.checkpoint()
		} else {
			try await storage.flush()
		}
	}
	public func close() async throws {
		_ = await cancelAutomaticRecovery()
		try await commands.acquire()
		do {
			if !closed { try await quiesce(); try await storage.shutdown(); closed = true }
			await commands.release()
		} catch { await commands.release(); throw error }
	}
	private func resume() async throws {
		try Task.checkCancellation()
		observedGeneration = try await storage.snapshot().integrityGeneration
		transfer = try await TCPTransfer.open(metadata: metadata, storage: storage, configuration: configuration, peerID: peerID, budget: budget, resources: resources, clock: clock, webSeedClient: webClient)
		startDiscovery(transfer!)
	}
	private func quiesce() async throws {
		await stopDiscovery()
		guard let transfer else { return }
		do { try await transfer.shutdown(); self.transfer = nil; pauseFailed = false }
		catch { pauseFailed = true; throw error }
	}
	private func mutate<T: Sendable>(_ body: (TorrentStorage) async throws -> T) async throws -> T {
		let recovering = await cancelAutomaticRecovery()
		return try await serial {
			let wasRunning = self.transfer != nil || recovering
			try await self.quiesce()
			let result: T
			do { try Task.checkCancellation(); result = try await body(self.storage) }
			catch {
				// A pending journal keeps the transfer paused. Rejected preflights can
				// retain the prior running state without hiding the original error.
				if wasRunning, !Task.isCancelled, (try? await self.storage.snapshot().needsRecovery) == false { try? await self.resume() }
				throw error
			}
			if wasRunning { try await self.resume() }
			return result
		}
	}
	public func trash(directory: URL? = nil) async throws -> [URL] {
		_ = await cancelAutomaticRecovery()
		return try await serial { try await self.quiesce(); return try await self.storage.trash(directory: directory) }
	}
	private func serial<T: Sendable>(_ body: () async throws -> T) async throws -> T {
		try await commands.acquire()
		do {
			try Task.checkCancellation(); guard !closed else { throw PeerFailure.closed }
			let result = try await body(); await commands.release(); return result
		} catch { await commands.release(); throw error }
	}
	private func cancelAutomaticRecovery() async -> Bool {
		let task = automaticRecovery, running = automaticResume
		automaticRecovery = nil; automaticRecoveryID = nil; automaticResume = false; automaticError = nil
		task?.cancel(); await task?.value
		return running
	}
	private func beginAutomaticRecovery(generation: UInt64) {
		let id = UUID(), clock = clock
		automaticRecoveryID = id; automaticResume = true
		automaticRecovery = Task { [weak self] in
			var generation = generation
			do {
				while !Task.isCancelled {
					try await clock.sleep(for: 1)
					guard let next = try await self?.recoverStableGeneration(id, generation: generation) else { return }
					generation = next
				}
			} catch { await self?.automaticRecoveryFailed(id, error: error) }
		}
	}
	private func automaticRecoveryFailed(_ id: UUID, error: any Error) {
		guard automaticRecoveryID == id else { return }
		automaticRecoveryID = nil; automaticRecovery = nil; automaticResume = false
		if !(error is CancellationError) { automaticError = error }
	}
	private func recoverStableGeneration(_ id: UUID, generation: UInt64) async throws -> UInt64? {
		try await serial {
			guard self.automaticRecoveryID == id else { return nil }
			let before = try await self.storage.snapshot()
			if before.integrityGeneration != generation { return before.integrityGeneration }
			let scope = TransferDiskScope(resources: self.resources)
			for piece in 0..<self.storage.layout.pieceCount where before.uncheckedPieces[piece / 8] & (128 >> (piece % 8)) != 0 {
				try Task.checkCancellation(); try await scope.acquire()
				do { _ = try await self.storage.recoverExistingPiece(piece) }
				catch {
					await scope.release()
					let current = try await self.storage.snapshot()
					if current.integrityGeneration != generation { return current.integrityGeneration }
					throw error
				}
				await scope.release()
			}
			try await self.storage.flush()
			let after = try await self.storage.snapshot()
			if after.integrityGeneration != generation { return after.integrityGeneration }
			try Task.checkCancellation()
			guard self.automaticRecoveryID == id else { return nil }
			if self.automaticResume { try await self.resume() }
			self.automaticResume = false; self.automaticRecoveryID = nil; self.automaticRecovery = nil
			return nil
		}
	}
	deinit { automaticRecovery?.cancel(); for task in discoveryPumps { task.cancel() } }
}

private struct TransferCheckpointClock: StorageCheckpointClock {
	let clock: any TransportClock
	func now() -> TimeInterval { clock.now() }
	func sleep(for seconds: TimeInterval) async throws { try await clock.sleep(for: seconds) }
}
