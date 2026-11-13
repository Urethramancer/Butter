#if BUTTER_APPLICATION_BENCHMARK
import Foundation
import ButterTorrentEngine
import ButterTorrentStorage
import ButterTorrentMetadata
import ButterTorrentNetworking

// The production session and application mapper, with one poll per second.
// No SwiftUI rendering or OS services are included in this headless workload.
extension TransferBenchmark {
	struct ApplicationSample {
		let snapshot: EngineSnapshot
		let errors: [String]
	}
	static func applicationSample(_ session: TorrentSession, mapper: NativeSnapshotMapper, inspector: String?) async throws -> ApplicationSample {
		#if BUTTER_SNAPSHOT_PROJECTION_AVAILABLE
		let native = try await session.snapshot(projection: inspector.map(SessionSnapshotProjection.inspector) ?? .summary)
		#else
		let native = try await session.snapshot()
		#endif
		let view = await mapper.map(native, progress: 0, now: ProcessInfo.processInfo.systemUptime)
		guard view.transfers.allSatisfy({ $0.error.isEmpty }) else { throw PeerFailure.invalid("application snapshot storage error") }
		return ApplicationSample(snapshot: view, errors: native.transfers.compactMap { $0.state.transfer?.lastPeerError })
	}
	static func application(_ job: Job, verify: Bool) async throws {
		guard let visible = job.applicationInspector, !job.items.isEmpty, job.partial != true else { throw PeerFailure.invalid("full application benchmark job required") }
		let root = URL(fileURLWithPath: job.items[0].state).deletingLastPathComponent().appendingPathComponent("application-" + job.role)
		if verify {
			let repository = TransferRepository(root: root)
			for (index, item) in job.items.enumerated() {
				let prepared = try await repository.prepare(id: "bench-\(index)", restore: true)
				let metadata = try TorrentMetadata(contentsOf: URL(fileURLWithPath: item.torrent))
				let storage = try await TorrentStorage.open(metadata: metadata, destination: URL(fileURLWithPath: item.destination), stateDirectory: prepared.directory, preparedState: prepared)
				guard try await storage.snapshot().verifiedPieces.count == storage.layout.pieceCount else { try await storage.shutdown(); throw PeerFailure.invalid("application checkpoint did not reopen complete") }
				try await storage.shutdown()
			}
			return
		}
		try emit("prepare")
		var configuration = TCPTransferConfiguration(); configuration.encryption = .disabled; configuration.enablePEX = false
		let session = TorrentSession(storage: root, readPolicy: .trustedVerified, configuration: configuration, loopbackOnly: true), mapper = NativeSnapshotMapper()
		var polling: Task<ApplicationSample, Error>?
		do {
			var settings = SessionPeerSettings(); settings.utp = false; settings.pex = false; settings.allowSameIP = true
			let port = try await session.configurePeers(settings)
			var identifiers: [String] = [], bytes: Int64 = 0
			for (index, item) in job.items.enumerated() {
				let source = URL(fileURLWithPath: item.torrent), metadata = try TorrentMetadata(contentsOf: source)
				let imported = try await session.add(id: "bench-\(index)", source: source, destination: URL(fileURLWithPath: item.destination))
				guard imported.id == "bench-\(index)", !imported.duplicate else { throw PeerFailure.invalid("duplicate application fixture") }
				identifiers.append(imported.id); bytes += metadata.inspection.files.filter { !$0.pad }.reduce(0) { $0 + $1.size }
				if job.role == "seed" { try await session.recheck(id: imported.id) }
				try await session.run(id: imported.id, running: true)
			}
			try emit("ready", ports: job.role == "seed" ? Array(repeating: port, count: identifiers.count) : [], bytes: bytes)
			let start = try await command("start"); try emit("start")
			if job.role == "download" {
				guard let ports = start.ports, ports.count == identifiers.count else { throw PeerFailure.invalid("application benchmark ports") }
				for (id, peerPort) in zip(identifiers, ports) { _ = try await session.connect(id: id, to: NetworkEndpoint("127.0.0.1", port: peerPort)) }
			}
			let inspector = visible ? identifiers[0] : nil
			let role = job.role
			let task = Task {
				var latest = try await applicationSample(session, mapper: mapper, inspector: inspector)
				do {
					while true {
						if role == "download", latest.snapshot.transfers.count == job.items.count, latest.snapshot.transfers.allSatisfy(\.complete) { return latest }
						try await Task.sleep(for: .seconds(1)); try Task.checkCancellation()
						latest = try await applicationSample(session, mapper: mapper, inspector: inspector)
					}
				} catch is CancellationError {
					if role == "seed" { return latest }; throw CancellationError()
				}
			}
			polling = task
			if job.role == "seed" { _ = try await command("verified"); task.cancel() }
			let final = try await task.value; polling = nil
			try emit("verified", errors: final.errors)
			_ = try await command("persist"); try emit("persistence")
			for id in identifiers { try await session.save(id: id) }
			try emit("durable")
			_ = try await command("stop"); try emit("shutdown")
			try await session.close(); try emit("stopped")
		} catch {
			polling?.cancel(); _ = try? await polling?.value
			try? await session.close(); throw error
		}
	}
}
#endif
