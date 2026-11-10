import Foundation
import ButterTorrentMetadata
import ButterTorrentNetworking
import ButterTorrentStorage

public enum MagnetResolution: Sendable {
	case ready(TorrentMetadata, TCPTransfer, TorrentStorage)
	case duplicate(UUID)
}

/// MagnetDownload owns resolution, identity registration and its resulting native transfer.
public actor MagnetDownload {
	public nonisolated let id: UUID
	public nonisolated let magnet: Magnet
	private let destination: URL
	private let stateDirectory: URL
	private let registry: TorrentIdentityRegistry
	private let exchange: MetadataExchange
	private var current: (UUID, Task<MagnetResolution, Error>)?
	private var result: MagnetResolution?
	private var closed = false
	private var stopped = false
	private var stopTask: (UUID, Task<Void, Error>)?
	public private(set) var connectionFailures: [NetworkEndpoint: String] = [:]
	public init(magnet: Magnet, destination: URL, stateDirectory: URL, registry: TorrentIdentityRegistry,
		id: UUID = UUID(), exchange: MetadataExchange = MetadataExchange()) {
		self.magnet = magnet; self.destination = destination; self.stateDirectory = stateDirectory; self.registry = registry; self.id = id; self.exchange = exchange
	}
	public var discoveryAllowed: Bool { if case .ready(let metadata, _, _) = result { return !metadata.inspection.private && !closed }; return false }
	public func resolve(peers: [NetworkEndpoint]) async throws -> MagnetResolution {
		guard !closed else { throw PeerFailure.closed }
		if let result { return result }
		let entry: (UUID, Task<MagnetResolution, Error>)
		if let current { entry = current } else { entry = (UUID(), Task { try await self.open(peers: peers) }); current = entry }
		return try await withTaskCancellationHandler {
			do { return try await entry.1.value } catch { if current?.0 == entry.0 { current = nil }; throw error }
		} onCancel: { entry.1.cancel() }
	}
	private func open(peers: [NetworkEndpoint]) async throws -> MagnetResolution {
		let metadata = try await exchange.fetch(magnet, peers: peers)
		try Task.checkCancellation(); guard !closed else { throw PeerFailure.closed }
		let owner = try await registry.claim(metadata, owner: id)
		if owner != id { let duplicate = MagnetResolution.duplicate(owner); result = duplicate; return duplicate }
		var storage: TorrentStorage?, engine: TCPTransfer?
		do {
			try Task.checkCancellation()
			let disk = try await TorrentStorage.open(metadata: metadata, destination: destination, stateDirectory: stateDirectory); storage = disk
			let transfer = try await TCPTransfer.open(metadata: metadata, storage: disk); engine = transfer
			for endpoint in peers.prefix(8) {
				try Task.checkCancellation()
				do { _ = try await transfer.connect(to: endpoint) } catch {
					if Task.isCancelled { throw CancellationError() }
					connectionFailures[endpoint] = String(describing: error)
				}
			}
			try Task.checkCancellation(); guard !closed else { throw PeerFailure.closed }
			let ready = MagnetResolution.ready(metadata, transfer, disk); result = ready; return ready
		} catch {
			let cleanup = Task { if let engine { try? await engine.shutdown() }; if let storage { try? await storage.shutdown() } }
			await cleanup.value; await registry.release(id); throw error
		}
	}
	public func shutdown() async throws {
		if stopped { return }
		let entry: (UUID, Task<Void, Error>)
		if let stopTask { entry = stopTask } else { entry = (UUID(), Task { try await self.finish() }); stopTask = entry }
		do { try await entry.1.value } catch { if stopTask?.0 == entry.0 { stopTask = nil }; throw error }
	}
	private func finish() async throws {
		closed = true; current?.1.cancel(); _ = try? await current?.1.value
		if case .ready(_, let engine, let storage) = result { try await engine.shutdown(); try await storage.shutdown() }
		await registry.release(id); stopped = true
	}
}
