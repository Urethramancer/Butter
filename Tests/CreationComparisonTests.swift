import Foundation
import ButterTorrentMetadata

@main struct CreationComparisonTests {
	struct Fixture: Codable { let torrent: String; let destination: String; let output: String }
	static func main() async {
		do {
			guard CommandLine.arguments.count == 2 else { throw MetadataError.invalid("expected disposable root") }
			let root = URL(fileURLWithPath: CommandLine.arguments[1]), fm = FileManager.default
			let seed = root.appendingPathComponent("seed")
			try fm.createDirectory(at: seed.appendingPathComponent("Bundle/nested"), withIntermediateDirectories: true)
			let payload = Data((0..<65_537).map { UInt8(($0 * 71 + $0 / 97) % 251) })
			try payload.write(to: seed.appendingPathComponent("single.bin"))
			for (path, count) in [("Bundle/a", 1), ("Bundle/b", 16383), ("Bundle/c", 16384), ("Bundle/nested/d", 16385), ("Bundle/nested/e", 32771), ("Bundle/empty", 0)] {
				try payload.prefix(count).write(to: seed.appendingPathComponent(path))
			}
			try fm.createSymbolicLink(at: seed.appendingPathComponent("Bundle/link"), withDestinationURL: seed.appendingPathComponent("single.bin"))
			let engine = SwiftEngineClient(storage: root.appendingPathComponent("native-engine"))
			var fixtures: [Fixture] = []
			for (index, path) in ["single.bin", "Bundle"].enumerated() {
				let result = try await engine.perform("create", ["id": "native-\(index)", "source": seed.appendingPathComponent(path).path, "trackers": [], "private": false])
				let response = try JSONDecoder().decode([String: String].self, from: result)
				guard let torrent = response["source"], response["destination"] == seed.path, engine.creationProgress == 1 else {
					throw MetadataError.invalid("creation response or progress differs")
				}
				fixtures.append(Fixture(torrent: torrent, destination: seed.path, output: root.appendingPathComponent("download-\(index)").path))
			}
			// Also force larger pieces so v2 zero-subtree padding is exercised by the reference.
			for length in [32768, 65536] {
				let bytes = try TorrentCreator.create(source: seed.appendingPathComponent("Bundle"), trackers: [], isPrivate: false, pieceLength: length)
				let file = root.appendingPathComponent("piece-\(length).torrent"); try bytes.write(to: file)
				fixtures.append(Fixture(torrent: file.path, destination: seed.path, output: root.appendingPathComponent("download-\(length)").path))
			}
			// Force v2-only reference transfers as well, so SHA-1 cannot mask bad Merkle data.
			for (index, fixture) in fixtures.enumerated() {
				var rootFields = try BencodeDocument(Data(contentsOf: URL(fileURLWithPath: fixture.torrent))).root.dictionary!
				var info = rootFields[Data("info".utf8)]!.dictionary!
				for key in ["pieces", "files", "length"] { info[Data(key.utf8)] = nil }
				rootFields[Data("info".utf8)] = .dictionary(info)
				let file = root.appendingPathComponent("v2-\(index).torrent")
				try BencodeValue.dictionary(rootFields).encoded().write(to: file)
				fixtures.append(Fixture(torrent: file.path, destination: seed.path, output: root.appendingPathComponent("v2-download-\(index)").path))
			}
			let gate = AsyncStream<Void>.makeStream()
			let cancelled = Task {
				for await _ in gate.stream { break }
				return try await engine.perform("create", ["id": "cancelled", "source": seed.appendingPathComponent("single.bin").path])
			}
			cancelled.cancel()
			gate.continuation.finish()
			do { _ = try await cancelled.value; throw MetadataError.invalid("cancelled creation succeeded") }
			catch let error as MetadataError { throw error }
			catch { /* The adapter exposes cancellation through its existing error boundary. */ }
			_ = try await engine.perform("shutdown")
			guard !fm.fileExists(atPath: root.appendingPathComponent("native-engine/cancelled.torrent").path) else { throw MetadataError.invalid("cancelled creation wrote metadata") }
			let blockedStorage = root.appendingPathComponent("blocked-storage")
			try Data([1]).write(to: blockedStorage)
			let failureEngine = SwiftEngineClient(storage: blockedStorage)
			do { _ = try await failureEngine.perform("create", ["id": "failure", "source": seed.appendingPathComponent("single.bin").path]); throw MetadataError.invalid("storage failure was ignored") }
			catch let error as MetadataError { throw error }
			catch { }
			try fm.removeItem(at: blockedStorage)
			_ = try await failureEngine.perform("create", ["id": "recovered", "source": seed.appendingPathComponent("single.bin").path])
			guard try Data(contentsOf: seed.appendingPathComponent("single.bin")) == payload else { throw MetadataError.invalid("creation changed source bytes") }
			try JSONEncoder().encode(fixtures).write(to: root.appendingPathComponent("creation.json"))
			print("PASS: native creation response, progress, cancellation, failed publication and recovery")
		} catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
	}
}
