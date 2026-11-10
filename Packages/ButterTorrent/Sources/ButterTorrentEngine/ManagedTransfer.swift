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
		budget: TCPPeerBudget? = nil, preparedState: PreparedTransferState? = nil, peerID: Data? = nil, clock: any TransportClock = ContinuousTransportClock(), webSeedTransport: (any HTTPTransport)? = nil) async throws -> ManagedTransfer {
		try configuration.validate()
		let identity = peerID ?? Data("-BT0001-".utf8) + Data((0..<12).map { _ in UInt8.random(in: 0...255) })
		guard identity.count == 20 else { throw PeerFailure.invalid("peer identifier") }
		let storage = try await TorrentStorage.open(metadata: metadata, destination: destination, stateDirectory: stateDirectory, selected: selected, preparedState: preparedState)
		return ManagedTransfer(metadata: metadata, storage: storage, configuration: configuration, resources: resources, budget: budget, peerID: identity, clock: clock, webSeedTransport: webSeedTransport)
	}
	public func start() async throws {
		try await serial {
			guard !self.pauseFailed else { throw StorageFailure.recoveryRequired("retry pausing before restarting") }
			if self.transfer == nil { try await self.resume() }
		}
	}
	public func pause() async throws { try await serial { try await self.quiesce() } }
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
			// Sample the picker before disk stamps so newly verified pieces cannot look
			// like invalidation. External file changes must retire the old advertisements.
			var wire = await self.transfer?.snapshot(), disk = try await self.storage.snapshot()
			if let previous = wire, !self.pauseFailed, !previous.verifiedPieces.isSubset(of: disk.verifiedPieces) {
				try await self.quiesce(); try await self.resume()
				wire = await self.transfer?.snapshot(); disk = try await self.storage.snapshot()
			}
			return ManagedTransferSnapshot(storage: disk, transfer: wire, running: self.transfer != nil && !self.pauseFailed)
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
		}
	}
	public func exportMetadata() async throws -> Data {
		try await serial {
			// Exporting does not mutate payload or picker state and need not disconnect peers.
			try await self.checkpoint()
			return try await self.storage.exportMetadata()
		}
	}
	public func save() async throws { try await serial { try await self.checkpoint() } }
	private func checkpoint() async throws {
		if let transfer {
			let counters = await transfer.snapshot(); try await storage.checkpoint(downloaded: counters.downloaded, uploaded: counters.uploaded)
		} else {
			let counters = try await storage.snapshot(); try await storage.checkpoint(downloaded: counters.downloaded, uploaded: counters.uploaded)
		}
	}
	public func close() async throws {
		try await commands.acquire()
		do {
			if !closed { try await quiesce(); try await storage.shutdown(); closed = true }
			await commands.release()
		} catch { await commands.release(); throw error }
	}
	private func resume() async throws {
		try Task.checkCancellation()
		transfer = try await TCPTransfer.open(metadata: metadata, storage: storage, configuration: configuration, peerID: peerID, budget: budget, resources: resources, clock: clock, webSeedClient: webClient)
		startDiscovery(transfer!)
	}
	private func quiesce() async throws {
		await stopDiscovery()
		guard let transfer else { return }
		do { try await transfer.shutdown(); self.transfer = nil; pauseFailed = false }
		catch { pauseFailed = true; throw error }
	}
	private func mutate(_ body: (TorrentStorage) async throws -> Void) async throws {
		try await serial {
			let wasRunning = self.transfer != nil
			try await self.quiesce()
			do { try Task.checkCancellation(); try await body(self.storage) }
			catch {
				// A pending journal keeps the transfer paused. Rejected preflights can
				// retain the prior running state without hiding the original error.
				if wasRunning, !Task.isCancelled, (try? await self.storage.snapshot().needsRecovery) == false { try? await self.resume() }
				throw error
			}
			if wasRunning { try await self.resume() }
		}
	}
	public func trash(directory: URL? = nil) async throws -> [URL] {
		try await serial { try await self.quiesce(); return try await self.storage.trash(directory: directory) }
	}
	private func serial<T: Sendable>(_ body: () async throws -> T) async throws -> T {
		try await commands.acquire()
		do {
			try Task.checkCancellation(); guard !closed else { throw PeerFailure.closed }
			let result = try await body(); await commands.release(); return result
		} catch { await commands.release(); throw error }
	}
	deinit { for task in discoveryPumps { task.cancel() } }
}
