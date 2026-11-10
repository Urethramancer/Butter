import Foundation
import Testing
import ButterTorrentMetadata
import ButterTorrentNetworking
@testable import ButterTorrentEngine

@Suite struct UTPTransferTests {
	@Test(arguments: [1, 2, 3], [false, true]) func metadataAndTransfersWithoutTCP(_ version: Int, _ encrypted: Bool) async throws {
		let fixture = try V2Fixture(version: version)
		let seedSocket = try DatagramSocket(bind: NetworkEndpoint("127.0.0.1", port: 0)), downSocket = try DatagramSocket(bind: NetworkEndpoint("127.0.0.1", port: 0))
		let seedUDP = UDPDispatcher(transport: seedSocket), downUDP = UDPDispatcher(transport: downSocket)
		let seedUTP = try await UTPTransport.open(dispatcher: seedUDP), downUTP = try await UTPTransport.open(dispatcher: downUDP)
		let encryption = encrypted ? PeerEncryptionConfiguration(incoming: .required, outgoing: .required, levels: .rc4) : .disabled
		var serving: Task<Void, Error>?
		do {
			let seed = try await fixture.engine("seed", seed: true, encryption: encryption), down = try await fixture.engine("download", seed: false, sparse: true, encryption: encryption)
			let task = Task { for _ in 0..<2 { _ = try await seed.attach(seedUTP.accept(timeout: 10)) } }; serving = task
			let received = try await MetadataExchange(encryption: encryption, utp: downUTP).fetch(Magnet(hashes: fixture.metadata.hashes), peers: [seedSocket.localEndpoint], timeout: 10)
			#expect(received.originalInfo == fixture.metadata.originalInfo)
			_ = try await down.connect(to: seedSocket.localEndpoint, utp: downUTP); try await task.value
			try await eventually { await down.snapshot().complete }
			#expect(await down.snapshot().peers.contains { $0.transport == .utp && $0.encryption == (encrypted ? .rc4 : .plaintext) })
			#expect(try Data(contentsOf: fixture.root.appendingPathComponent("download/Bundle/b")) == Data(repeating: 17, count: 200003))
		} catch {
			serving?.cancel(); await fixture.close(); await seedUTP.shutdown(); await downUTP.shutdown(); try? await seedUDP.shutdown(); try? await downUDP.shutdown(); throw error
		}
		await fixture.close(); await seedUTP.shutdown(); await downUTP.shutdown(); try await seedUDP.shutdown(); try await downUDP.shutdown()
	}
}
