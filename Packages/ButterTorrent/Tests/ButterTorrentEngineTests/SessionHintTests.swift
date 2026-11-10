import Foundation
import Testing
import ButterTorrentMetadata
@testable import ButterTorrentNetworking
@testable import ButterTorrentEngine

extension NativeSessionTests { @Suite struct SessionHintTests {
	@Test func missingUTPFlagDoesNotPreventTryingUTPWhenTCPIsDisabled() async throws {
		let fixture = try V2Fixture(version: 1)
		let seed = TorrentSession(storage: fixture.root.appendingPathComponent("seed-library"), configuration: plainTransferConfiguration(), loopbackOnly: true)
		let intro = TorrentSession(storage: fixture.root.appendingPathComponent("intro-library"), configuration: plainTransferConfiguration(), loopbackOnly: true)
		let down = TorrentSession(storage: fixture.root.appendingPathComponent("down-library"), configuration: plainTransferConfiguration(), loopbackOnly: true)
		do {
			var settings = SessionPeerSettings(); settings.allowSameIP = true; settings.pex = false
			let seedPort = try await seed.configurePeers(settings)
			settings.pex = true; let introPort = try await intro.configurePeers(settings)
			settings.tcp = false; _ = try await down.configurePeers(settings)
			let source = fixture.root.appendingPathComponent("input.torrent"); try fixture.metadata.document.original.write(to: source)
			_ = try await seed.add(id: "transfer", source: source, destination: fixture.root.appendingPathComponent("source"))
			_ = try await intro.add(id: "transfer", source: source, destination: fixture.root.appendingPathComponent("intro-empty"), selected: fixture.metadata.inspection.files.map { _ in false })
			_ = try await down.add(id: "transfer", source: source, destination: fixture.root.appendingPathComponent("download"))
			for session in [seed, intro, down] { try await session.run(id: "transfer", running: true) }
			_ = try await intro.connect(id: "transfer", to: NetworkEndpoint("127.0.0.1", port: seedPort))
			try await eventually { try await intro.snapshot().transfers[0].state.transfer?.peers.contains { $0.endpoint?.port == seedPort && $0.transport == .tcp && $0.peerID != nil } == true }
			_ = try await down.connect(id: "transfer", to: NetworkEndpoint("127.0.0.1", port: introPort))
			try await eventually { try await down.snapshot().transfers[0].state.transfer?.complete == true }
			#expect(try await down.snapshot().transfers[0].state.transfer?.peers.contains { $0.endpoint?.port == seedPort && $0.transport == .utp } == true)
			for session in [down, intro, seed] { try await session.close() }
		} catch { for session in [down, intro, seed] { try? await session.close() }; await fixture.close(); throw error }; await fixture.close()
	}
	@Test(arguments: [false, true]) func privateOrDisabledPORTNeverChallengesAdvertisedNodes(_ isPrivate: Bool) async throws {
		let fixture = try V2Fixture(version: 1, isPrivate: isPrivate), router = try await SessionDHTRouter.open(host: "127.0.0.1", metadata: nil)
		let session = TorrentSession(storage: fixture.root.appendingPathComponent("library"), configuration: plainTransferConfiguration(), loopbackOnly: true, dhtBootstrap: [])
		var wire: HintPeer?
		do {
			var settings = SessionPeerSettings(); settings.dht = isPrivate; _ = try await session.configurePeers(settings)
			let source = fixture.root.appendingPathComponent("input.torrent"); try fixture.metadata.withTrackerTiers([]).write(to: source)
			_ = try await session.add(id: "transfer", source: source, destination: fixture.root.appendingPathComponent("download")); try await session.run(id: "transfer", running: true)
			wire = try await hintPeer(session, metadata: fixture.metadata, dht: true)
			try await wire!.send(.port(Int(router.endpoint.port)))
			try await eventually { try await session.snapshot().transfers[0].state.transfer?.peers.isEmpty == true }
			wire?.stream.close(); try await session.close(); #expect(await router.packets.isEmpty)
		} catch { wire?.stream.close(); try? await session.close(); await router.close(); await fixture.close(); throw error }; await router.close(); await fixture.close()
	}
	@Test func staleHintsCannotConnectAfterPauseOrStorageReplacement() async throws {
		try await transferFixture { fixture in
			let owner = try await ManagedTransfer.open(metadata: fixture.metadata, destination: fixture.root.appendingPathComponent("download"), stateDirectory: fixture.root.appendingPathComponent("managed-state"), configuration: plainTransferConfiguration())
			let recorder = HintRecorder(), probe = try await TCPListener.listen(address: IPAddress("127.0.0.1"))
			var first: HintPeer?, second: HintPeer?
			do {
				await owner.setDiscoveryHandler { await recorder.receive($0) }; try await owner.start()
				first = try await hintPeer(metadata: fixture.metadata, dht: false) { try await owner.connect(to: $0) }
				let contact = try ExchangedPeer(endpoint: NetworkEndpoint("127.0.0.1", port: probe.port), flags: 0)
				try await first!.send(.extended(2, PeerExchange.encode(added: [contact], dropped: [])))
				try await eventually { await recorder.notices.count == 1 }
				try await engineDeadline { try await owner.pause() }
				#expect(await recorder.cancelled == 1)
				let old = try #require(await recorder.notices.first)
				try await owner.start()
				await #expect(throws: PeerFailure.closed) { try await owner.connectDiscovered(to: contact.endpoint, revision: old.revision, utp: nil) }
				second = try await hintPeer(metadata: fixture.metadata, dht: false) { try await owner.connect(to: $0) }
				try await second!.send(.extended(2, PeerExchange.encode(added: [contact], dropped: [])))
				try await eventually { await recorder.notices.count == 2 }
				let newer = try #require(await recorder.notices.last); #expect(newer.revision != old.revision)
				try await owner.changeStorage(.rename([0: "renamed"]))
				await #expect(throws: PeerFailure.closed) { try await owner.connectDiscovered(to: contact.endpoint, revision: newer.revision, utp: nil) }
				await #expect(throws: NetworkFailure.timedOut) { try await probe.accept(timeout: 0.1) }
				first?.stream.close(); second?.stream.close(); try await owner.close()
			} catch { first?.stream.close(); second?.stream.close(); try? await owner.close(); try? await probe.shutdown(); throw error }; try await probe.shutdown()
		}
	}
	@Test func blockedPEXContactsBecomeReachableOnlyAfterPolicyChanges() async throws {
		let fixture = try V2Fixture(version: 1), session = TorrentSession(storage: fixture.root.appendingPathComponent("library"), configuration: plainTransferConfiguration(), loopbackOnly: true)
		let probe = try await TCPListener.listen(address: IPAddress("::1")); var wire: HintPeer?
		do {
			var settings = SessionPeerSettings(); settings.pex = true; _ = try await session.configurePeers(settings)
			let address = try IPAddress("::1"); try await session.setBlocklist([PeerAddressRange(first: address, last: address)])
			let source = fixture.root.appendingPathComponent("input.torrent"); try fixture.metadata.document.original.write(to: source)
			_ = try await session.add(id: "transfer", source: source, destination: fixture.root.appendingPathComponent("download")); try await session.run(id: "transfer", running: true)
			let message = try PeerExchange.encode(added: [ExchangedPeer(endpoint: NetworkEndpoint("::1", port: probe.port), flags: 0)], dropped: [])
			wire = try await hintPeer(session, metadata: fixture.metadata, dht: false); try await wire!.send(.extended(2, message))
			await #expect(throws: NetworkFailure.timedOut) { try await probe.accept(timeout: 0.1) }
			try await session.pause(id: "transfer"); try await session.setBlocklist([]); try await session.run(id: "transfer", running: true)
			wire?.stream.close(); wire = try await hintPeer(session, metadata: fixture.metadata, dht: false)
			try await wire!.send(.extended(2, message)); let accepted = try await probe.accept(timeout: 1); accepted.close()
			wire?.stream.close(); _ = try await session.remove(id: "transfer"); try await session.close()
		} catch { wire?.stream.close(); try? await session.close(); try? await probe.shutdown(); await fixture.close(); throw error }; try await probe.shutdown(); await fixture.close()
	}
	@Test(arguments: [1, 2, 3], [false, true]) func PEXContactsStartManagedTransfersWithTheirAdvertisedTransport(_ version: Int, _ utp: Bool) async throws {
		let fixture = try V2Fixture(version: version)
		let seed = TorrentSession(storage: fixture.root.appendingPathComponent("seed-library"), configuration: plainTransferConfiguration(), loopbackOnly: true)
		let down = TorrentSession(storage: fixture.root.appendingPathComponent("down-library"), configuration: plainTransferConfiguration(), loopbackOnly: true)
		var wire: HintPeer?
		do {
			let source = fixture.root.appendingPathComponent("input.torrent"); try fixture.metadata.document.original.write(to: source)
			var settings = SessionPeerSettings(); settings.tcp = !utp; settings.utp = utp; settings.pex = false; settings.allowSameIP = true
			let port = try await seed.configurePeers(settings)
			_ = try await seed.add(id: "transfer", source: source, destination: fixture.root.appendingPathComponent("source")); try await seed.run(id: "transfer", running: true)
			settings.tcp = true; settings.utp = true; settings.pex = true; _ = try await down.configurePeers(settings)
			_ = try await down.add(id: "transfer", source: source, destination: fixture.root.appendingPathComponent("download")); try await down.run(id: "transfer", running: true)
			wire = try await hintPeer(down, metadata: fixture.metadata, dht: false)
			try await wire!.send(.extended(2, PeerExchange.encode(added: [ExchangedPeer(endpoint: NetworkEndpoint("127.0.0.1", port: port), flags: utp ? 4 : 0)], dropped: [])))
			try await eventually { try await down.snapshot().transfers[0].state.transfer?.complete == true }
			#expect(try await down.snapshot().transfers[0].state.transfer?.peers.contains { $0.endpoint?.port == port && $0.transport == (utp ? .utp : .tcp) } == true)
			wire?.stream.close(); try await down.close(); try await seed.close()
			for file in fixture.metadata.inspection.files where !file.pad {
				#expect(try Data(contentsOf: fixture.root.appendingPathComponent("download/" + file.path)) == Data(contentsOf: fixture.root.appendingPathComponent("source/" + file.path)))
			}
		} catch { wire?.stream.close(); try? await down.close(); try? await seed.close(); await fixture.close(); throw error }; await fixture.close()
	}
	@Test func PORTFindsPeersWithoutAnyBootstrapAndAdvertisesTheOwnedPort() async throws {
		let fixture = try V2Fixture(version: 2), router = try await SessionDHTRouter.open(host: "127.0.0.1", metadata: fixture.metadata)
		let seed = TorrentSession(storage: fixture.root.appendingPathComponent("seed-library"), configuration: plainTransferConfiguration(), loopbackOnly: true, dhtBootstrap: [router.endpoint])
		let down = TorrentSession(storage: fixture.root.appendingPathComponent("down-library"), configuration: plainTransferConfiguration(), loopbackOnly: true, dhtBootstrap: [])
		var wire: HintPeer?
		do {
			var settings = SessionPeerSettings(); settings.dht = true; settings.pex = false; settings.allowSameIP = true
			let source = fixture.root.appendingPathComponent("input.torrent"); try fixture.metadata.document.original.write(to: source)
			let seedPort = try await seed.configurePeers(settings), downPort = try await down.configurePeers(settings)
			_ = try await seed.add(id: "transfer", source: source, destination: fixture.root.appendingPathComponent("source")); try await seed.run(id: "transfer", running: true)
			try await eventually { await router.announces.contains { $0.port == seedPort } }
			_ = try await down.add(id: "transfer", source: source, destination: fixture.root.appendingPathComponent("download")); try await down.run(id: "transfer", running: true)
			wire = try await hintPeer(down, metadata: fixture.metadata, dht: true)
			var advertised: Int?
			for _ in 0..<8 { if case .port(let port) = try await wire!.next() { advertised = port; break } }
			#expect(advertised == Int(downPort))
			try await wire!.send(.port(Int(router.endpoint.port)))
			try await eventually { try await down.snapshot().transfers[0].state.transfer?.complete == true }
			#expect(try await down.snapshot().network.discovery.contacts > 0)
			wire?.stream.close(); try await down.close(); try await seed.close()
		} catch { wire?.stream.close(); try? await down.close(); try? await seed.close(); await router.close(); await fixture.close(); throw error }; await router.close(); await fixture.close()
	}
	@Test(arguments: [false, true]) func privateAndDisabledPEXNeverConnectReturnedContacts(_ isPrivate: Bool) async throws {
		let fixture = try V2Fixture(version: 1, isPrivate: isPrivate)
		let session = TorrentSession(storage: fixture.root.appendingPathComponent("library"), configuration: plainTransferConfiguration(), loopbackOnly: true)
		let probe = try await TCPListener.listen(address: IPAddress("127.0.0.1")); var wire: HintPeer?
		do {
			var settings = SessionPeerSettings(); settings.pex = isPrivate; _ = try await session.configurePeers(settings)
			let source = fixture.root.appendingPathComponent("input.torrent"); try fixture.metadata.withTrackerTiers([]).write(to: source)
			_ = try await session.add(id: "transfer", source: source, destination: fixture.root.appendingPathComponent("download")); try await session.run(id: "transfer", running: true)
			wire = try await hintPeer(session, metadata: fixture.metadata, dht: false)
			try await wire!.send(.extended(2, PeerExchange.encode(added: [ExchangedPeer(endpoint: NetworkEndpoint("127.0.0.1", port: probe.port), flags: 0)], dropped: [])))
			try await eventually { try await session.snapshot().transfers[0].state.transfer?.peers.isEmpty == true }
			await #expect(throws: NetworkFailure.timedOut) { try await probe.accept(timeout: 0.1) }
			wire?.stream.close(); try await session.close()
		} catch { wire?.stream.close(); try? await session.close(); try? await probe.shutdown(); await fixture.close(); throw error }; try await probe.shutdown(); await fixture.close()
	}
}

}

