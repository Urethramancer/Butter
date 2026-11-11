import Foundation
import ButterTorrentMetadata
import ButterTorrentStorage

// Disposable many-file storage fixture; timing excludes metadata creation.
@main struct StorageBenchmark {
	static func main() async throws {
		let arguments = CommandLine.arguments
		guard arguments.count == 4 else { throw StorageFailure.invalid("expected fixture ROOT FILES or write ROOT FORMAT") }
		let root = URL(fileURLWithPath: arguments[2])
		if arguments[1] == "fixture", let files = Int(arguments[3]), (1...1024).contains(files) {
			let source = root.appendingPathComponent("seed/bundle")
			try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
			for index in 0..<files {
				let bytes = Data((0..<65536).map { UInt8(truncatingIfNeeded: $0 * 17 + index) })
				try bytes.write(to: source.appendingPathComponent(String(format: "file-%04d", index)))
			}
			let hybrid = try TorrentCreator.create(source: source, trackers: [], isPrivate: false, pieceLength: 65536)
			try hybrid.write(to: root.appendingPathComponent("hybrid.torrent"))
			var info = try BencodeDocument(hybrid).root["info"]!.dictionary!
			for key in ["meta version", "file tree"] { info[Data(key.utf8)] = nil }
			try BencodeValue.dictionary([Data("info".utf8): .dictionary(info)]).encoded().write(to: root.appendingPathComponent("v1.torrent"))
		} else if arguments[1] == "write", ["v1", "hybrid"].contains(arguments[3]) {
			try await write(root, format: arguments[3])
		} else { throw StorageFailure.invalid("benchmark arguments") }
	}
	static func write(_ root: URL, format: String) async throws {
		let metadata = try TorrentMetadata(contentsOf: root.appendingPathComponent(format + ".torrent"))
		let run = root.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: run) }
		let start = ProcessInfo.processInfo.systemUptime
		let storage = try await TorrentStorage.open(metadata: metadata, destination: run.appendingPathComponent("data"), stateDirectory: run.appendingPathComponent("state"))
		for piece in 0..<storage.layout.pieceCount {
			let count = try storage.layout.length(of: piece)
			var data = Data()
			for segment in try storage.layout.segments(piece: piece, count: count) {
				if segment.padding { data.append(Data(repeating: 0, count: segment.count)); continue }
				let input = try FileHandle(forReadingFrom: root.appendingPathComponent("seed/" + storage.layout.files[segment.file].path))
				defer { try? input.close() }
				try input.seek(toOffset: UInt64(segment.offset))
				guard let bytes = try input.read(upToCount: segment.count), bytes.count == segment.count else { throw StorageFailure.invalid("fixture read") }
				data.append(bytes)
			}
			try await storage.write(piece: piece, offset: 0, data: data)
			guard try await storage.verify(piece: piece) else { throw StorageFailure.invalid("benchmark verification") }
		}
		try await storage.shutdown()
		let elapsed = ProcessInfo.processInfo.systemUptime - start
		for file in storage.layout.files where !file.pad {
			guard try Data(contentsOf: root.appendingPathComponent("seed/" + file.path)) == Data(contentsOf: run.appendingPathComponent("data/" + file.path)) else { throw StorageFailure.invalid("benchmark bytes") }
		}
		let restored = try await TorrentStorage.open(metadata: metadata, destination: run.appendingPathComponent("data"), stateDirectory: run.appendingPathComponent("state"))
		guard try await restored.snapshot().verifiedPieces.count == storage.layout.pieceCount else { throw StorageFailure.invalid("benchmark restart") }
		try await restored.shutdown()
		print(String(format: "%@ files=%d write-and-flush-seconds=%.3f", format, storage.layout.files.filter { !$0.pad }.count, elapsed))
	}
}
