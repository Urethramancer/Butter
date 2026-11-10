import Foundation
import ButterTorrentNetworking

enum ManagedDiscoveryHint: Sendable { case peer(ExchangedPeer), node(NetworkEndpoint) }
struct ManagedDiscoveryNotice: Sendable {
	let revision: UUID
	let hint: ManagedDiscoveryHint
}

struct SessionPeerHint: Hashable, Sendable {
	let id: String
	let owner: ManagedTransfer
	let revision: UUID
	let endpoint: NetworkEndpoint
	let flags: UInt8
	static func == (a: Self, b: Self) -> Bool { a.id == b.id && a.owner === b.owner && a.revision == b.revision && a.endpoint == b.endpoint && a.flags == b.flags }
	func hash(into hasher: inout Hasher) { hasher.combine(id); hasher.combine(ObjectIdentifier(owner)); hasher.combine(revision); hasher.combine(endpoint); hasher.combine(flags) }
}

extension ManagedTransfer {
	func setDiscoveryHandler(_ handler: @escaping @Sendable (ManagedDiscoveryNotice) async -> Void) { discoveryHandler = handler }
	func acceptsDiscovery(_ revision: UUID) -> Bool { !closed && !pauseFailed && transfer != nil && discoveryRevision == revision && !metadata.inspection.private }
	func connectDiscovered(to endpoint: NetworkEndpoint, revision: UUID, utp: UTPTransport?) async throws -> UUID {
		guard acceptsDiscovery(revision), let transfer else { throw PeerFailure.closed }
		return try await transfer.connect(to: endpoint, utp: utp)
	}
	func startDiscovery(_ transfer: TCPTransfer) {
		discoveryRevision = UUID(); let revision = discoveryRevision
		guard discoveryHandler != nil, !metadata.inspection.private else { return }
		let peers = transfer.discoveredPeers, nodes = transfer.discoveredNodes
		discoveryPumps = [
			Task { [weak self] in for await peer in peers { guard !Task.isCancelled else { return }; await self?.emitDiscovery(.peer(peer), revision: revision) } },
			Task { [weak self] in for await node in nodes { guard !Task.isCancelled else { return }; await self?.emitDiscovery(.node(node), revision: revision) } }
		]
	}
	private func emitDiscovery(_ hint: ManagedDiscoveryHint, revision: UUID) async {
		guard acceptsDiscovery(revision), !Task.isCancelled else { return }
		await discoveryHandler?(ManagedDiscoveryNotice(revision: revision, hint: hint))
	}
	func stopDiscovery() async {
		discoveryRevision = UUID(); let active = discoveryPumps; discoveryPumps.removeAll()
		for task in active { task.cancel() }; for task in active { await task.value }
	}
}
