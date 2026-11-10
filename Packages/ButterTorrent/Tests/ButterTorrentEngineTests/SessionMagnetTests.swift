import Foundation
import Testing
import ButterTorrentMetadata
import ButterTorrentNetworking
import ButterTorrentStorage
@testable import ButterTorrentEngine

extension NativeSessionTests { @Suite struct SessionMagnetTests {
	@Test(arguments: [false, true]) func incomingPeerProvidesMetadataWithoutDiscovery(_ utp: Bool) async throws {
		let fixture = try V2Fixture(version: 3)
		let seed = TorrentSession(storage: fixture.root.appendingPathComponent("seed-library"), configuration: plainTransferConfiguration(), loopbackOnly: true)
		let down = TorrentSession(storage: fixture.root.appendingPathComponent("down-library"), configuration: plainTransferConfiguration(), loopbackOnly: true)
		do {
			var settings = SessionPeerSettings()
			settings.tcp = !utp; settings.utp = utp; settings.pex = false
			_ = try await seed.configurePeers(settings)
			let port = try await down.configurePeers(settings)
			let source = fixture.root.appendingPathComponent("source.torrent")
			try fixture.metadata.document.original.write(to: source)
			_ = try await seed.add(id: "seed", source: source, destination: fixture.root.appendingPathComponent("source"))
			try await seed.run(id: "seed", running: true)
			_ = try await down.add(id: "magnet", magnet: Magnet(hashes: fixture.metadata.hashes), destination: fixture.root.appendingPathComponent("download"))
			try await down.run(id: "magnet", running: true)
			_ = try await seed.connect(id: "seed", to: NetworkEndpoint("127.0.0.1", port: port))
			try await eventually { try await down.snapshot().transfers.first?.state.transfer?.complete == true }
			let snapshot = try await down.snapshot()
			#expect(snapshot.magnets.isEmpty && snapshot.transfers[0].metadata.originalInfo == fixture.metadata.originalInfo)
			try await down.close(); try await seed.close()
			for file in fixture.metadata.inspection.files where !file.pad {
				#expect(try Data(contentsOf: fixture.root.appendingPathComponent("download/" + file.path)) == Data(contentsOf: fixture.root.appendingPathComponent("source/" + file.path)))
			}
		} catch { try? await down.close(); try? await seed.close(); await fixture.close(); throw error }
		await fixture.close()
	}

	@Test(arguments: [1, 2, 3], [false, true]) func trackerlessMagnetResolvesAndTransfersUsingOnlyDHT(_ version: Int, _ utp: Bool) async throws {
		let fixture = try V2Fixture(version: version), host = version == 2 ? "::1" : "127.0.0.1"
		let seed = TorrentSession(storage: fixture.root.appendingPathComponent("seed-library"), configuration: plainTransferConfiguration(), loopbackOnly: true)
		var router: SessionDHTRouter?, down: TorrentSession?
		do {
			var settings = SessionPeerSettings(); settings.pex = false; settings.tcp = !utp; settings.utp = utp
			let port = try await seed.configurePeers(settings), endpoint = try NetworkEndpoint(host, port: port)
			let source = fixture.root.appendingPathComponent("source.torrent"); try fixture.metadata.document.original.write(to: source)
			_ = try await seed.add(id: "seed", source: source, destination: fixture.root.appendingPathComponent("source")); try await seed.run(id: "seed", running: true)
			let hashes = [fixture.metadata.hashes.v1, fixture.metadata.hashes.v2.map { Data($0.prefix(20)) }].compactMap { $0 }
			let routing = try await SessionDHTRouter.open(host: host, metadata: nil, replies: Dictionary(uniqueKeysWithValues: hashes.map { ($0, [endpoint]) })); router = routing
			let session = TorrentSession(storage: fixture.root.appendingPathComponent("down-library"), configuration: plainTransferConfiguration(), loopbackOnly: true, dhtBootstrap: [routing.endpoint]); down = session
			settings.dht = true; _ = try await session.configurePeers(settings)
			let magnet = Magnet(hashes: fixture.metadata.hashes, name: "Pending")
			let result = try await session.add(id: "magnet", magnet: magnet, destination: fixture.root.appendingPathComponent("download"))
			#expect(!result.duplicate && result.hashes == magnet.hashes.hex)
			let pending = try await session.snapshot()
			#expect(pending.transfers.isEmpty && pending.magnets.count == 1 && !pending.magnets[0].running)
			#expect(await routing.packets.isEmpty)
			try await session.run(id: "magnet", running: true)
			try await eventually {
				let snapshot = try await session.snapshot()
				return snapshot.magnets.isEmpty && snapshot.transfers.first?.state.transfer?.complete == true
			}
			let resolved = try #require(try await session.snapshot().transfers.first)
			#expect(resolved.metadata.originalInfo == fixture.metadata.originalInfo)
			#expect(resolved.state.transfer?.peers.contains { $0.transport == (utp ? .utp : .tcp) } == true)
			try await session.close(); try await seed.close()
			for file in fixture.metadata.inspection.files where !file.pad {
				#expect(try Data(contentsOf: fixture.root.appendingPathComponent("download/" + file.path)) == Data(contentsOf: fixture.root.appendingPathComponent("source/" + file.path)))
			}
		} catch { try? await down?.close(); try? await seed.close(); await router?.close(); await fixture.close(); throw error }
		await router?.close(); await fixture.close()
	}

