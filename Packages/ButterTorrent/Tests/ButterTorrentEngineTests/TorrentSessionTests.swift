import Foundation
import Testing
import ButterTorrentMetadata
import ButterTorrentStorage
@testable import ButterTorrentEngine

extension NativeSessionTests { @Suite struct TorrentSessionTests {
	@Test(arguments: [2, 3]) func sparseDownloadsAcquireHashesAndRestoreNativeCounters(_ version: Int) async throws {
		let fixture = try V2Fixture(version: version), library = fixture.root.appendingPathComponent("library"), source = fixture.root.appendingPathComponent("input.torrent")
		let sparse = try TorrentMetadata(infoBytes: fixture.metadata.originalInfo, expected: fixture.metadata.hashes)
		try sparse.document.original.write(to: source)
		let clock = EngineClock(), session = TorrentSession(storage: library, configuration: plainTransferConfiguration(), clock: clock)
		do {
			_ = try await session.add(id: "transfer", source: source, destination: fixture.root.appendingPathComponent("download"))
			try await session.save(id: "transfer")
			#expect(try await session.snapshot().transfers[0].state.storage.verifiedPieces.isEmpty)
			await #expect(throws: MetadataError.invalid("piece layers are incomplete")) { try await session.export(id: "transfer") }
			let seed = try await fixture.engine("seed", seed: true), (endpoint, accepting) = try await fixture.provider(seed)
			try await session.run(id: "transfer", running: true)
			let firstExport = Task { try await session.export(id: "transfer") }, secondExport = Task { try await session.export(id: "transfer") }
			try await waitForExportTimer(clock); try await waitForExportTimer(clock)
			_ = try await session.connect(id: "transfer", to: endpoint); try await accepting.value
			try await eventually { try await session.snapshot().transfers[0].state.transfer?.complete == true }
			let first = try await exportValue(firstExport), second = try await exportValue(secondExport)
			#expect(first == second)
			#expect(try TorrentMetadata(first).pieceLayers == fixture.metadata.pieceLayers)
			let active = try await session.snapshot()
			#expect(active.transfers[0].state.transfer?.peers.contains { $0.endpoint == endpoint && $0.client == "Butter Swift" && $0.transport == .tcp } == true)
			try await session.pause(id: "transfer")
			let snapshot = try await session.snapshot(), downloaded = snapshot.transfers[0].state.storage.downloaded
			#expect(downloaded > 0)
			#expect(try TorrentMetadata(await session.export(id: "transfer")).pieceLayers == fixture.metadata.pieceLayers)
			_ = try await session.remove(id: "transfer", retainState: true)
			_ = try await session.add(id: "transfer", source: source, destination: fixture.root.appendingPathComponent("download"), restore: true)
			#expect(try await session.snapshot().transfers[0].state.storage.downloaded == downloaded)
			_ = try await session.remove(id: "transfer")
		} catch { try? await cleanup(session); await fixture.close(); throw error }; await fixture.close()
	}
	@Test func waitingExportsSettleOnCancellationTimeoutRemovalAndShutdown() async throws {
		let fixture = try V2Fixture(version: 2), clock = EngineClock()
		let source = fixture.root.appendingPathComponent("sparse.torrent"), destination = fixture.root.appendingPathComponent("download")
		let session = TorrentSession(storage: fixture.root.appendingPathComponent("library"), configuration: plainTransferConfiguration(), clock: clock)
		do {
			let sparse = try TorrentMetadata(infoBytes: fixture.metadata.originalInfo, expected: fixture.metadata.hashes)
			try sparse.document.original.write(to: source)
			_ = try await session.add(id: "transfer", source: source, destination: destination)
			try await session.run(id: "transfer", running: true)
			let cancelled = Task { try await session.export(id: "transfer") }, timedOut = Task { try await session.export(id: "transfer") }
			try await waitForExportTimer(clock); try await waitForExportTimer(clock)
			cancelled.cancel()
			await #expect(throws: CancellationError.self) { try await exportValue(cancelled) }
			clock.advance(15)
			await #expect(throws: SessionExportFailure.timedOut) { try await exportValue(timedOut) }
			let removed = Task { try await session.export(id: "transfer") }
			try await waitForExportTimer(clock)
			_ = try await session.remove(id: "transfer")
			await #expect(throws: SessionExportFailure.stopped) { try await exportValue(removed) }
			_ = try await session.add(id: "transfer", source: source, destination: destination)
			try await session.run(id: "transfer", running: true)
			let stopped = Task { try await session.export(id: "transfer") }
			try await waitForExportTimer(clock)
			try await session.shutdown()
			await #expect(throws: SessionExportFailure.stopped) { try await exportValue(stopped) }
			try await session.close()
		} catch { try? await session.close(); await fixture.close(); throw error }
		await fixture.close()
	}
	private func waitForExportTimer(_ clock: EngineClock) async throws {
		try await engineDeadline { while try await clock.nextSleep() != 15 {} }
	}
	private func exportValue(_ task: Task<Data, Error>) async throws -> Data {
		try await engineDeadline {
			try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
		}
	}
	@Test func anotherSessionCannotForgetLiveCheckpointState() async throws {
		try await withSession { fixture, session, library, source in
			_ = try await session.add(id: "transfer", source: source, destination: fixture.root.appendingPathComponent("source"))
			let other = TorrentSession(storage: library)
			await #expect(throws: StorageFailure.self) { try await other.forget(id: "transfer") }
			#expect(try await session.snapshot().transfers.count == 1)
			_ = try await session.remove(id: "transfer", retainState: true)
			try await other.forget(id: "transfer")
			#expect(!FileManager.default.fileExists(atPath: library.appendingPathComponent("transfer.torrent").path))
		}
	}
	@Test func concurrentImportsPublishOneOwnerAndFailedImportsReleaseTheirState() async throws {
		try await withSession { fixture, session, library, source in
			let blocked = fixture.root.appendingPathComponent("blocked"); try Data([1]).write(to: blocked)
			await #expect(throws: (any Error).self) { try await session.add(id: "failed", source: source, destination: blocked) }
			#expect(try FileManager.default.contentsOfDirectory(atPath: library.path).allSatisfy { !$0.hasPrefix(".native-") })
			let destination = fixture.root.appendingPathComponent("source")
			let results = try await withThrowingTaskGroup(of: SessionImport.self) { group in
				for index in 0..<16 { group.addTask { try await session.add(id: "transfer-\(index)", source: source, destination: destination) } }
				var results: [SessionImport] = []; for try await result in group { results.append(result) }; return results
			}
			#expect(results.filter { !$0.duplicate }.count == 1 && Set(results.map(\.id)).count == 1)
			#expect(try await session.snapshot().transfers.count == 1)
			try FileManager.default.removeItem(at: source)
			let exported = try await session.export(id: results[0].id)
			#expect(try TorrentMetadata(exported).originalInfo == fixture.metadata.originalInfo)
		}
	}
	@Test func retainedStateRestoresPathsSelectionTrackersAndIgnoresTheOriginalSource() async throws {
		try await withSession { fixture, session, library, source in
			_ = try await session.add(id: "transfer", source: source, destination: fixture.root.appendingPathComponent("source"))
			try await session.changeStorage(id: "transfer", change: .rename([0: "bundle/renamed"]))
			try await session.changeStorage(id: "transfer", change: .select([true, false, true, true]))
			try await session.appendTracker(id: "transfer", tracker: "http://127.0.0.1:8000/announce")
			try await session.shutdown(); _ = try await session.remove(id: "transfer", retainState: true)
			try FileManager.default.removeItem(at: source)
			let restored = TorrentSession(storage: library, configuration: plainTransferConfiguration())
			do {
				_ = try await restored.add(id: "transfer", source: source, destination: fixture.root.appendingPathComponent("wrong"), restore: true)
				let snapshot = try #require(await restored.snapshot().transfers.first)
				#expect(!snapshot.state.running && snapshot.state.storage.paths[0] == "bundle/renamed")
				#expect(snapshot.state.storage.selected == [true, false, true, true] && snapshot.state.storage.verifiedPieces.isEmpty)
				#expect(snapshot.state.storage.pendingVerificationCount == 3)
				#expect(snapshot.metadata.trackerTiers == [["http://127.0.0.1:8000/announce"]])
				#expect(snapshot.state.storage.destination == fixture.root.appendingPathComponent("source"))
				#expect(try TorrentMetadata(await restored.export(id: "transfer")).originalInfo == fixture.metadata.originalInfo)
				try await restored.recheck(id: "transfer")
				#expect(try await restored.snapshot().transfers[0].state.storage.verifiedPieces.count == 3)
				_ = try await restored.remove(id: "transfer")
			} catch { _ = try? await restored.remove(id: "transfer", retainState: true); throw error }
		}
	}
	@Test func unknownStateFilesPreventDiscardAndLegacyResumeFilesAreRetained() async throws {
		try await withSession { fixture, session, library, source in
			_ = try await session.add(id: "transfer", source: source, destination: fixture.root.appendingPathComponent("source"))
			let names = try FileManager.default.contentsOfDirectory(atPath: library.path)
			let state = library.appendingPathComponent(try #require(names.first { $0.hasPrefix(".native-") }))
			let unknown = state.appendingPathComponent("review.txt"), legacy = library.appendingPathComponent("transfer.resume")
			let sentinel = Data("retain these bytes".utf8); try sentinel.write(to: unknown); try sentinel.write(to: legacy)
			await #expect(throws: StorageFailure.self) { try await session.remove(id: "transfer") }
			#expect(try Data(contentsOf: unknown) == sentinel && Data(contentsOf: legacy) == sentinel)
			let failed = try #require(await session.snapshot().transfers.first); #expect(!failed.error.isEmpty && !failed.state.running)
			await #expect(throws: StorageFailure.self) { try await session.forget(id: "transfer") }
			try await session.retry(id: "transfer")
			let retried = try #require(await session.snapshot().transfers.first); #expect(retried.error.isEmpty && !retried.state.running)
			#expect(try Data(contentsOf: unknown) == sentinel)
			try FileManager.default.removeItem(at: unknown); _ = try await session.remove(id: "transfer")
			#expect(!FileManager.default.fileExists(atPath: state.path))
			#expect(try Data(contentsOf: legacy) == sentinel)
		}
	}
	@Test func restoredStateRefusesASymlinkedCheckpointRoot() async throws {
		try await withSession { fixture, session, library, source in
			_ = try await session.add(id: "transfer", source: source, destination: fixture.root.appendingPathComponent("source"))
			_ = try await session.remove(id: "transfer", retainState: true)
			let names = try FileManager.default.contentsOfDirectory(atPath: library.path)
			let state = library.appendingPathComponent(try #require(names.first { $0.hasPrefix(".native-") })), retained = fixture.root.appendingPathComponent("retained-state")
			try FileManager.default.moveItem(at: state, to: retained); try FileManager.default.createSymbolicLink(at: state, withDestinationURL: retained)
			let before = try Data(contentsOf: retained.appendingPathComponent("checkpoint.plist"))
			await #expect(throws: (any Error).self) { try await session.add(id: "transfer", source: source, destination: fixture.root.appendingPathComponent("source"), restore: true) }
			#expect(try Data(contentsOf: retained.appendingPathComponent("checkpoint.plist")) == before)
			try FileManager.default.removeItem(at: state); try FileManager.default.moveItem(at: retained, to: state)
			_ = try await session.add(id: "transfer", source: source, destination: fixture.root.appendingPathComponent("source"), restore: true)
		}
	}
	private func withSession(_ body: (TransferFixture, TorrentSession, URL, URL) async throws -> Void) async throws {
		let fixture = try TransferFixture(), library = fixture.root.appendingPathComponent("library"), source = fixture.root.appendingPathComponent("input.torrent")
		try fixture.metadata.document.original.write(to: source)
		let session = TorrentSession(storage: library, configuration: plainTransferConfiguration())
		do { try await body(fixture, session, library, source); try await cleanup(session); await fixture.clean() }
		catch { try? await cleanup(session); await fixture.clean(); throw error }
	}
	private func cleanup(_ session: TorrentSession) async throws {
		try await session.shutdown()
		for entry in try await session.snapshot().transfers { _ = try await session.remove(id: entry.id, retainState: true) }
	}
}
}
