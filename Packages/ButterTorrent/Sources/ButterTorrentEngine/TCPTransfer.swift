import Foundation
import ButterTorrentMetadata
import ButterTorrentNetworking
import ButterTorrentStorage

public struct TCPTransferConfiguration: Sendable {
	public var maximumPeers = 50
	public var allowSameIP = true
	public var addressFilter = PeerAddressFilter()
	public var pipeline = 8
	public var uploadSlots = 4
	public var requestTimeout: TimeInterval = 30
	public var idleTimeout: TimeInterval = 180
	public var downloadLimit = 0
	public var uploadLimit = 0
	public var enableFast = true
	public var enableExtensions = true
	public var enablePEX = true
	public var preferV2 = true
	public var listenPort: UInt16 = 0
	public var dhtPort: UInt16 = 0
	public var encryption = PeerEncryptionConfiguration()
	public init() {}
	func validate() throws {
		guard (1...1000).contains(maximumPeers), (1...32).contains(pipeline), (1...32).contains(uploadSlots),
			requestTimeout.isFinite, (0.1...300).contains(requestTimeout), idleTimeout.isFinite, (1...600).contains(idleTimeout),
			(0...Int(Int32.max)).contains(downloadLimit), (0...Int(Int32.max)).contains(uploadLimit) else { throw PeerFailure.invalid("transfer limits") }
	}
}
public struct TCPPeerSnapshot: Sendable {
	public let id: UUID
	public let endpoint: NetworkEndpoint?
	public let client: String
	public let remoteInterested: Bool
	public let peerID: Data?
	public let remoteChoking: Bool
	public let choking: Bool
	public let pendingRequests: Int
	public let downloaded: Int64
	public let uploaded: Int64
	public let v2: Bool
	public let fast: Bool
	public let encryption: PeerEncryptionMode
	public let transport: PeerTransportKind
}
public struct TCPTransferSnapshot: Sendable {
	public let webSeeds: [WebSeedSnapshot]
	public let complete: Bool
	public let verifiedPieces: Set<Int>
	public let wantedPieces: Set<Int>
	public let pieceStates: [UInt8]
	public let peers: [TCPPeerSnapshot]
	public let downloaded: Int64
	public let uploaded: Int64
	public let corruptBytes: Int64
	public let redundantBytes: Int64
	public let corruptPieces: Int
	public let writingBlocks: Int
	public let lastPeerError: String?
	public let storageError: String?
	public let stopped: Bool
}

final class TransferPeer {
	let session: PeerSession
	var task: Task<Void, Never>?
	var peerID: Data?
	var closing = false
	var retryIdentityAfterClose = false
	var alternateHash: Data?
	var retryTransport: UTPTransport?
	var remoteChoking = true
	var choking = true
	var interested = false
	var remoteInterested = false
	var firstMessage = true
	var pending: Set<PeerBlock> = []
	var recent: [PeerBlock: TimeInterval] = [:]
	var uploads: [PeerBlock: UUID] = [:]
	var downloaded: Int64 = 0
	var uploaded: Int64 = 0
	var score = 0
	var timeouts = 0
	var retryAfter: TimeInterval = 0
	var lastSent: TimeInterval
	var window: TimeInterval
	var controls = 0
	var features = PeerFeatures()
	var outgoing = false
	var encryption: PeerEncryptionMode = .plaintext
	var extensions = ExtensionHandshake()
	var advertisedPort: UInt16?
	var availabilitySeen = false
	var allowedIncoming: Set<Int> = []
	var allowedOutgoing: Set<Int> = []
	var suggestions: Set<Int> = []
	var nextPEX: TimeInterval = 0
	var nextIncomingPEX: TimeInterval = 0
	var pexSent: Set<NetworkEndpoint> = []
	var pexReceived: Set<NetworkEndpoint> = []
	var metadataRequests = 0
	var metadataWindow: TimeInterval = 0
	var hashRequests: [MerkleHashRequest: TimeInterval] = [:]
	var hashRequestSize = 512
	let connectedAt: TimeInterval
	init(session: PeerSession, now: TimeInterval) { self.session = session; lastSent = now; window = now; connectedAt = now }
}

