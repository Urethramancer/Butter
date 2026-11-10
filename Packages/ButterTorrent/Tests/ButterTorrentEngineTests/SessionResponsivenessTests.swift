import Foundation
import Testing
import ButterTorrentMetadata
import ButterTorrentStorage
@testable import ButterTorrentEngine

extension NativeSessionTests { @Suite struct SessionResponsivenessTests {
	@Test(arguments: [1, 4]) func durableMoveKeepsSnapshotsAndOtherCommandsResponsiveWhileShutdownWaits(_ count: Int) async throws {
		let fixture = try TransferFixture(), entered = AsyncStream<Void>.makeStream(), release = DispatchSemaphore(value: 0)
		let session = TorrentSession(storage: fixture.root.appendingPathComponent("library"), configuration: plainTransferConfiguration(), storageEvent: { id, event in
			if id.hasPrefix("first"), event == .journalDurable { entered.continuation.yield(()); _ = release.wait(timeout: .now() + 15) }
		})
		var moving: [Task<Void, Error>] = [], shutdown: Task<Void, Error>?
		var stage = "import"
		do {
			for index in 0..<count {
				var info = fixture.metadata.document.root["info"]!.dictionary!; info[Data("name".utf8)] = .bytes(Data("bundle\(index)".utf8))
				let source = fixture.root.appendingPathComponent("first\(index).torrent")
				try BencodeValue.dictionary([Data("info".utf8): .dictionary(info)]).encoded().write(to: source)
				try FileManager.default.copyItem(at: fixture.root.appendingPathComponent("source/bundle"), to: fixture.root.appendingPathComponent("source/bundle\(index)"))
				_ = try await session.add(id: "first\(index)", source: source, destination: fixture.root.appendingPathComponent("source"))
			}
			var info = fixture.metadata.document.root["info"]!.dictionary!; info[Data("name".utf8)] = .bytes(Data("other".utf8))
			let secondSource = fixture.root.appendingPathComponent("other.torrent")
			try BencodeValue.dictionary([Data("info".utf8): .dictionary(info)]).encoded().write(to: secondSource)
			try FileManager.default.copyItem(at: fixture.root.appendingPathComponent("source/bundle"), to: fixture.root.appendingPathComponent("source/other"))
			_ = try await session.add(id: "second", source: secondSource, destination: fixture.root.appendingPathComponent("source"))
			for index in 0..<count { try await session.run(id: "first\(index)", running: true) }
			try await session.run(id: "second", running: true)
			for index in 0..<count {
				let destination = fixture.root.appendingPathComponent("moved\(index)")
				moving.append(Task { try await session.changeStorage(id: "first\(index)", change: .move(destination)) })
			}
			stage = "wait for durable journal"
			try await engineDeadline {
				var received = 0
				for await _ in entered.stream { received += 1; if received == min(count, 3) { return } }
				throw PeerFailure.closed
			}
			stage = "snapshot during move"
			let during = try await engineDeadline {
				while true {
					let snapshot = try await session.snapshot()
					if snapshot.transfers.prefix(count).allSatisfy({ $0.activity == .moving }) { return snapshot }
					try await Task.sleep(for: .milliseconds(5))
				}
			}
			#expect(during.transfers[0].state.storage.destination == fixture.root.appendingPathComponent("source"))
			stage = "pause unrelated transfer"
			try await engineDeadline { try await session.pause(id: "second") }
			stage = "export unrelated transfer"
			let exported = try await engineDeadline { try await session.export(id: "second") }
			#expect(try TorrentMetadata(exported).inspection.name == "other")
			stage = "snapshot after unrelated pause"
			let paused = try await engineDeadline { try await session.snapshot() }
			#expect(!paused.transfers[count].state.running && paused.transfers[0].activity == .moving)
			let stopping = Task { try await session.shutdown() }; shutdown = stopping
			// The journal is still held: the global barrier cannot finish its pause yet.
			stage = "snapshot while shutdown waits"
			let waiting = try await engineDeadline { try await session.snapshot() }
			#expect(waiting.transfers[0].activity == .moving)
			stage = "finish move and shutdown"
			for _ in 0..<count { release.signal() }
			for task in moving { try await task.value }; try await stopping.value
			let finished = try await session.snapshot()
			#expect(finished.transfers.allSatisfy { !$0.state.running && $0.activity == nil })
			#expect(finished.events.filter { $0.kind == "moved" && $0.id.hasPrefix("first") }.count == count)
			#expect(try await session.snapshot().events.isEmpty)
			for index in 0..<count {
				let destination = fixture.root.appendingPathComponent("moved\(index)")
				#expect(finished.transfers[index].state.storage.destination.path == destination.path)
				for file in fixture.metadata.inspection.files where !file.pad {
					let relative = file.path.split(separator: "/").dropFirst().joined(separator: "/")
					#expect(try Data(contentsOf: destination.appendingPathComponent("bundle\(index)/" + relative)) == Data(contentsOf: fixture.root.appendingPathComponent("source/other/" + relative)))
				}
			}
			try await session.close()
		} catch {
			for _ in 0..<count { release.signal() }; for task in moving { task.cancel() }; shutdown?.cancel()
			for task in moving { _ = try? await task.value }; _ = try? await shutdown?.value
			try? await session.close(); await fixture.clean(); throw PeerFailure.invalid("\(stage): \(error)")
		}
		await fixture.clean()
	}
} }
