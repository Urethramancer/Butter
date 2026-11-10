import Foundation
import Darwin
import Testing
import ButterTorrentMetadata
import ButterTorrentNetworking
@testable import ButterTorrentEngine

extension NativeSessionTests { @Suite struct SessionPeerTests {
	@Test func bindingFailureRecoversAndUnchangedSettingsPreservePendingHandshakes() async throws {
		let fixture = try SessionPeerFixture()
		do {
			let seed = try await fixture.session("seed", seed: true, tcp: true), reserved = try await TCPListener.listen(address: IPAddress("127.0.0.1"))
			var settings = SessionPeerSettings(); settings.port = reserved.port; settings.maximumPeers = 5; settings.torrentPeers = 2
			do {
				await #expect(throws: (any Error).self) { try await seed.configurePeers(settings) }
				let failed = try await seed.snapshot(); #expect(failed.network.port == 0 && !failed.network.udp && !failed.network.error.isEmpty)
				#expect(failed.transfers.allSatisfy { $0.state.running })
				try await reserved.shutdown()
			} catch { try? await reserved.shutdown(); throw error }
			#expect(try await seed.configurePeers(settings) == settings.port)
			settings.maximumPeers = 5000; settings.torrentPeers = 1000
			_ = try await seed.configurePeers(settings)
			let raw = try await TCPStream.connect(to: NetworkEndpoint("127.0.0.1", port: settings.port)); defer { raw.close() }
			try await raw.write(Data([19])); try await eventually { try await seed.snapshot().network.pendingHandshakes == 1 }
			_ = try await seed.configurePeers(settings)
			#expect(try await seed.snapshot().network.pendingHandshakes == 1)
			try await seed.close(); #expect(try await raw.read(timeout: 3).isEmpty)
		} catch { await fixture.close(); throw error }; await fixture.close()
	}
	@Test func unknownPlaintextSwarmIsRejectedBeforeAttachingToAnyTransfer() async throws {
		let fixture = try SessionPeerFixture()
		do {
			let seed = try await fixture.session("seed", seed: true, tcp: true), port = try await seed.snapshot().network.port
			let raw = try await TCPStream.connect(to: NetworkEndpoint("127.0.0.1", port: port)); defer { raw.close() }
			try await raw.write(PeerHandshake(infoHash: Data(repeating: 99, count: 20), peerID: Data(repeating: 8, count: 20)).encoded)
			#expect(try await raw.read(timeout: 3).isEmpty)
			try await eventually { let state = try await seed.snapshot(); return state.network.peers == 0 && state.network.pendingHandshakes == 0 }
			#expect(try await seed.snapshot().transfers.allSatisfy { $0.state.transfer?.peers.isEmpty == true })
		} catch { await fixture.close(); throw error }; await fixture.close()
	}
	@Test func threeSwarmsRouteAcrossBothFamiliesAndEncryptedTransports() async throws {
		for tcp in [true, false] { for encrypted in [false, true] { for host in ["127.0.0.1", "::1"] {
			let fixture = try SessionPeerFixture()
			do {
				let encryption = encrypted ? PeerEncryptionConfiguration(incoming: .required, outgoing: .required, levels: .rc4) : .disabled
				let seed = try await fixture.session("seed", seed: true, tcp: tcp, encryption: encryption), down = try await fixture.session("down", seed: false, tcp: tcp, encryption: encryption)
				let port = try await seed.snapshot().network.port
				for version in 1...3 { _ = try await down.connect(id: "v\(version)", to: NetworkEndpoint(host, port: port)) }
				try await eventually { try await down.snapshot().transfers.allSatisfy { $0.state.transfer?.complete == true } }
				let snapshot = try await down.snapshot(), source = try await seed.snapshot()
				#expect(source.network.peers == 3 && snapshot.network.peers == 3)
				for version in 1...3 {
					let transfer = snapshot.transfers[version - 1], peer = try #require(transfer.state.transfer?.peers.first { $0.peerID != nil })
					#expect(peer.transport == (tcp ? .tcp : .utp) && peer.encryption == (encrypted ? .rc4 : .plaintext))
					#expect(peer.peerID == seed.peerID)
					for file in transfer.metadata.inspection.files where !file.pad {
						let original = fixture.variants[version - 1].root.appendingPathComponent("source").appendingPathComponent(file.path)
						#expect(try Data(contentsOf: transfer.state.storage.destination.appendingPathComponent(file.path)) == Data(contentsOf: original))
					}
				}
			} catch { await fixture.close(); throw error }; await fixture.close()
		} } }
	}
	@Test func pauseDrainsUnidentifiedConnectionsAndGlobalBudgetIncludesOutgoingOpens() async throws {
		let fixture = try SessionPeerFixture()
		do {
			let seed = try await fixture.session("seed", seed: true, tcp: true, maximum: 1)
			let endpoint = try await NetworkEndpoint("127.0.0.1", port: seed.snapshot().network.port)
			let raw = try await TCPStream.connect(to: endpoint); defer { raw.close() }; try await raw.write(Data([19]))
			try await eventually { try await seed.snapshot().network.pendingHandshakes == 1 }
			for _ in 0..<5 { try await seed.run(id: "v1", running: true) }
			#expect(try await seed.snapshot().network.pendingHandshakes == 1)
			let other = try await TCPListener.listen(address: IPAddress("127.0.0.1"))
			do {
				await #expect(throws: NetworkFailure.self) { try await seed.connect(id: "v1", to: NetworkEndpoint("127.0.0.1", port: other.port)) }
				await #expect(throws: NetworkFailure.timedOut) { try await other.accept(timeout: 0.1) }
				try await other.shutdown()
			} catch { try? await other.shutdown(); throw error }
			try await seed.pause(id: "v1")
			#expect(try await raw.read(timeout: 3).isEmpty)
			let state = try await seed.snapshot(); #expect(state.network.pendingHandshakes == 0 && state.network.peers == 0)
		} catch { await fixture.close(); throw error }; await fixture.close()
	}
	@Test func encryptedSwarmCannotSwitchToAnotherRegisteredHandshakeIdentity() async throws {
		let fixture = try SessionPeerFixture()
		do {
			let encryption = PeerEncryptionConfiguration(incoming: .required, outgoing: .required, levels: .rc4)
			let seed = try await fixture.session("seed", seed: true, tcp: true, encryption: encryption)
			let endpoint = try await NetworkEndpoint("127.0.0.1", port: seed.snapshot().network.port)
			let channel = try await PeerStream.connect(to: endpoint, hash: fixture.variants[0].metadata.hashes.v1!, configuration: encryption); defer { channel.close() }
			try await channel.write(PeerHandshake(infoHash: Data(fixture.variants[1].metadata.hashes.v2!.prefix(20)), peerID: Data(repeating: 44, count: 20)).encoded)
			do { #expect(try await channel.read(timeout: 3).isEmpty) }
			catch { #expect(error as? NetworkFailure == .closed || (error as NSError).code == Int(ECONNRESET)) }
			try await eventually { let state = try await seed.snapshot(); return state.network.pendingHandshakes == 0 && state.network.peers == 0 }
			#expect(try await seed.snapshot().transfers.allSatisfy { $0.state.transfer?.peers.isEmpty == true })
		} catch { await fixture.close(); throw error }; await fixture.close()
	}
	@Test func changingBlocklistsDrainsBlockedPeersAndRejectsOutgoingTraffic() async throws {
		let fixture = try SessionPeerFixture()
		do {
			let seed = try await fixture.session("seed", seed: true, tcp: true), down = try await fixture.session("down", seed: false, tcp: true)
			let endpoint = try await NetworkEndpoint("127.0.0.1", port: seed.snapshot().network.port)
			_ = try await down.connect(id: "v1", to: endpoint)
			try await eventually { try await down.snapshot().transfers[0].state.transfer?.complete == true }
			try await seed.setBlocklist([PeerAddressRange(first: IPAddress("127.0.0.1"), last: IPAddress("127.0.0.1"))])
			#expect(try await seed.snapshot().network.peers == 0)
			await #expect(throws: PeerFailure.invalid("blocked peer")) { try await seed.connect(id: "v1", to: NetworkEndpoint("127.0.0.1", port: down.snapshot().network.port)) }
			try await eventually { try await down.snapshot().transfers[0].state.transfer?.peers.isEmpty == true }
			try await seed.setBlocklist([]); _ = try await down.connect(id: "v1", to: endpoint)
			try await eventually { try await seed.snapshot().transfers[0].state.transfer?.peers.contains { $0.peerID == down.peerID } == true }
		} catch { await fixture.close(); throw error }; await fixture.close()
	}
}

}

private final class SessionPeerFixture {
	let variants: [V2Fixture]
	private var sessions: [TorrentSession] = []
	init() throws {
		variants = try [1, 2, 3].map { try V2Fixture(version: $0) }
		for fixture in variants { try fixture.metadata.document.original.write(to: fixture.root.appendingPathComponent("input.torrent")) }
	}
	func session(_ name: String, seed: Bool, tcp: Bool, maximum: Int = 8, encryption: PeerEncryptionConfiguration = .disabled) async throws -> TorrentSession {
		var config = plainTransferConfiguration(); config.encryption = encryption
		let session = TorrentSession(storage: variants[0].root.appendingPathComponent(name + "-library"), configuration: config, loopbackOnly: true); sessions.append(session)
		var settings = SessionPeerSettings(); settings.tcp = tcp; settings.utp = !tcp; settings.maximumPeers = maximum; settings.torrentPeers = maximum
		_ = try await session.configurePeers(settings)
		for (index, fixture) in variants.enumerated() {
			_ = try await session.add(id: "v\(index + 1)", source: fixture.root.appendingPathComponent("input.torrent"), destination: fixture.root.appendingPathComponent(seed ? "source" : name + "-data"))
			try await session.run(id: "v\(index + 1)", running: true)
		}
		return session
	}
	func close() async { for session in sessions { try? await session.close() }; for fixture in variants { await fixture.close() } }
}