	@Test func disjointHybridAliasesKeepTheOlderRowsDestinationAndRestoreItsMetadata() async throws {
		let fixture = try V2Fixture(version: 3)
		let session = TorrentSession(storage: fixture.root.appendingPathComponent("library"), configuration: plainTransferConfiguration())
		do {
			let seed = try await fixture.engine("seed", seed: true), (endpoint, serving) = try await fixture.provider(seed)
			let older = Magnet(hashes: try InfoHashes(v1: fixture.metadata.hashes.v1)), later = Magnet(hashes: try InfoHashes(v2: fixture.metadata.hashes.v2), peers: [endpoint.description])
			let destination = fixture.root.appendingPathComponent("older-data"), ignored = fixture.root.appendingPathComponent("later-data")
			_ = try await session.add(id: "older", magnet: older, destination: destination)
			let duplicate = try await session.add(id: "duplicate", magnet: older, destination: ignored)
			#expect(duplicate.duplicate && duplicate.id == "older")
			_ = try await session.add(id: "later", magnet: later, destination: ignored); try await session.run(id: "later", running: true)
			try await serving.value
			let snapshot = try await engineDeadline {
				while true {
					let state = try await session.snapshot()
					if state.magnets.isEmpty && state.transfers.count == 1 { return state }
					try await Task.sleep(for: .milliseconds(5))
				}
			}
			#expect(snapshot.transfers[0].id == "older" && !snapshot.transfers[0].state.running)
			#expect(snapshot.transfers[0].state.storage.destination.path == destination.path)
			#expect(snapshot.events.count == 1 && snapshot.events[0].kind == "duplicate" && snapshot.events[0].id == "later" && snapshot.events[0].existingID == "older")
			#expect(!FileManager.default.fileExists(atPath: ignored.path))
			_ = try await session.remove(id: "older", retainState: true)
			_ = try await session.add(id: "older", magnet: older, destination: ignored, restore: true)
			let restored = try #require(try await session.snapshot().transfers.first)
			#expect(restored.metadata.hashes == fixture.metadata.hashes && restored.state.storage.destination.path == destination.path)
			try await session.close()
		} catch { try? await session.close(); await fixture.close(); throw error }
		await fixture.close()
	}

	@Test func privateMetadataPublishesOnlyAfterDHTAndUntrustedConnectionsDrain() async throws {
		let fixture = try V2Fixture(version: 3, isPrivate: true), clock = EngineClock(), release = AsyncStream<Void>.makeStream()
		let (provider, serving) = try await metadataProvider(fixture, behaviour: .good) {
			for await _ in release.stream { return }; throw PeerFailure.closed
		}
		let providerListener = fixture.listeners.last!, stalled = try await TCPListener.listen(address: IPAddress("127.0.0.1")); fixture.listeners.append(stalled)
		let silent = try NetworkEndpoint("127.0.0.1", port: stalled.port), hashes = [fixture.metadata.hashes.v1!, Data(fixture.metadata.hashes.v2!.prefix(20))]
		let router = try await SessionDHTRouter.open(host: "127.0.0.1", metadata: nil, replies: Dictionary(uniqueKeysWithValues: hashes.map { ($0, [provider, silent]) }))
		let session = TorrentSession(storage: fixture.root.appendingPathComponent("library"), configuration: plainTransferConfiguration(), loopbackOnly: true, clock: clock, dhtBootstrap: [router.endpoint])
		do {
			var settings = SessionPeerSettings(); settings.port = try await session.configurePeers(settings)
			let magnet = Magnet(hashes: fixture.metadata.hashes)
			_ = try await session.add(id: "private", magnet: magnet, destination: fixture.root.appendingPathComponent("download")); try await session.run(id: "private", running: true)
			#expect(await router.packets.isEmpty)
			settings.dht = true; _ = try await session.configurePeers(settings)
			let untrusted = try await stalled.accept(timeout: 3); defer { untrusted.close() }
			_ = try await untrusted.read(timeout: 3)
			try await eventually { await router.packets.count == 2 }
			release.continuation.yield(()); try await serving.value
			try await eventually { try await session.snapshot().transfers.first?.metadata.inspection.private == true }
			let snapshot = try await session.snapshot()
			#expect(snapshot.magnets.isEmpty && snapshot.network.discovery.searches == 0)
			#expect(snapshot.transfers[0].state.transfer?.peers.isEmpty == true)
			#expect(try await untrusted.read(timeout: 3).isEmpty)
			await #expect(throws: NetworkFailure.timedOut) { try await providerListener.accept(timeout: 0.1) }
			clock.advance(600); try await session.shutdown()
			#expect(await router.packets.count == 2)
			try await session.close()
		} catch { serving.cancel(); release.continuation.finish(); try? await session.close(); await router.close(); await fixture.close(); throw error }
		await router.close(); await fixture.close()
	}