/// TCPTransfer runs v1, v2 and hybrid plaintext swarms against the native storage layer.
public actor TCPTransfer {
	let metadata: TorrentMetadata
	let storage: TorrentStorage
	let clock: any TransportClock
	var configuration: TCPTransferConfiguration
	let hello: PeerHandshake
	let budget: TCPPeerBudget
	let disk: TransferDiskScope
	let uploadRate: TransferRateLimiter
	let downloadRate: TransferRateLimiter
	let cache: VerifiedPieceCache
	var picker: PiecePicker
	var hashReady: Set<Int>
	var legacyRemaining: [Int: Int] = [:]
	var reconstructingLegacyFiles: Set<Int> = []
	var hashOwners: [MerkleHashRequest: UUID] = [:]
	public nonisolated let discoveredPeers: AsyncStream<ExchangedPeer>
	let discovery: AsyncStream<ExchangedPeer>.Continuation
	public nonisolated let discoveredNodes: AsyncStream<NetworkEndpoint>
	let nodeDiscovery: AsyncStream<NetworkEndpoint>.Continuation
	var peers: [UUID: TransferPeer] = [:]
	var openings: [UUID: Task<PeerStream, Error>] = [:]
	var openingEndpoints: [UUID: NetworkEndpoint] = [:]
	var disconnectingPeers = false
	var peerRevision = UUID()
	var identityRetries: [UUID: Task<Void, Never>] = [:]
	var uploadJobs: [UUID: (UUID, Task<Void, Never>)] = [:]
	var bannedIDs: Set<Data> = []
	var downloaded: Int64
	var uploaded: Int64
	var corruptPieces = 0
	var corruptBytes: Int64
	var redundantBytes: Int64
	var activePayloadBytes: [Int: Int64] = [:]
	/// The most recent peer failure, available without constructing a transfer snapshot.
	public private(set) var lastPeerError: String?
	var storageError: String?
	var stopping = false
	var stopped = false
	var ticker: Task<Void, Never>?
	var shutdownTask: (UUID, Task<Void, Error>)?
	var completionWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
	var completionCheckpoint: Task<Void, Error>?
	let hasExistingPayload: Bool
	var locallyChecked: PieceBitfield
	var localRecoveries: [Int: Task<Void, Never>] = [:]
	var webSeeds: [TransferWebSeed] = []
	var webTask: Task<Void, Never>?
	var webClient: WebSeedClient?
	var webAdmission: TransferPermits?
	var lastChoke: TimeInterval
	var rotation = 0
	private init(metadata: TorrentMetadata, storage: TorrentStorage, initial: StorageSnapshot, hashes: Set<Int>, configuration: TCPTransferConfiguration,
		peerID: Data, budget: TCPPeerBudget, resources: TransferResources, clock: any TransportClock) throws {
		self.metadata = metadata; self.storage = storage; self.configuration = configuration; self.budget = budget; self.clock = clock
		let hash = configuration.preferV2 ? metadata.hashes.v2.map { Data($0.prefix(20)) } ?? metadata.hashes.v1! : metadata.hashes.v1 ?? Data(metadata.hashes.v2!.prefix(20))
		var reserved = Data(repeating: 0, count: 8)
		if configuration.enableFast { reserved[7] |= 4 }; if configuration.enableExtensions { reserved[5] |= 16 }
		if metadata.hashes.v2 != nil && hash == metadata.hashes.v1 && configuration.preferV2 { reserved[7] |= 16 }
		if configuration.dhtPort > 0 && !metadata.inspection.private { reserved[7] |= 1 }
		hello = try PeerHandshake(infoHash: hash, peerID: peerID, reserved: reserved)
		let discoveries = AsyncStream<ExchangedPeer>.makeStream(bufferingPolicy: .bufferingNewest(256)); discoveredPeers = discoveries.stream; discovery = discoveries.continuation
		let nodes = AsyncStream<NetworkEndpoint>.makeStream(bufferingPolicy: .bufferingNewest(64)); discoveredNodes = nodes.stream; nodeDiscovery = nodes.continuation
		uploadRate = TransferRateLimiter(rate: configuration.uploadLimit, clock: clock); downloadRate = TransferRateLimiter(rate: configuration.downloadLimit, clock: clock)
		disk = TransferDiskScope(resources: resources); cache = VerifiedPieceCache(storage: storage, resources: resources)
		var offset: Int64 = 0, wanted: Set<Int> = []
		for file in storage.layout.files {
			if !file.pad, initial.selected[file.index], file.size > 0 {
				let first = Int(offset / metadata.pieceLength), last = Int((offset + file.size - 1) / metadata.pieceLength)
				wanted.formUnion(first...last)
			}
			offset += file.size
		}
		picker = PiecePicker(layout: storage.layout, wanted: wanted, completed: initial.verifiedPieces, lengths: storage.merkleIndex.pieces.mapValues(\.length))
		hasExistingPayload = initial.hasExistingPayload; locallyChecked = try PieceBitfield(count: storage.layout.pieceCount)
		hashReady = hashes
		downloaded = initial.downloaded; uploaded = initial.uploaded; corruptBytes = initial.corruptBytes; redundantBytes = initial.redundantBytes; lastChoke = clock.now()
	}
	public static func open(metadata: TorrentMetadata, storage: TorrentStorage, configuration: TCPTransferConfiguration = .init(),
		peerID: Data? = nil, budget: TCPPeerBudget? = nil, resources: TransferResources = .shared, clock: any TransportClock = ContinuousTransportClock(), webSeedClient: WebSeedClient? = nil) async throws -> TCPTransfer {
		try configuration.validate()
		guard storage.infoHashes == metadata.hashes else { throw PeerFailure.invalid("metadata/storage identity") }
		let initial = try await storage.snapshot()
		guard !initial.needsRecovery else { throw StorageFailure.recoveryRequired("recover files before starting a transfer") }
		let identity = peerID ?? Data("-BT0001-".utf8) + Data((0..<12).map { _ in UInt8.random(in: 0...255) })
		let hashes = try await storage.availableHashes()
		let transfer = try TCPTransfer(metadata: metadata, storage: storage, initial: initial, hashes: hashes, configuration: configuration,
			peerID: identity, budget: budget ?? TCPPeerBudget(limit: configuration.maximumPeers), resources: resources, clock: clock)
		try await transfer.flushInitialCompletion()
		await transfer.startTicker()
		await transfer.startWebSeeds(client: webSeedClient ?? WebSeedClient(transport: NetworkHTTPTransport(clock: clock, addressFilter: configuration.addressFilter), clock: clock, maximumBytes: 16384), admission: resources.web)
		return transfer
	}
	private func flushInitialCompletion() async throws { if picker.complete { try await storage.flush(retryFailed: false) } }
	func checkpointCompletion() {
		guard !stopping, picker.complete, completionCheckpoint == nil else { return }
		let storage = storage
		completionCheckpoint = Task { [weak self] in
			do { try await storage.flush(retryFailed: false) }
			catch { await self?.diskFailed(error); throw error }
		}
	}
	func startTicker() {
		let clock = clock, interval = min(1, configuration.requestTimeout / 2)
		ticker = Task { [weak self] in
			do { while !Task.isCancelled { try await clock.sleep(for: interval); guard let self else { return }; await self.tick() } } catch { }
		}
	}
	@discardableResult public func attach(_ stream: any PeerByteStream) throws -> UUID { try attach(stream, outgoing: false) }
	@discardableResult public func attach(_ channel: PeerStream) throws -> UUID {
		let mode = channel.mode, policy = configuration.encryption
		let hashes = [metadata.hashes.v1, metadata.hashes.v2.map { Data($0.prefix(20)) }].compactMap { $0 }
		guard !(policy.incoming == .required && mode == .plaintext), !(policy.incoming == .disabled && mode != .plaintext),
			mode != .rc4 || policy.levels.rawValue & 2 != 0,
			mode != .negotiatedPlaintext || policy.levels.rawValue & 1 != 0,
			channel.negotiatedInfoHash == nil || hashes.contains(channel.negotiatedInfoHash!) else { channel.close(); throw PeerFailure.invalid("routed encryption policy or swarm") }
		return try attach(channel.raw, outgoing: false, transport: channel)
	}
	@discardableResult func attach(_ stream: any PeerByteStream, outgoing: Bool, transport: PeerStream? = nil, offeredHello: PeerHandshake? = nil, alternateHash: Data? = nil, utp: UTPTransport? = nil) throws -> UUID {
		do { try Task.checkCancellation() } catch { stream.close(); throw error }
		guard !disconnectingPeers else { stream.close(); throw PeerFailure.closed }
		// libtorrent resolves crossed endpoint connections before reading peer IDs:
		// the lower listening port initiates. µTP preserves both listening ports.
		if !outgoing, let stream = stream as? UTPStream, let remote = stream.remoteEndpoint,
			stream.localEndpoint.port != remote.port {
			let existing = peers.filter { !$0.value.closing && $0.value.outgoing && $0.value.session.stream.kind == .utp && $0.value.session.stream.remoteEndpoint == remote }
			if stream.localEndpoint.port < remote.port, !existing.isEmpty || openingEndpoints.values.contains(remote) { stream.close(); throw PeerFailure.invalid("duplicate endpoint") }
			for (id, _) in existing { drop(id, error: PeerFailure.invalid("duplicate endpoint")) }
		}
		if let address = stream.remoteEndpoint?.address, !configuration.addressFilter.allows(address) { stream.close(); throw PeerFailure.invalid("blocked peer") }
		guard !stopping, storageError == nil, peers.count < configuration.maximumPeers else { stream.close(); throw PeerFailure.limit("active peers") }
		let id = UUID(), session = PeerSession(stream: stream, transport: transport), peer = TransferPeer(session: session, now: clock.now())
		peers[id] = peer
		peer.outgoing = outgoing
		peer.alternateHash = alternateHash; peer.retryTransport = utp
		let hello = offeredHello ?? hello, rate = uploadRate, download = downloadRate, timeout = configuration.idleTimeout, encryption = configuration.encryption, clock = clock
		let hashes = [metadata.hashes.v1, metadata.hashes.v2.map { Data($0.prefix(20)) }].compactMap { $0 }
		peer.task = Task { [weak self] in
			guard let self else { session.close(); return }
			var failure: Error?
			do { try await session.run(id: id, hello: hello, outgoing: outgoing, engine: self, upload: rate, download: download, idleTimeout: timeout, hashes: hashes, encryption: encryption, clock: clock) } catch { failure = error }
			try? await stream.shutdown()
			await self.ended(id, error: failure)
		}
		return id
	}
	@discardableResult func connect(to endpoint: NetworkEndpoint, utp: UTPTransport?, infoHash: Data, alternateHash: Data?) async throws -> UUID {
		try Task.checkCancellation()
		guard !disconnectingPeers else { throw PeerFailure.closed }
		guard configuration.addressFilter.allows(endpoint.address) else { throw PeerFailure.invalid("blocked peer") }
		if let existing = peers.first(where: { !$0.value.closing && $0.value.peerID != nil && $0.value.session.stream.remoteEndpoint == endpoint }) { return existing.key }
		guard !stopping, storageError == nil, peers.count + openings.count < configuration.maximumPeers else { throw PeerFailure.limit("active and connecting peers") }
		let offered = try handshake(for: infoHash)
		let id = UUID(), revision = peerRevision, budget = budget, clock = clock, encryption = configuration.encryption
		let task = Task { try await PeerStream.connect(to: endpoint, hash: infoHash, configuration: encryption, clock: clock, budget: budget, utp: utp) }; openings[id] = task; openingEndpoints[id] = endpoint
		defer { openings[id] = nil; openingEndpoints[id] = nil }
		do { return try await withTaskCancellationHandler {
			let stream = try await task.value
			do {
				try Task.checkCancellation()
				guard revision == peerRevision, !disconnectingPeers else { throw PeerFailure.closed }
				if let existing = peers.first(where: { !$0.value.closing && $0.value.session.stream.remoteEndpoint == endpoint }) { stream.close(); return existing.key }
				return try attach(stream.raw, outgoing: true, transport: stream, offeredHello: offered, alternateHash: alternateHash, utp: utp)
			} catch { stream.close(); throw error }
		} onCancel: { task.cancel() } }
		catch { if !stopping, !Task.isCancelled { lastPeerError = "\(endpoint): \(error.localizedDescription)" }; throw error }
	}
	func disconnectPeers() async {
		disconnectingPeers = true; peerRevision = UUID()
		let connecting = Array(openings.values), running = peers.values.compactMap(\.task), retrying = Array(identityRetries.values)
		for task in retrying { task.cancel() }
		for task in connecting { task.cancel() }
		for peer in peers.values { peer.closing = true; peer.session.close(); peer.task?.cancel() }
		for task in connecting { if let stream = try? await task.value { stream.close() } }
		for task in running { await task.value }
		for task in retrying { await task.value }
		disconnectingPeers = false
	}
	public func snapshot() -> TCPTransferSnapshot {
		TCPTransferSnapshot(webSeeds: webSeeds.map { $0.snapshot }, complete: picker.complete, verifiedPieces: picker.completed, wantedPieces: picker.wanted,
			pieceStates: (0..<storage.layout.pieceCount).map { picker.completed.contains($0) ? 1 : picker.active[$0] != nil || picker.staged.contains($0) ? 2 : peers.isEmpty ? 0 : picker.availability[$0] > 0 ? 3 : 4 },
			peers: peers.map { id, peer in TCPPeerSnapshot(id: id, endpoint: peer.session.stream.remoteEndpoint, client: peer.extensions.client, remoteInterested: peer.remoteInterested, peerID: peer.peerID, remoteChoking: peer.remoteChoking, choking: peer.choking,
				pendingRequests: peer.pending.count, downloaded: peer.downloaded, uploaded: peer.uploaded, v2: peer.features.v2, fast: peer.features.fast, encryption: peer.encryption, transport: peer.session.stream.kind) },
			downloaded: downloaded, uploaded: uploaded, corruptBytes: corruptBytes, redundantBytes: redundantBytes, corruptPieces: corruptPieces, writingBlocks: picker.active.values.reduce(0) { $0 + $1.writing.count }, lastPeerError: lastPeerError, storageError: storageError, stopped: stopped)
	}
	/// Waits for verified wanted pieces without constructing a transfer snapshot.
	/// Disconnecting a peer leaves the wait pending so another peer can finish it.
	public func waitUntilComplete() async throws {
		let id = UUID()
		try await withTaskCancellationHandler {
			try Task.checkCancellation()
			if let storageError { throw PeerFailure.invalid(storageError) }
			if picker.complete { return }
			guard !stopping else { throw PeerFailure.closed }
			guard completionWaiters.count < 1024 else { throw PeerFailure.limit("completion waiters") }
			try await withCheckedThrowingContinuation { continuation in
				completionWaiters[id] = continuation
			}
		} onCancel: {
			Task { await self.cancelCompletionWaiter(id) }
		}
	}
	private func cancelCompletionWaiter(_ id: UUID) {
		completionWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
	}
	func settleCompletionWaiters(_ error: Error? = nil) {
		guard error != nil || picker.complete else { return }
		let pending = completionWaiters; completionWaiters.removeAll()
		for waiter in pending.values {
			if let error { waiter.resume(throwing: error) } else { waiter.resume() }
		}
	}
	public func setLimits(download: Int, upload: Int) async throws {
		guard !stopping, (0...Int(Int32.max)).contains(download), (0...Int(Int32.max)).contains(upload) else { throw PeerFailure.invalid("rate limits or closed transfer") }
		configuration.downloadLimit = download; configuration.uploadLimit = upload
		await downloadRate.set(download); await uploadRate.set(upload)
	}
	/// Persists counters and verified progress after draining the completion checkpoint.
	public func checkpoint() async throws {
		if !stopping, let completionCheckpoint { try await completionCheckpoint.value }
		try await storage.checkpoint(downloaded: downloaded, uploaded: uploaded, corruptBytes: corruptBytes, redundantBytes: redundantBytes)
	}
	public func shutdown() async throws {
		if stopped { return }
		let entry: (UUID, Task<Void, Error>)
		if let current = shutdownTask { entry = current } else { entry = (UUID(), Task { try await self.finishShutdown() }); shutdownTask = entry }
		do { try await entry.1.value } catch { if shutdownTask?.0 == entry.0 { shutdownTask = nil }; throw error }
	}
	private func finishShutdown() async throws {
		stopping = true; ticker?.cancel(); webTask?.cancel()
		let completing = completionCheckpoint; completing?.cancel()
		settleCompletionWaiters(PeerFailure.closed)
		discovery.finish(); nodeDiscovery.finish()
		let connecting = Array(openings.values), running = peers.values.compactMap(\.task), uploads = uploadJobs.values.map(\.1), retrying = Array(identityRetries.values), recovering = Array(localRecoveries.values)
		for task in recovering { task.cancel() }
		for task in retrying { task.cancel() }
		for task in connecting { task.cancel() }
		for peer in peers.values { peer.closing = true; peer.session.close(); peer.task?.cancel() }
		for task in uploads { task.cancel() }
		await disk.close(); await cache.close()
		for task in connecting { if let stream = try? await task.value { stream.close() } }
		for task in running { await task.value }; for task in uploads { await task.value }
		for task in recovering { await task.value }
		_ = try? await completing?.value
		for task in retrying { await task.value }
		await webTask?.value; webTask = nil
		if let ticker { await ticker.value }; ticker = nil
		for bytes in activePayloadBytes.values { recordUnusablePayload(bytes) }; activePayloadBytes.removeAll()
		try await checkpoint(); stopped = true
	}
	func ended(_ id: UUID, error: Error?) async {
		guard let peer = peers.removeValue(forKey: id) else { return }
		let revision = peerRevision
		peer.session.close(); picker.remove(id); discardUnretainedPayload()
		for request in peer.hashRequests.keys where hashOwners[request] == id { hashOwners[request] = nil }
		let jobs = uploadJobs.values.filter { $0.0 == id }.map(\.1)
		for task in jobs { task.cancel() }; for task in jobs { await task.value }
		if !stopping, !peer.closing, let error, !(error is CancellationError) { lastPeerError = "\(peer.session.stream.remoteEndpoint?.description ?? "peer"): \(error.localizedDescription)" }
		if (!peer.closing && (error == nil || error.map { PeerStream.allowsIdentityRetry(after: $0) } == true)) || peer.retryIdentityAfterClose,
			peer.peerID == nil, let hash = peer.alternateHash, let endpoint = peer.session.stream.remoteEndpoint {
			retryIdentity(to: endpoint, hash: hash, utp: peer.retryTransport, revision: revision)
		}
		if !stopping { rechoke(); fillAll() }
	}
	func drop(_ id: UUID, error: Error, retryIdentity: Bool = false) {
		guard let peer = peers[id], !peer.closing else { return }
		peer.closing = true; peer.retryIdentityAfterClose = retryIdentity; lastPeerError = "\(peer.session.stream.remoteEndpoint?.description ?? "peer"): \(error.localizedDescription)"; peer.session.close(); peer.task?.cancel()
	}
	func diskFailed(_ error: Error) {
		guard !stopping, !(error is CancellationError), storageError == nil else { return }
		storageError = error.localizedDescription
		settleCompletionWaiters(error)
		webTask?.cancel()
		for id in peers.keys { drop(id, error: error) }
	}
}
