import Foundation
import ButterTorrentNetworking

extension TCPTransfer {
	@discardableResult public func connect(to endpoint: NetworkEndpoint, utp: UTPTransport? = nil) async throws -> UUID {
		let primary = hello.infoHash, alternate = alternateIdentity(to: primary), revision = peerRevision
		do { return try await connect(to: endpoint, utp: utp, infoHash: primary, alternateHash: alternate) }
		catch {
			guard let alternate, !Task.isCancelled, !stopping, !disconnectingPeers, storageError == nil,
				revision == peerRevision, PeerStream.allowsIdentityRetry(after: error) else { throw error }
			return try await connect(to: endpoint, utp: utp, infoHash: alternate, alternateHash: nil)
		}
	}
	private func alternateIdentity(to hash: Data) -> Data? {
		guard let v1 = metadata.hashes.v1, let full = metadata.hashes.v2 else { return nil }
		let v2 = Data(full.prefix(20)); guard v1 != v2 else { return nil }
		return hash == v1 ? v2 : hash == v2 ? v1 : nil
	}
	func handshake(for hash: Data) throws -> PeerHandshake {
		var reserved = hello.reserved
		if configuration.preferV2 && metadata.hashes.v2 != nil && hash == metadata.hashes.v1 { reserved[7] |= 16 }
		else { reserved[7] &= ~16 }
		return try PeerHandshake(infoHash: hash, peerID: hello.peerID, reserved: reserved)
	}
	func retryIdentity(to endpoint: NetworkEndpoint, hash: Data, utp: UTPTransport?, revision: UUID) {
		guard !stopping, !disconnectingPeers, storageError == nil, revision == peerRevision else { return }
		let id = UUID()
		identityRetries[id] = Task { [weak self] in await self?.runIdentityRetry(id, to: endpoint, hash: hash, utp: utp, revision: revision) }
	}
	private func runIdentityRetry(_ id: UUID, to endpoint: NetworkEndpoint, hash: Data, utp: UTPTransport?, revision: UUID) async {
		defer { identityRetries[id] = nil }
		guard !Task.isCancelled, !stopping, !disconnectingPeers, revision == peerRevision else { return }
		_ = try? await connect(to: endpoint, utp: utp, infoHash: hash, alternateHash: nil)
	}
}
