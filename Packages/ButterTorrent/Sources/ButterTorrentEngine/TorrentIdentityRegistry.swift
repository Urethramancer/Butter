import Foundation
import ButterTorrentMetadata

/// TorrentIdentityRegistry aliases v1/v2 identities only after the complete info dictionary verifies.
public actor TorrentIdentityRegistry {
	private var aliases: [Data: UUID] = [:]
	private var digests: [UUID: Data] = [:]
	private var confirmed: Set<UUID> = []
	var waiters: [UUID: (UUID, CheckedContinuation<Void, Error>)] = [:]
	public init() {}
	/// Reserves an identity, waiting for an earlier owner to publish or abandon its transfer.
	public func claim(_ metadata: TorrentMetadata, owner: UUID) async throws -> UUID {
		while true {
			try Task.checkCancellation()
			let winner = try reserve(metadata, owner: owner)
			if winner == owner || confirmed.contains(winner) { return winner }
			guard waiters.count < 128 else { throw PeerFailure.limit("identity publication waiters") }
			let token = UUID()
			try await withTaskCancellationHandler {
				try Task.checkCancellation()
				try await withCheckedThrowingContinuation { continuation in waiters[token] = (winner, continuation) }
			} onCancel: { Task { await self.cancel(token) } }
		}
	}
	private func reserve(_ metadata: TorrentMetadata, owner: UUID) throws -> UUID {
		let keys = [metadata.hashes.v1, metadata.hashes.v2].compactMap { $0 }
		let owners = Set(keys.compactMap { aliases[$0] })
		guard owners.count <= 1 else { throw PeerFailure.invalid("conflicting verified identity owners") }
		let winner = owners.first ?? owner
		let digest = TorrentHasher.hash(metadata.originalInfo).sha256
		guard digests[winner] == nil || digests[winner] == digest else { throw PeerFailure.invalid("conflicting verified metadata") }
		guard aliases.count + keys.filter({ aliases[$0] == nil }).count <= 20_000 else { throw PeerFailure.limit("registered swarm identities") }
		for key in keys { aliases[key] = winner }; digests[winner] = digest; return winner
	}
	/// Confirms a reservation only after the owning transfer has opened successfully.
	public func confirm(_ owner: UUID) throws {
		guard digests[owner] != nil else { throw PeerFailure.invalid("missing identity reservation") }
		confirmed.insert(owner); wake(owner)
	}
	private func cancel(_ token: UUID) { waiters.removeValue(forKey: token)?.1.resume(throwing: CancellationError()) }
	private func wake(_ owner: UUID) {
		let ready = waiters.filter { $0.value.0 == owner }
		for token in ready.keys { waiters[token] = nil }
		for entry in ready.values { entry.1.resume() }
	}
	public func release(_ owner: UUID) {
		aliases = aliases.filter { $0.value != owner }; digests[owner] = nil; confirmed.remove(owner); wake(owner)
	}
	public func owner(of hashes: InfoHashes) -> UUID? {
		let owners = Set([hashes.v1, hashes.v2].compactMap { $0 }.compactMap { aliases[$0] }.filter { confirmed.contains($0) }); return owners.count == 1 ? owners.first : nil
	}
}
