import Foundation
import Testing
import ButterTorrentMetadata
import ButterTorrentNetworking
@testable import ButterTorrentEngine

@Suite struct MagnetLifecycleTests {
	@Test func waitingMagnetSurvivesTheFirstOwnersStorageFailure() async throws {
		let fixture = try V2Fixture(version: 3), registry = TorrentIdentityRegistry()
		let blocked = fixture.root.appendingPathComponent("blocked-state"); try Data("keep".utf8).write(to: blocked)
		let first = MagnetDownload(magnet: Magnet(hashes: fixture.metadata.hashes), destination: fixture.root.appendingPathComponent("first"), stateDirectory: blocked, registry: registry)
		let second = MagnetDownload(magnet: Magnet(hashes: fixture.metadata.hashes), destination: fixture.root.appendingPathComponent("second"), stateDirectory: fixture.root.appendingPathComponent("second-state"), registry: registry)
		do {
			_ = try await registry.claim(fixture.metadata, owner: first.id)
			let seed = try await fixture.engine("seed", seed: true), (endpoint, serving) = try await fixture.provider(seed, count: 3)
			let waiting = Task { try await second.resolve(peers: [endpoint]) }
			try await eventually { await registry.waiters.count == 1 }
			do { _ = try await first.resolve(peers: [endpoint]); Issue.record("Invalid storage root was accepted") } catch {}
			guard case .ready(_, let engine, _) = try await waiting.value else { throw PeerFailure.invalid("failed owner was returned as a duplicate") }
			try await serving.value; try await eventually { await engine.snapshot().complete }
			#expect(await registry.owner(of: fixture.metadata.hashes) == second.id)
			#expect(try Data(contentsOf: blocked) == Data("keep".utf8))
			try await first.shutdown(); try await second.shutdown()
		} catch { try? await first.shutdown(); try? await second.shutdown(); await fixture.close(); throw error }; await fixture.close()
	}
	@Test func failedOwnerReleasesReservationAndCancelledWaiterDoesNotTakeOwnership() async throws {
		let fixture = try V2Fixture(version: 3), registry = TorrentIdentityRegistry(), first = UUID(), second = UUID(), third = UUID()
		do {
			#expect(try await registry.claim(fixture.metadata, owner: first) == first)
			#expect(await registry.owner(of: fixture.metadata.hashes) == nil)
			let cancelled = Task { [metadata = fixture.metadata] in try await registry.claim(metadata, owner: third) }
			try await eventually { await registry.waiters.count == 1 }; cancelled.cancel()
			await #expect(throws: CancellationError.self) { try await cancelled.value }
			let waiting = Task { [metadata = fixture.metadata] in try await registry.claim(metadata, owner: second) }
			try await eventually { await registry.waiters.count == 1 }
			await registry.release(first)
			#expect(try await waiting.value == second)
			try await registry.confirm(second)
			#expect(await registry.owner(of: fixture.metadata.hashes) == second)
			#expect(try await registry.claim(fixture.metadata, owner: first) == second)
			await registry.release(second)
		} catch { await fixture.close(); throw error }; await fixture.close()
	}
	@Test func verifiedArrivalResolvesDuplicates() async throws {
		let fixture = try V2Fixture(version: 3)
		let registry = TorrentIdentityRegistry()
		let first = MagnetDownload(magnet: Magnet(hashes: fixture.metadata.hashes), destination: fixture.root.appendingPathComponent("first"), stateDirectory: fixture.root.appendingPathComponent("first-state"), registry: registry)
		let second = MagnetDownload(magnet: Magnet(hashes: fixture.metadata.hashes), destination: fixture.root.appendingPathComponent("second"), stateDirectory: fixture.root.appendingPathComponent("second-state"), registry: registry)
		do {
			#expect(await !first.discoveryAllowed)
			let seed = try await fixture.engine("seed", seed: true)
			let (endpoint, serving) = try await fixture.provider(seed, count: 3)
			async let one = first.resolve(peers: [endpoint])
			async let two = second.resolve(peers: [endpoint])
			let results = try await (one, two)
			try await serving.value
			let winner: MagnetDownload, loser: MagnetDownload
			switch results {
			case (.ready(let metadata, let engine, _), .duplicate(let owner)):
				#expect(metadata.hashes == fixture.metadata.hashes && owner == first.id)
				try await eventually { await engine.snapshot().complete }; winner = first; loser = second
			case (.duplicate(let owner), .ready(let metadata, let engine, _)):
				#expect(metadata.hashes == fixture.metadata.hashes && owner == second.id)
				try await eventually { await engine.snapshot().complete }; winner = second; loser = first
			default: Issue.record("Concurrent metadata arrivals created multiple transfers"); throw PeerFailure.invalid("duplicate resolution")
			}
			#expect(await winner.discoveryAllowed)
			let loserName = loser.id == first.id ? "first" : "second"
			#expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(loserName + "-state").path))
			try await loser.shutdown()
			#expect(await registry.owner(of: fixture.metadata.hashes) == winner.id)
			try await winner.shutdown()
			#expect(await registry.owner(of: fixture.metadata.hashes) == nil)
		} catch { try? await first.shutdown(); try? await second.shutdown(); await fixture.close(); throw error }
		await fixture.close()
	}
	@Test func cancellationDrainsMetadataWaitAndCreatesNoStorage() async throws {
		let fixture = try V2Fixture(version: 2)
		let listener = try await TCPListener.listen(address: IPAddress("127.0.0.1"))
		let registry = TorrentIdentityRegistry()
		let download = MagnetDownload(magnet: Magnet(hashes: fixture.metadata.hashes), destination: fixture.root.appendingPathComponent("download"), stateDirectory: fixture.root.appendingPathComponent("state"), registry: registry)
		do {
			let work = Task { try await download.resolve(peers: [NetworkEndpoint("127.0.0.1", port: listener.port)]) }
			let stream = try await listener.accept(timeout: 3)
			work.cancel()
			do { _ = try await work.value; Issue.record("Cancelled metadata request succeeded") } catch {}
			try await download.shutdown(); stream.close()
			#expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("state").path))
			#expect(await registry.owner(of: fixture.metadata.hashes) == nil)
		} catch { try? await download.shutdown(); try? await listener.shutdown(); await fixture.close(); throw error }
		try await listener.shutdown(); await fixture.close()
	}
	@Test func extensionRemappingAndCompactPeerValidation() throws {
		var handshake = ExtensionHandshake()
		try handshake.apply(extensionDictionary(["m": extensionDictionary(["ut_metadata": .integer(7), "ut_pex": .integer(9)])]).encoded())
		try handshake.apply(extensionDictionary(["m": extensionDictionary(["ut_metadata": .integer(3), "ut_pex": .integer(0)])]).encoded())
		#expect(handshake.ids == ["ut_metadata": 3])
		#expect(throws: (any Error).self) { try handshake.apply(extensionDictionary(["m": extensionDictionary(["duplicate": .integer(3)])]).encoded()) }
		let v4 = try NetworkEndpoint("127.0.0.1", port: 4567), v6 = try NetworkEndpoint("::1", port: 4568)
		let encoded = try PeerExchange.encode(added: [ExchangedPeer(endpoint: v4, flags: 1), ExchangedPeer(endpoint: v6, flags: 2)], dropped: [v6])
		let decoded = try PeerExchange(encoded)
		#expect(decoded.added.map(\.endpoint) == [v4, v6] && decoded.dropped == [v6])
		#expect(throws: (any Error).self) { try PeerExchange(extensionDictionary(["added": .bytes(Data(repeating: 1, count: 6)), "added.f": .bytes(Data())]).encoded()) }
		var bounded = ExtensionHandshake()
		for index in 1...64 { try bounded.apply(extensionDictionary(["m": extensionDictionary(["extension_\(index)": .integer(Int64(index))])]).encoded()) }
		#expect(throws: (any Error).self) { try bounded.apply(extensionDictionary(["m": extensionDictionary(["overflow": .integer(65)])]).encoded()) }
	}
}
