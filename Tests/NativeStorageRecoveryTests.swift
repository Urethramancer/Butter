import Foundation
import Darwin
import ButterTorrentMetadata
import ButterTorrentStorage

private func require(_ condition: Bool, _ message: String) throws {
	if !condition { throw NSError(domain: "Butter.StorageTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
private func full(_ error: Error) -> Bool {
	let value = error as NSError
	return (value.domain == NSPOSIXErrorDomain && value.code == Int(ENOSPC)) || (value.userInfo[NSUnderlyingErrorKey] as? NSError).map { full($0) } == true
}
private func contents(_ index: Int) -> Data { Data((0..<65536).map { UInt8(($0 * 31 + index * 17) % 251) }) }
private func name(_ index: Int) -> String { String(format: "file-%02d", index) }

@main struct NativeStorageRecoveryTests {
	static var fm: FileManager { .default }
	static func main() async {
		do {
			let args = CommandLine.arguments
			switch args[1] {
			case "--child": try await child(root: URL(fileURLWithPath: args[2]), operation: args[3], boundary: args[4], target: URL(fileURLWithPath: args[5]))
			case "--disk": try await disk(root: URL(fileURLWithPath: args[2]), volume: URL(fileURLWithPath: args[3]))
			case "--read-only": try await readOnly(volume: URL(fileURLWithPath: args[2]))
			default: try await interruptions(root: URL(fileURLWithPath: args[1]), volume: URL(fileURLWithPath: args[2]))
			}
		} catch { try? FileHandle.standardError.write(contentsOf: Data("FAIL: \(error)\n".utf8)); exit(1) }
	}
	static func prepare(_ root: URL, selected: Bool = true, importData: Bool = true) async throws -> TorrentMetadata {
		let bundle = root.appendingPathComponent("seed/bundle")
		try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
		for index in 0..<8 { try contents(index).write(to: bundle.appendingPathComponent(name(index))) }
		let data = try TorrentCreator.create(source: bundle, trackers: [], isPrivate: false, pieceLength: 16384)
		try data.write(to: root.appendingPathComponent("fixture.torrent"))
		let metadata = try TorrentMetadata(data)
		let storage = try await TorrentStorage.open(metadata: metadata, destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"), selected: metadata.inspection.files.map { !$0.pad && selected })
		if importData {
			try await storage.importFiles(from: root.appendingPathComponent("seed"))
			for piece in 0..<storage.layout.pieceCount { let valid = try await storage.verify(piece: piece); try require(valid, "Preparation hash failed") }
		}
		try await storage.shutdown(); return metadata
	}
	static func label(_ event: StorageEvent) -> String {
		switch event {
		case .journalDurable: "journal"
		case .filePublished(let index): "published-\(index)"
		case .entryDurable(let index): "entry-\(index)"
		case .checkpointDurable: "checkpoint"
		case .sourceRemoved(let index): "removed-\(index)"
		case .sourceWillBeClaimed(let index): "claiming-\(index)"
		case .sourceClaimed(let index): "claimed-\(index)"
		case .pieceLayersChanged: "piece-layers"
		}
	}
	static func files(in directory: URL) throws -> [Data] {
		var result: [Data] = []
		if let iterator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) {
			for case let url as URL in iterator where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { result.append(try Data(contentsOf: url)) }
		}
		return result
	}
	static func child(root: URL, operation: String, boundary: String, target: URL) async throws {
		let metadata = try TorrentMetadata(contentsOf: root.appendingPathComponent("fixture.torrent"))
		if operation == "repository-publish" || operation == "repository-discard" {
			let repository = TransferRepository(root: root.appendingPathComponent("library"), event: { event in
				if String(describing: event) == boundary { stopAtBoundary(root) }
			})
			if operation == "repository-discard" { try await repository.discard(id: "transfer") }
			else { _ = try await publishRepositoryStorage(repository, id: "transfer", metadata: metadata, destination: root.appendingPathComponent("data")) }
			return
		}
		let storage = try await TorrentStorage.open(metadata: metadata, destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"), event: { event in
			if label(event) == boundary { stopAtBoundary(root) }
		})
		switch operation {
		case "rename":
			let paths = Dictionary(uniqueKeysWithValues: metadata.inspection.files.filter { !$0.pad }.map { ($0.index, "renamed/" + URL(fileURLWithPath: $0.path).lastPathComponent) })
			try await storage.rename(paths)
		case "move": try await storage.move(to: target)
		case "trash": _ = try await storage.trash(directory: target)
		case "import": try await storage.importFiles(from: root.appendingPathComponent("seed"))
		case "select": try await storage.select(metadata.inspection.files.map { !$0.pad })
		case "atomic":
			for generation in 0..<10000 {
				try await storage.checkpoint(downloaded: Int64(generation), uploaded: Int64(generation))
				if generation == 0 { try Data([1]).write(to: root.appendingPathComponent("ready")) }
			}
		default: throw StorageFailure.invalid("fixture operation")
		}
	}
	static func stopAtBoundary(_ root: URL) {
		do { try Data([1]).write(to: root.appendingPathComponent("ready"), options: .atomic) }
		catch { _exit(3) }
		raise(SIGSTOP)
	}
	static func openRepositoryStorage(_ state: PreparedTransferState, metadata: TorrentMetadata, destination: URL) async throws {
		let storage = try await TorrentStorage.open(metadata: metadata, destination: destination, stateDirectory: state.directory, preparedState: state)
		try await storage.shutdown()
	}
	@discardableResult static func publishRepositoryStorage(_ repository: TransferRepository, id: String, metadata: TorrentMetadata, destination: URL) async throws -> PreparedTransferState {
		let state = try await repository.prepare(id: id, restore: false)
		try await openRepositoryStorage(state, metadata: metadata, destination: destination)
		try await repository.publish(id: id, metadata: metadata, state: state)
		return state
	}
	static func stopChild(_ root: URL, operation: String, boundary: String, target: URL) async throws {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
		process.arguments = ["--child", root.path, operation, boundary, target.path]
		try process.run()
		defer { if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() } }
		let deadline = ProcessInfo.processInfo.systemUptime + 10
		while !fm.fileExists(atPath: root.appendingPathComponent("ready").path), process.isRunning, ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(5)) }
		try require(fm.fileExists(atPath: root.appendingPathComponent("ready").path), "Child did not reach \(operation)/\(boundary)")
		if operation == "atomic" { try await Task.sleep(for: .milliseconds(8)) }
		kill(process.processIdentifier, SIGKILL)
		while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(5)) }
		try require(!process.isRunning, "Child failed to terminate")
	}
	static func interruptions(root: URL, volume: URL) async throws {
		let cases: [(String, String, Bool)] = [
			("rename", "journal", false), ("rename", "claimed-0", false), ("rename", "published-0", false), ("rename", "entry-0", false), ("rename", "checkpoint", false),
			("move", "claimed-0", false), ("move", "published-0", false), ("move", "entry-0", false),
			("move", "published-0", true), ("move", "entry-0", true), ("move", "checkpoint", true), ("move", "claimed-0", true), ("move", "removed-0", true),
			("trash", "published-0", false), ("trash", "entry-0", false),
			("trash", "entry-0", true), ("trash", "removed-0", true),
			("import", "published-0", false), ("import", "entry-0", false),
			("select", "published-0", false), ("select", "entry-0", false)
		]
		for (iteration, fixture) in cases.enumerated() {
			let (operation, boundary, cross) = fixture
			let work = root.appendingPathComponent("case-\(iteration)")
			let metadata = try await prepare(work, selected: operation != "select", importData: operation != "import")
			let target = (cross ? volume : work).appendingPathComponent("target-\(iteration)")
			try await stopChild(work, operation: operation, boundary: boundary, target: target)
			let recreatedSource = operation == "move" && !cross && boundary == "published-0"
			if recreatedSource { try Data([99]).write(to: work.appendingPathComponent("data/bundle/" + name(0)), options: .atomic) }
			// Every managed byte must survive outside the untouched seed backup.
			var candidates: [Data] = []
			for directory in [work.appendingPathComponent("data"), work.appendingPathComponent("state/unwanted"), target] {
				candidates += try files(in: directory)
			}
			if operation != "import" { for index in 0..<8 { try require(candidates.contains(contents(index)), "Interrupted operation lost managed bytes") } }
			let storage = try await TorrentStorage.open(metadata: metadata, destination: work.appendingPathComponent("data"), stateDirectory: work.appendingPathComponent("state"))
			let pending = try await storage.snapshot()
			try require(pending.needsRecovery && pending.verifiedPieces.isEmpty, "Unreconciled progress was advertised")
			if boundary == "published-0" && (cross || operation == "import") {
				var rejected = false
				do { try await storage.recover() } catch StorageFailure.recoveryRequired { rejected = true }
				try require(rejected, "Unrecorded copy was accepted without review")
				try await storage.recover(acceptMatchingCopies: true)
			} else { try await storage.recover() }
			let snapshot = try await storage.snapshot()
			try require(!snapshot.needsRecovery, "Recovery remained pending")
			if operation == "trash" {
				try require(snapshot.trashReceipts.count == 8, "Trash receipts were lost")
				let trashed = try snapshot.trashReceipts.map { try Data(contentsOf: $0) }
				for index in 0..<8 { try require(trashed.contains(contents(index)), "Trash receipt bytes changed") }
			} else {
				for file in metadata.inspection.files where !file.pad {
					try require(try Data(contentsOf: snapshot.destination.appendingPathComponent(snapshot.paths[file.index])) == contents(file.index), "Recovered file bytes differ")
				}
				for piece in 0..<storage.layout.pieceCount { let valid = try await storage.verify(piece: piece); try require(valid, "Recovered piece failed verification") }
			}
			try await storage.shutdown()
			if recreatedSource { try require(try Data(contentsOf: work.appendingPathComponent("data/bundle/" + name(0))) == Data([99]), "Rename recovery removed a recreated source") }
			print("PASS: killed \(operation)/\(boundary)\(cross ? " across volumes" : ""); recovered every managed byte")
		}
		try await copyCorruption(root: root.appendingPathComponent("copy-corruption"), target: volume.appendingPathComponent("target-corruption"))
		for afterClaim in [false, true] {
			try await sourceReplacement(root: root.appendingPathComponent("source-replacement-\(afterClaim)"), target: volume.appendingPathComponent("target-replacement-\(afterClaim)"), afterClaim: afterClaim)
			try await renameReplacement(root: root.appendingPathComponent("rename-replacement-\(afterClaim)"), afterClaim: afterClaim)
		}
		try await claimReplacement(root: root.appendingPathComponent("claim-replacement"), target: volume.appendingPathComponent("target-claim-replacement"))
		for iteration in 0..<4 {
			let work = root.appendingPathComponent("atomic-\(iteration)"), metadata = try await prepare(work)
			try await stopChild(work, operation: "atomic", boundary: "unused", target: work)
			let storage = try await TorrentStorage.open(metadata: metadata, destination: work.appendingPathComponent("data"), stateDirectory: work.appendingPathComponent("state"))
			let snapshot = try await storage.snapshot()
			try require(snapshot.downloaded == snapshot.uploaded && snapshot.verifiedPieces.count == storage.layout.pieceCount, "Atomic checkpoint contained mixed generations")
			try await storage.shutdown()
		}
		print("PASS: four atomic-checkpoint child interruptions")
		try await repositoryPublicationInterruptions(root: root)
		try await repositoryDiscardInterruptions(root: root)
	}
	static func repositoryPublicationInterruptions(root: URL) async throws {
		for boundary in ["stagingDurable", "checkpointDirectoryDurable", "torrentDurable", "locatorDurable"] {
			let work = root.appendingPathComponent("repository-\(boundary)")
			let metadata = try await prepare(work), library = work.appendingPathComponent("library"), destination = work.appendingPathComponent("data")
			try await stopChild(work, operation: "repository-publish", boundary: boundary, target: work)
			let repository = TransferRepository(root: library)
			let committed = boundary == "locatorDurable"
			let retained = try await repository.retainedMetadata(id: "transfer")
			try require((retained != nil) == committed, "A partial publication became visible")
			let state = try await repository.prepare(id: "transfer", restore: committed)
			try await openRepositoryStorage(state, metadata: metadata, destination: destination)
			try await repository.publish(id: "transfer", metadata: metadata, state: state)
			let paths = try fm.contentsOfDirectory(atPath: library.path)
			try require(paths.filter { $0.hasPrefix(".native-") }.count == 1 && !paths.contains("transfer.native-stage.plist"), "Publication left an orphaned checkpoint")
			try require(try await repository.retainedMetadata(id: "transfer")?.originalInfo == metadata.originalInfo, "Recovered identity differs")
			for index in 0..<8 { try require(try Data(contentsOf: destination.appendingPathComponent("bundle/" + name(index))) == contents(index), "Publication recovery changed payload bytes") }
			print("PASS: killed repository publication at \(boundary); recovered one checkpoint and exact payloads")
		}
	}
	static func repositoryDiscardInterruptions(root: URL) async throws {
		for boundary in ["discardDurable", "discardCheckpointRemoved", "discardFilesRemoved"] {
			let work = root.appendingPathComponent("repository-\(boundary)")
			let metadata = try await prepare(work), library = work.appendingPathComponent("library"), destination = work.appendingPathComponent("data")
			let repository = TransferRepository(root: library)
			let state = try await publishRepositoryStorage(repository, id: "transfer", metadata: metadata, destination: destination)
			let legacy = library.appendingPathComponent("transfer.resume"), other = library.appendingPathComponent("other")
			try Data([12]).write(to: legacy); try Data([34]).write(to: other)
			try await stopChild(work, operation: "repository-discard", boundary: boundary, target: work)
			var rejected = false
			do { _ = try await repository.retainedMetadata(id: "transfer") } catch StorageFailure.recoveryRequired { rejected = true }
			try require(rejected, "A partially discarded transfer remained restorable")
			if boundary == "discardFilesRemoved" {
				let replacement = library.appendingPathComponent("transfer.torrent")
				try Data([42]).write(to: replacement)
				rejected = false
				do { try await repository.discard(id: "transfer") } catch StorageFailure.recoveryRequired { rejected = true }
				try require(rejected && (try Data(contentsOf: replacement)) == Data([42]), "Discard deleted a replacement file")
				try fm.removeItem(at: replacement)
			}
			try await repository.discard(id: "transfer")
			try require(try await repository.retainedMetadata(id: "transfer") == nil, "Discard did not remove the locator")
			try require(!fm.fileExists(atPath: state.directory.path) && !fm.fileExists(atPath: library.appendingPathComponent("transfer.native-discard.plist").path), "Discard did not retire its checkpoint and journal")
			try require(try Data(contentsOf: legacy) == Data([12]) && Data(contentsOf: other) == Data([34]), "Discard touched unrelated repository files")
			for index in 0..<8 { try require(try Data(contentsOf: destination.appendingPathComponent("bundle/" + name(index))) == contents(index), "Discard changed payload bytes") }
			print("PASS: killed repository discard at \(boundary); retry preserved payload, replacement and legacy files")
		}
	}
	static func copyCorruption(root: URL, target: URL) async throws {
		let metadata = try await prepare(root)
		let storage = try await TorrentStorage.open(metadata: metadata, destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"), event: { event in
			if event == .entryDurable(0), let handle = try? FileHandle(forWritingTo: target.appendingPathComponent("bundle/" + name(0))) {
				try? handle.write(contentsOf: Data([9])); try? handle.close()
			}
		})
		var rejected = false
		do { try await storage.move(to: target) } catch StorageFailure.recoveryRequired { rejected = true }
		try require(rejected, "Changed destination did not block source deletion")
		for index in 0..<8 { try require(try Data(contentsOf: root.appendingPathComponent("data/bundle/" + name(index))) == contents(index), "Changed copy caused original bytes to be deleted") }
		let pending = try await storage.snapshot()
		try require(pending.needsRecovery && pending.verifiedPieces.isEmpty, "Changed destination advertised progress")
		print("PASS: cross-volume destination corruption retains every original and blocks verified progress")
	}
	static func sourceReplacement(root: URL, target: URL, afterClaim: Bool) async throws {
		let metadata = try await prepare(root), source = root.appendingPathComponent("data/bundle/" + name(0)), replacement = Data([99, 98, 97])
		let storage = try await TorrentStorage.open(metadata: metadata, destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"), event: { event in
			if event == (afterClaim ? .sourceClaimed(0) : .sourceWillBeClaimed(0)) { try? replacement.write(to: source, options: .atomic) }
		})
		var rejected = false
		do { try await storage.move(to: target) } catch StorageFailure.recoveryRequired { rejected = true }
		try require(rejected != afterClaim, "Source identity must be validated after claiming")
		try require(try Data(contentsOf: source) == replacement, "Cross-volume cleanup deleted a replacement source")
		for index in 0..<8 { try require(try Data(contentsOf: target.appendingPathComponent("bundle/" + name(index))) == contents(index), "Cross-volume cleanup changed the verified destination") }
		if rejected {
			// Explicitly retain the replacement elsewhere before completing the interrupted move.
			try fm.moveItem(at: source, to: root.appendingPathComponent("retained-replacement"))
			try await storage.recover()
		}
		try await storage.shutdown()
		print("PASS: cross-volume source replacement \(afterClaim ? "after" : "before") claim is retained")
	}
	static func renameReplacement(root: URL, afterClaim: Bool) async throws {
		let metadata = try await prepare(root), source = root.appendingPathComponent("data/bundle/" + name(0)), target = root.appendingPathComponent("moved"), replacement = Data([21, 22])
		let storage = try await TorrentStorage.open(metadata: metadata, destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"), event: { event in
			if event == (afterClaim ? .sourceClaimed(0) : .sourceWillBeClaimed(0)) { try? replacement.write(to: source, options: .atomic) }
		})
		var rejected = false
		do { try await storage.move(to: target) } catch StorageFailure.recoveryRequired { rejected = true }
		try require(rejected != afterClaim, "Rename must validate ownership after claiming")
		try require(try Data(contentsOf: source) == replacement, "Rename lost a replacement source")
		if afterClaim {
			for index in 0..<8 { try require(try Data(contentsOf: target.appendingPathComponent("bundle/" + name(index))) == contents(index), "Rename changed managed bytes") }
			try await storage.shutdown()
		} else { try require(try await storage.snapshot().needsRecovery, "Rejected rename must retain its journal") }
		print("PASS: same-volume replacement \(afterClaim ? "after" : "before") source claim is retained")
	}
	static func claimReplacement(root: URL, target: URL) async throws {
		let metadata = try await prepare(root)
		try await stopChild(root, operation: "move", boundary: "claimed-0", target: target)
		let source = root.appendingPathComponent("data/bundle"), replacement = Data([87, 86, 85])
		let claims = try fm.contentsOfDirectory(atPath: source.path).filter { $0.hasPrefix(".butter-source-") }
		try require(claims.count == 1, "Interrupted cleanup retains exactly one source claim")
		let claimed = source.appendingPathComponent(claims[0])
		try replacement.write(to: claimed, options: .atomic)
		let storage = try await TorrentStorage.open(metadata: metadata, destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"))
		var rejected = false
		do { try await storage.recover() } catch StorageFailure.recoveryRequired { rejected = true }
		try require(rejected && !fm.fileExists(atPath: source.appendingPathComponent(name(0)).path), "Recovery must not relocate an unrecognised claimed file")
		try require(try Data(contentsOf: claimed) == replacement, "Recovery must retain a replaced claim")
		try fm.moveItem(at: claimed, to: root.appendingPathComponent("retained-claim"))
		try await storage.recover(); try await storage.shutdown()
		print("PASS: replaced cleanup claim is retained for explicit recovery")
	}
	static func disk(root: URL, volume: URL) async throws {
		try require(fm.fileExists(atPath: volume.appendingPathComponent(".butter-native-storage-test").path), "Missing disposable-volume marker")
		let seed = root.appendingPathComponent("disk-seed"), metadata = try await prepare(seed)
		try metadata.document.original.write(to: volume.appendingPathComponent("fixture.torrent"))
		let state = volume.appendingPathComponent("state"), destination = volume.appendingPathComponent("data")
		let storage = try await TorrentStorage.open(metadata: metadata, destination: destination, stateDirectory: state)
		try await storage.importFiles(from: seed.appendingPathComponent("seed"))
		for piece in 0..<storage.layout.pieceCount { let valid = try await storage.verify(piece: piece); try require(valid, "Disk fixture failed verification") }
		let checkpoint = state.appendingPathComponent("checkpoint.plist"), original = try Data(contentsOf: checkpoint)
		let library = volume.appendingPathComponent("library"), repository = TransferRepository(root: library)
		let repositoryDestination = volume.appendingPathComponent("repository-data")
		let discard = try await publishRepositoryStorage(repository, id: "discard", metadata: metadata, destination: volume.appendingPathComponent("discard-data"))
		let prepared = try await repository.prepare(id: "transfer", restore: false)
		try await openRepositoryStorage(prepared, metadata: metadata, destination: repositoryDestination)
		let filler = volume.appendingPathComponent("filler")
		try Data().write(to: filler)
		let handle = try FileHandle(forWritingTo: filler)
		var exhausted = false
		for size in [1_048_576, 4096, 512] {
			do { for _ in 0..<65536 { try handle.write(contentsOf: Data(repeating: 31, count: size)) } }
			catch { guard full(error) else { throw error }; exhausted = true }
		}
		try handle.close(); try require(exhausted, "Disposable volume did not fill")
		var rejected = false
		do { try await storage.checkpoint(downloaded: 9, uploaded: 8) } catch { guard full(error) else { throw error }; rejected = true }
		try require(rejected && (try Data(contentsOf: checkpoint)) == original, "ENOSPC changed the last durable checkpoint")
		let first = destination.appendingPathComponent("bundle/" + name(0)), previous = try Data(contentsOf: first)
		rejected = false
		do { try await storage.write(piece: 0, offset: 0, data: Data([42])) } catch { guard full(error) else { throw error }; rejected = true }
		try require(rejected && (try Data(contentsOf: first)) == previous, "Failed durable invalidation modified verified bytes")
		rejected = false
		do { try await repository.publish(id: "transfer", metadata: metadata, state: prepared) } catch { guard full(error) else { throw error }; rejected = true }
		try require(rejected && !fm.fileExists(atPath: library.appendingPathComponent("transfer.native.plist").path), "ENOSPC published an incomplete locator")
		rejected = false
		do { try await repository.discard(id: "discard") } catch { guard full(error) else { throw error }; rejected = true }
		try require(rejected && fm.fileExists(atPath: discard.directory.appendingPathComponent("checkpoint.plist").path), "ENOSPC removed the checkpoint before journalling discard")
		try fm.removeItem(at: filler)
		try await repository.abandon(prepared)
		try await repository.discard(id: "discard")
		try require(!fm.fileExists(atPath: discard.directory.path), "Discard did not recover after freeing space")
		let retry = try await repository.prepare(id: "transfer", restore: false)
		try await openRepositoryStorage(retry, metadata: metadata, destination: repositoryDestination)
		try await repository.publish(id: "transfer", metadata: metadata, state: retry)
		try await storage.checkpoint(downloaded: 9, uploaded: 8)
		let valid = try await storage.verify(piece: 0); try require(valid, "Storage did not recover after freeing space")
		try await storage.shutdown()
		print("PASS: real ENOSPC preserves checkpoint and verified bytes; writes recover after space is freed")
		print("PASS: real ENOSPC prevents repository publication; the same transfer publishes after space is freed")
		print("PASS: real ENOSPC preserves the checkpoint before discard; retry completes after space is freed")
	}
	static func readOnly(volume: URL) async throws {
		let state = volume.appendingPathComponent("state"), before = try Data(contentsOf: state.appendingPathComponent("checkpoint.plist"))
		let metadata = try TorrentMetadata(contentsOf: volume.appendingPathComponent("fixture.torrent"))
		var rejected = false
		do { _ = try await TorrentStorage.open(metadata: metadata, destination: volume.appendingPathComponent("data"), stateDirectory: state) }
		catch { let value = error as NSError; try require(value.domain == NSPOSIXErrorDomain && value.code == Int(EROFS), "Unexpected read-only error: \(error)"); rejected = true }
		try require(rejected && (try Data(contentsOf: state.appendingPathComponent("checkpoint.plist"))) == before, "Read-only restore changed saved state")
		let library = volume.appendingPathComponent("library"), repository = TransferRepository(root: library)
		let locator = library.appendingPathComponent("transfer.native.plist"), previous = try Data(contentsOf: locator)
		rejected = false
		do { try await repository.discard(id: "transfer") }
		catch { let value = error as NSError; try require(value.domain == NSPOSIXErrorDomain && value.code == Int(EROFS), "Unexpected read-only discard error: \(error)"); rejected = true }
		try require(rejected && (try Data(contentsOf: locator)) == previous, "Read-only discard changed the repository locator")
		print("PASS: actual read-only volume rejects mutable storage and preserves the checkpoint")
		print("PASS: actual read-only volume rejects repository discard and preserves the locator")
	}
}
