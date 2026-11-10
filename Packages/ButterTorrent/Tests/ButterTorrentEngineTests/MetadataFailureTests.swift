import Foundation
import Testing
import ButterTorrentMetadata
import ButterTorrentNetworking
@testable import ButterTorrentEngine

private enum MetadataBehaviour: String, CaseIterable { case good, corrupt, wrongTotal, unsolicited, resized, silent }

private func metadataProvider(_ fixture: V2Fixture, behaviour: MetadataBehaviour) async throws -> (NetworkEndpoint, Task<Void, Error>) {
	let listener = try await TCPListener.listen(address: IPAddress("127.0.0.1")); fixture.listeners.append(listener)
	let metadata = fixture.metadata
	let work = Task {
		let stream = try await listener.accept(timeout: 3); defer { stream.close() }
		if behaviour == .silent { while !(try await stream.read(timeout: 3)).isEmpty {} ; return }
		let peer = WirePeer(stream: stream); var flags = Data(repeating: 0, count: 8); flags[5] = 16
		let hash = metadata.hashes.v2.map { Data($0.prefix(20)) } ?? metadata.hashes.v1!
		try await peer.hello(hash: hash, identity: 77, reserved: flags)
		func handshake(_ size: Int) throws -> PeerMessage { .extended(0, try extensionDictionary(["m": extensionDictionary(["ut_metadata": .integer(3)]), "metadata_size": .integer(Int64(size))]).encoded()) }
		try await peer.send(handshake(metadata.originalInfo.count))
		while true {
			if case .extended(3, let bytes) = try await peer.next() {
				let request = try BencodeDocument(bytes).root
				guard request["msg_type"]?.integer == 0, let piece = request["piece"]?.integer else { continue }
				if behaviour == .resized { try await peer.send(handshake(metadata.originalInfo.count + 1)); return }
				// Unknown metadata message types must be ignored even without a piece field.
				try await peer.send(.extended(1, extensionDictionary(["msg_type": .integer(99)]).encoded()))
				var info = metadata.originalInfo
				if behaviour == .corrupt { info[0] ^= 1 }
				let number = behaviour == .unsolicited ? piece + 1 : piece
				let total = info.count + (behaviour == .wrongTotal ? 1 : 0)
				let header = extensionDictionary(["msg_type": .integer(1), "piece": .integer(number), "total_size": .integer(Int64(total))])
				try await peer.send(.extended(1, header.encoded() + info)); return
			}
		}
	}
	return (try NetworkEndpoint("127.0.0.1", port: listener.port), work)
}

@Suite struct MetadataFailureTests {
	@Test(arguments: ["corrupt", "wrongTotal", "unsolicited", "resized"]) func rejectsMalformedOrUnauthenticatedMetadata(_ name: String) async throws {
		let fixture = try V2Fixture(version: 3)
		do {
			let (endpoint, provider) = try await metadataProvider(fixture, behaviour: MetadataBehaviour(rawValue: name)!)
			do { _ = try await MetadataExchange(encryption: .disabled).fetch(Magnet(hashes: fixture.metadata.hashes), peers: [endpoint], timeout: 3); Issue.record("Invalid metadata was accepted: \(name)") } catch {}
			try await provider.value
		} catch { await fixture.close(); throw error }; await fixture.close()
	}
	@Test func successfulProviderCancelsStalledAndCorruptCompetitors() async throws {
		let fixture = try V2Fixture(version: 2)
		do {
			let (bad, badWork) = try await metadataProvider(fixture, behaviour: .corrupt), (silent, silentWork) = try await metadataProvider(fixture, behaviour: .silent), (good, goodWork) = try await metadataProvider(fixture, behaviour: .good)
			let metadata = try await MetadataExchange(encryption: .disabled).fetch(Magnet(hashes: fixture.metadata.hashes), peers: [bad, silent, good], timeout: 3)
			#expect(metadata.originalInfo == fixture.metadata.originalInfo)
			// Competing providers may see cancellation before their response is written.
			_ = try? await badWork.value; try await goodWork.value; try await silentWork.value
		} catch { await fixture.close(); throw error }; await fixture.close()
	}
	@Test func privateMetadataArrivalNeverReconnectsUntrustedHints() async throws {
		let fixture = try V2Fixture(version: 3, isPrivate: true), registry = TorrentIdentityRegistry()
		let download = MagnetDownload(magnet: Magnet(hashes: fixture.metadata.hashes), destination: fixture.root.appendingPathComponent("download"), stateDirectory: fixture.root.appendingPathComponent("state"), registry: registry, exchange: MetadataExchange(encryption: .disabled))
		do {
			let (endpoint, provider) = try await metadataProvider(fixture, behaviour: .good)
			guard case .ready(let metadata, let engine, _) = try await download.resolve(peers: [endpoint]) else { throw PeerFailure.invalid("unexpected duplicate") }
			try await provider.value
			#expect(metadata.inspection.private)
			#expect(await !download.discoveryAllowed)
			#expect(await engine.snapshot().peers.isEmpty)
			#expect(await engine.snapshot().verifiedPieces.isEmpty)
			try await download.shutdown()
		} catch { try? await download.shutdown(); await fixture.close(); throw error }; await fixture.close()
	}
}
