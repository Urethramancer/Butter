import Foundation
import ButterTorrentMetadata

/// TorrentIdentityRegistry aliases v1/v2 identities only after the complete info dictionary verifies.
public actor TorrentIdentityRegistry {
	private var aliases: [Data: UUID] = [:]
	private var digests: [UUID: Data] = [:]
	public init() {}
	public func claim(_ metadata: TorrentMetadata, owner: UUID) throws -> UUID {
		let keys = [metadata.hashes.v1, metadata.hashes.v2].compactMap { $0 }
		let owners = Set(keys.compactMap { aliases[$0] })
		guard owners.count <= 1 else { throw PeerFailure.invalid("conflicting verified identity owners") }
		let winner = owners.first ?? owner
		let digest = TorrentHasher.hash(metadata.originalInfo).sha256
		guard digests[winner] == nil || digests[winner] == digest else { throw PeerFailure.invalid("conflicting verified metadata") }
		guard aliases.count + keys.filter({ aliases[$0] == nil }).count <= 20_000 else { throw PeerFailure.limit("registered swarm identities") }
		for key in keys { aliases[key] = winner }; digests[winner] = digest; return winner
	}
	public func release(_ owner: UUID) { aliases = aliases.filter { $0.value != owner }; digests[owner] = nil }
	public func owner(of hashes: InfoHashes) -> UUID? {
		let owners = Set([hashes.v1, hashes.v2].compactMap { $0 }.compactMap { aliases[$0] }); return owners.count == 1 ? owners.first : nil
	}
}
