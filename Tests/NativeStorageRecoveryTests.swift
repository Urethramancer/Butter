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
		let storage = try await TorrentStorage.open(metadata: metadata, destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"), event: { event in
			if label(event) == boundary {
				do { try Data([1]).write(to: root.appendingPathComponent("ready"), options: .atomic) }
				catch { _exit(3) }
				raise(SIGSTOP)
			}
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
			("rename", "journal", false), ("rename", "published-0", false), ("rename", "entry-0", false), ("rename", "checkpoint", false),
			("move", "published-0", false), ("move", "entry-0", false),
			("move", "published-0", true), ("move", "entry-0", true), ("move", "checkpoint", true), ("move", "removed-0", true),
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
			print("PASS: killed \(operation)/\(boundary)\(cross ? " across volumes" : ""); recovered every managed byte")
		}
		try await copyCorruption(root: root.appendingPathComponent("copy-corruption"), target: volume.appendingPathComponent("target-corruption"))
		for iteration in 0..<4 {
			let work = root.appendingPathComponent("atomic-\(iteration)"), metadata = try await prepare(work)
			try await stopChild(work, operation: "atomic", boundary: "unused", target: work)
			let storage = try await TorrentStorage.open(metadata: metadata, destination: work.appendingPathComponent("data"), stateDirectory: work.appendingPathComponent("state"))
			let snapshot = try await storage.snapshot()
			try require(snapshot.downloaded == snapshot.uploaded && snapshot.verifiedPieces.count == storage.layout.pieceCount, "Atomic checkpoint contained mixed generations")
			try await storage.shutdown()
		}
		print("PASS: four atomic-checkpoint child interruptions")
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
	static func disk(root: URL, volume: URL) async throws {
		try require(fm.fileExists(atPath: volume.appendingPathComponent(".butter-native-storage-test").path), "Missing disposable-volume marker")
		let seed = root.appendingPathComponent("disk-seed"), metadata = try await prepare(seed)
		try metadata.document.original.write(to: volume.appendingPathComponent("fixture.torrent"))
		let state = volume.appendingPathComponent("state"), destination = volume.appendingPathComponent("data")
		let storage = try await TorrentStorage.open(metadata: metadata, destination: destination, stateDirectory: state)
		try await storage.importFiles(from: seed.appendingPathComponent("seed"))
		for piece in 0..<storage.layout.pieceCount { let valid = try await storage.verify(piece: piece); try require(valid, "Disk fixture failed verification") }
		let checkpoint = state.appendingPathComponent("checkpoint.plist"), original = try Data(contentsOf: checkpoint)
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
		try fm.removeItem(at: filler)
		try await storage.checkpoint(downloaded: 9, uploaded: 8)
		let valid = try await storage.verify(piece: 0); try require(valid, "Storage did not recover after freeing space")
		try await storage.shutdown()
		print("PASS: real ENOSPC preserves checkpoint and verified bytes; writes recover after space is freed")
	}
	static func readOnly(volume: URL) async throws {
		let state = volume.appendingPathComponent("state"), before = try Data(contentsOf: state.appendingPathComponent("checkpoint.plist"))
		let metadata = try TorrentMetadata(contentsOf: volume.appendingPathComponent("fixture.torrent"))
		var rejected = false
		do { _ = try await TorrentStorage.open(metadata: metadata, destination: volume.appendingPathComponent("data"), stateDirectory: state) }
		catch { let value = error as NSError; try require(value.domain == NSPOSIXErrorDomain && value.code == Int(EROFS), "Unexpected read-only error: \(error)"); rejected = true }
		try require(rejected && (try Data(contentsOf: state.appendingPathComponent("checkpoint.plist"))) == before, "Read-only restore changed saved state")
		print("PASS: actual read-only volume rejects mutable storage and preserves the checkpoint")
	}
}
