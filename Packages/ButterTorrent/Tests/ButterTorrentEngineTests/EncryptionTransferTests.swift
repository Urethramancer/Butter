import Foundation
import Testing
import ButterTorrentMetadata
import ButterTorrentNetworking
@testable import ButterTorrentEngine

@Suite struct EncryptionTransferTests {
	@Test func magnetResolutionRetainsRequiredRC4Policy() async throws {
		let fixture = try V2Fixture(version: 3), registry = TorrentIdentityRegistry()
		var config = TCPTransferConfiguration(); config.encryption = .init(incoming: .required, outgoing: .required, levels: .rc4)
		let download = MagnetDownload(magnet: Magnet(hashes: fixture.metadata.hashes), destination: fixture.root.appendingPathComponent("download"), stateDirectory: fixture.root.appendingPathComponent("state"), registry: registry, configuration: config)
		do {
			let seed = try await fixture.engine("seed", seed: true, encryption: config.encryption), (endpoint, serving) = try await fixture.provider(seed, count: 2)
			guard case .ready(_, let engine, _) = try await download.resolve(peers: [endpoint]) else { throw PeerFailure.invalid("unexpected duplicate") }
			try await serving.value; try await eventually { await engine.snapshot().complete }
			#expect(await engine.snapshot().peers.contains { $0.encryption == .rc4 })
			try await download.shutdown()
		} catch { try? await download.shutdown(); await fixture.close(); throw error }; await fixture.close()
	}
	@Test(arguments: [1, 2, 3]) func encryptedMetadataAndTransfers(_ version: Int) async throws {
		let fixture = try V2Fixture(version: version)
		do {
			let encryption = PeerEncryptionConfiguration(incoming: .required, outgoing: .required, levels: .rc4)
			let seed = try await fixture.engine("seed", seed: true, encryption: encryption), down = try await fixture.engine("download", seed: false, sparse: true, encryption: encryption)
			let (endpoint, serving) = try await fixture.provider(seed, count: version == 1 ? 1 : 2)
			if version > 1 {
				let info = try await MetadataExchange(encryption: encryption).fetch(Magnet(hashes: fixture.metadata.hashes), peers: [endpoint], timeout: 15)
				#expect(info.originalInfo == fixture.metadata.originalInfo)
			}
			_ = try await down.connect(to: endpoint); try await serving.value
			try await eventually { await down.snapshot().complete }
			#expect(await down.snapshot().peers.allSatisfy { $0.encryption == .rc4 })
			#expect(await seed.snapshot().peers.filter { $0.peerID != nil }.allSatisfy { $0.encryption == .rc4 })
		} catch { await fixture.close(); throw error }; await fixture.close()
	}
	@Test func shutdownCancelsAnOutgoingEncryptionHandshake() async throws {
		try await transferFixture { fixture in
			var config = TCPTransferConfiguration(); config.encryption.outgoing = .required
			let engine = try await fixture.transfer("download", configuration: config), listener = try await fixture.listen()
			let opening = Task { try await engine.connect(to: NetworkEndpoint("127.0.0.1", port: listener.port)) }
			let peer = try await listener.accept(timeout: 3); defer { peer.close() }
			_ = try await peer.read()
			try await engine.shutdown()
			await #expect(throws: CancellationError.self) { try await opening.value }
			#expect(await engine.snapshot().stopped)
		}
	}
}
