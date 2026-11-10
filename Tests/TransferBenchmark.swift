import Foundation
import ButterTorrentMetadata
import ButterTorrentNetworking
import ButterTorrentStorage
import ButterTorrentEngine

@main struct TransferBenchmark {
	static func main() async throws {
		let arguments = CommandLine.arguments
		if arguments.count == 3, arguments[1] == "fixture" {
			try fixture(URL(fileURLWithPath: arguments[2], isDirectory: true))
		} else if arguments.count == 6, arguments[1] == "download", let port = UInt16(arguments[5]), port > 0 {
			let metadata = try TorrentMetadata(contentsOf: URL(fileURLWithPath: arguments[2]))
			try await download(metadata, destination: URL(fileURLWithPath: arguments[3]), state: URL(fileURLWithPath: arguments[4]), port: port)
		} else { throw PeerFailure.invalid("expected fixture ROOT or download TORRENT DESTINATION STATE PORT") }
	}

	static func fixture(_ root: URL) throws {
		let seed = root.appendingPathComponent("seed", isDirectory: true)
		try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
		let source = seed.appendingPathComponent("payload.bin")
		guard FileManager.default.createFile(atPath: source.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
		let file = try FileHandle(forWritingTo: source)
		var block = Data((0..<1_048_576).map { UInt8(($0 * 17 + $0 / 97) % 251) })
		for index in 0..<32 { block[0] = UInt8(index); try file.write(contentsOf: block) }
		try file.close()
		let hybrid = try TorrentCreator.create(source: source, trackers: [], isPrivate: false, pieceLength: 262144)
		try hybrid.write(to: root.appendingPathComponent("hybrid.torrent"))
		let document = try BencodeDocument(hybrid)
		var info = document.root["info"]!.dictionary!
		for key in ["meta version", "file tree"] { info[Data(key.utf8)] = nil }
		try BencodeValue.dictionary([Data("info".utf8): .dictionary(info)]).encoded().write(to: root.appendingPathComponent("v1.torrent"))
	}

	static func download(_ metadata: TorrentMetadata, destination: URL, state: URL, port: UInt16) async throws {
		let storage = try await TorrentStorage.open(metadata: metadata, destination: destination, stateDirectory: state)
		var configuration = TCPTransferConfiguration()
		configuration.encryption = .disabled
		configuration.enablePEX = false
		let engine = try await TCPTransfer.open(metadata: metadata, storage: storage, configuration: configuration)
		do {
			_ = try await engine.connect(to: NetworkEndpoint("127.0.0.1", port: port))
			let deadline = ProcessInfo.processInfo.systemUptime + 40
			while true {
				let status = await engine.snapshot()
				if let error = status.storageError { throw PeerFailure.invalid(error) }
				if status.complete { break }
				guard ProcessInfo.processInfo.systemUptime < deadline else { throw NetworkFailure.timedOut }
				try await Task.sleep(for: .milliseconds(20))
			}
			try await engine.shutdown(); try await storage.shutdown()
		} catch { try? await engine.shutdown(); try? await storage.shutdown(); throw error }
	}
}