	@Test func pauseAndRemovalDrainUnresolvedExplicitConnections() async throws {
		let fixture = try V2Fixture(version: 1), listener = try await TCPListener.listen(address: IPAddress("127.0.0.1")); fixture.listeners.append(listener)
		let library = fixture.root.appendingPathComponent("library"), destination = fixture.root.appendingPathComponent("download")
		let session = TorrentSession(storage: library, configuration: plainTransferConfiguration())
		do {
			let magnet = Magnet(hashes: fixture.metadata.hashes, peers: ["127.0.0.1:\(listener.port)"])
			_ = try await session.add(id: "pending", magnet: magnet, destination: destination)
			await #expect(throws: StorageFailure.invalid("cannot delete files without metadata")) { try await session.remove(id: "pending", trash: true) }
			try await session.run(id: "pending", running: true)
			let first = try await listener.accept(timeout: 3); _ = try await first.read(timeout: 3)
			try await session.pause(id: "pending"); #expect(try await first.read(timeout: 3).isEmpty)
			#expect(try await session.snapshot().magnets.first?.running == false)
			try await session.run(id: "pending", running: true)
			let second = try await listener.accept(timeout: 3); _ = try await second.read(timeout: 3)
			_ = try await session.remove(id: "pending"); #expect(try await second.read(timeout: 3).isEmpty)
			#expect(try await session.snapshot().magnets.isEmpty)
			#expect(!FileManager.default.fileExists(atPath: destination.path))
			try await session.close()
		} catch { try? await session.close(); await fixture.close(); throw error }
		await fixture.close()
	}

	@Test func failedPublicationKeepsVerifiedMetadataForAnExplicitRetry() async throws {
		let fixture = try V2Fixture(version: 1), blocked = fixture.root.appendingPathComponent("blocked"), library = fixture.root.appendingPathComponent("library")
		let session = TorrentSession(storage: library, configuration: plainTransferConfiguration())
		do {
			try Data([5]).write(to: blocked)
			let seed = try await fixture.engine("seed", seed: true), (endpoint, serving) = try await fixture.provider(seed, count: 2)
			let magnet = Magnet(hashes: fixture.metadata.hashes, peers: [endpoint.description])
			_ = try await session.add(id: "pending", magnet: magnet, destination: blocked); try await session.run(id: "pending", running: true)
			try await eventually { try await session.snapshot().magnets.first?.error.isEmpty == false }
			try await session.run(id: "pending", running: true)
			#expect(try await session.snapshot().magnets.first?.running == false)
			#expect(try Data(contentsOf: blocked) == Data([5]))
			#expect(try FileManager.default.contentsOfDirectory(atPath: library.path).allSatisfy { !$0.hasPrefix(".native-") })
			try await session.changeStorage(id: "pending", change: .move(fixture.root.appendingPathComponent("download")))
			try await session.retry(id: "pending"); try await session.run(id: "pending", running: true)
			try await serving.value
			try await eventually { try await session.snapshot().transfers.first?.state.transfer?.complete == true }
			#expect(try await session.snapshot().magnets.isEmpty)
			try await session.close()
		} catch { try? await session.close(); await fixture.close(); throw error }
		await fixture.close()
	}
} }