private func hintPeer(_ session: TorrentSession, metadata: TorrentMetadata, dht: Bool) async throws -> HintPeer {
	try await hintPeer(metadata: metadata, dht: dht) { try await session.connect(id: "transfer", to: $0) }
}
private func hintPeer(metadata: TorrentMetadata, dht: Bool, connect: @escaping @Sendable (NetworkEndpoint) async throws -> UUID) async throws -> HintPeer {
	let listener = try await TCPListener.listen(address: IPAddress("127.0.0.1"))
	let connecting = Task { try await connect(NetworkEndpoint("127.0.0.1", port: listener.port)) }
	var stream: TCPStream?
	do {
		stream = try await listener.accept(timeout: 3); let wire = WirePeer(stream: stream!)
		var flags = Data(repeating: 0, count: 8); flags[5] = 16; if dht { flags[7] = 1 }
		let hash = metadata.hashes.v2.map { Data($0.prefix(20)) } ?? metadata.hashes.v1!
		try await wire.hello(hash: hash, identity: 77, reserved: flags, v2: metadata.hashes.v2 != nil); _ = try await connecting.value
		let total = metadata.inspection.files.reduce(Int64(0)) { $0 + $1.size }, count = Int((total + metadata.pieceLength - 1) / metadata.pieceLength)
		try await wire.send(.bitfield(PieceBitfield(count: count).bytes))
		try await wire.send(.extended(0, extensionDictionary(["m": extensionDictionary(["ut_pex": .integer(9)])]).encoded()))
		return HintPeer(wire: wire, listener: listener)
	} catch { connecting.cancel(); _ = try? await connecting.value; stream?.close(); try? await listener.shutdown(); throw error }
}

private final class HintPeer {
	let wire: WirePeer
	let listener: TCPListener
	init(wire: WirePeer, listener: TCPListener) { self.wire = wire; self.listener = listener }
	var stream: any PeerByteStream { wire.stream }
	func send(_ message: PeerMessage) async throws { try await wire.send(message) }
	func next() async throws -> PeerMessage { try await wire.next() }
	deinit { listener.close() }
}

private actor HintRecorder {
	var notices: [ManagedDiscoveryNotice] = []
	var cancelled = 0
	var blockNext = true
	func receive(_ notice: ManagedDiscoveryNotice) async {
		notices.append(notice)
		if blockNext { blockNext = false; do { try await Task.sleep(for: .seconds(60)) } catch { cancelled += 1 } }
	}
}
