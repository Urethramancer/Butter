import Foundation
import Testing
import ButterTorrentNetworking
@testable import ButterTorrentEngine

/// Uses actual listeners: accepting only the v1 swarm must also work before MSE completes.
private final class IdentityListener: Sendable {
	let endpoint: NetworkEndpoint
	let tcp: TCPListener?
	let incoming: UTPTransport?
	let outgoing: UTPTransport?
	let dispatchers: [UDPDispatcher]
	init(utp: Bool) async throws {
		if utp {
			let left = UDPDispatcher(transport: try DatagramSocket(bind: NetworkEndpoint("127.0.0.1", port: 0)))
			let right = UDPDispatcher(transport: try DatagramSocket(bind: NetworkEndpoint("127.0.0.1", port: 0)))
			dispatchers = [left, right]; tcp = nil
			incoming = try await UTPTransport.open(dispatcher: left); outgoing = try await UTPTransport.open(dispatcher: right)
			endpoint = incoming!.localEndpoint
		} else {
			let listener = try await TCPListener.listen(address: IPAddress("127.0.0.1"))
			tcp = listener; endpoint = try NetworkEndpoint("127.0.0.1", port: listener.port)
			incoming = nil; outgoing = nil; dispatchers = []
		}
	}
	func accept(timeout: TimeInterval = 5) async throws -> any PeerByteStream {
		if let tcp { return try await tcp.accept(timeout: timeout) }
		return try await incoming!.accept(timeout: timeout)
	}
	func close() async {
		try? await tcp?.shutdown(); await incoming?.shutdown(); await outgoing?.shutdown()
		for dispatcher in dispatchers { try? await dispatcher.shutdown() }
	}
}

@Suite struct IdentityFallbackTests {
	@Test(arguments: [false, true], [false, true]) func legacyOnlyHybridPeer(_ utp: Bool, _ encrypted: Bool) async throws {
		let fixture = try V2Fixture(version: 3), listener = try await IdentityListener(utp: utp)
		let policy: PeerEncryptionConfiguration = encrypted ? .init(incoming: .required, outgoing: .required, levels: .rc4) : .disabled
		var opening: Task<UUID, Error>?
		do {
			let seed = try await fixture.engine("seed", seed: true, preferV2: false, encryption: policy)
			let down = try await fixture.engine("download", seed: false, encryption: policy)
			let task = Task { try await down.connect(to: listener.endpoint, utp: listener.outgoing) }; opening = task
			let rejected = try await listener.accept()
			if encrypted {
				await #expect(throws: (any Error).self) {
					try await PeerStream.accept(rejected, hashes: [fixture.metadata.hashes.v1!], configuration: policy)
				}
			} else {
				var decoder = PeerWireDecoder()
				while true {
					try decoder.feed(await rejected.read(timeout: 3))
					if let hello = try decoder.handshake() {
						#expect(hello.infoHash == Data(fixture.metadata.hashes.v2!.prefix(20))); break
					}
				}
				rejected.close()
			}
			let accepted = try await listener.accept()
			if encrypted { _ = try await seed.attach(PeerStream.accept(accepted, hashes: [fixture.metadata.hashes.v1!], configuration: policy)) }
			else { _ = try await seed.attach(accepted) }
			_ = try await task.value
			try await eventually { await down.snapshot().complete }
			let peers = await down.snapshot().peers
			#expect(peers.count == 1 && peers.allSatisfy { !$0.v2 && $0.encryption == (encrypted ? .rc4 : .plaintext) && $0.transport == (utp ? .utp : .tcp) })
			try await down.shutdown()
			for name in ["a", "b", "empty"] {
				#expect(try Data(contentsOf: fixture.root.appendingPathComponent("download/Bundle/" + name)) == Data(contentsOf: fixture.root.appendingPathComponent("source/Bundle/" + name)))
			}
		} catch { opening?.cancel(); await fixture.close(); await listener.close(); throw error }
		await fixture.close(); await listener.close()
	}
	@Test(arguments: [1, 2, 3]) func rejectionHasABoundedIdentityBudget(_ version: Int) async throws {
		let fixture = try V2Fixture(version: version), listener = try await IdentityListener(utp: false)
		do {
			let down = try await fixture.engine("download", seed: false)
			_ = try await down.connect(to: listener.endpoint)
			for _ in 0..<(version == 3 ? 2 : 1) {
				let raw = try await listener.accept(); _ = try await raw.read(timeout: 3); raw.close()
			}
			try await eventually { await down.snapshot().peers.isEmpty }
			await #expect(throws: NetworkFailure.timedOut) { try await listener.accept(timeout: 0.1) }
			#expect(await down.snapshot().verifiedPieces.isEmpty)
		} catch { await fixture.close(); await listener.close(); throw error }
		await fixture.close(); await listener.close()
	}
	@Test(arguments: [false, true], [false, true]) func drainingCancelsTheAlternateHandshake(_ shutdown: Bool, _ encrypted: Bool) async throws {
		let fixture = try V2Fixture(version: 3), listener = try await IdentityListener(utp: false)
		let policy: PeerEncryptionConfiguration = encrypted ? .init(incoming: .required, outgoing: .required, levels: .rc4) : .disabled
		var opening: Task<UUID, Error>?
		do {
			let down = try await fixture.engine("download", seed: false, encryption: policy)
			let task = Task { try await down.connect(to: listener.endpoint) }; opening = task
			let rejected = try await listener.accept()
			if encrypted {
				await #expect(throws: (any Error).self) { try await PeerStream.accept(rejected, hashes: [fixture.metadata.hashes.v1!], configuration: policy) }
			} else { _ = try await rejected.read(timeout: 3); rejected.close() }
			let alternate = try await listener.accept(); _ = try await alternate.read(timeout: 3)
			if shutdown { try await down.shutdown() } else { await down.disconnectPeers() }
			if encrypted { await #expect(throws: CancellationError.self) { try await task.value } }
			else { _ = try await task.value }
			#expect(await down.snapshot().peers.isEmpty)
			#expect(await down.identityRetries.isEmpty)
			alternate.close()
			await #expect(throws: NetworkFailure.timedOut) { try await listener.accept(timeout: 0.1) }
		} catch { opening?.cancel(); await fixture.close(); await listener.close(); throw error }
		await fixture.close(); await listener.close()
	}
}
