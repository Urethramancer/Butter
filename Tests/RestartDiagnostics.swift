import Foundation
import Darwin
import CryptoKit
import ButterTorrentMetadata
import ButterTorrentStorage

// Controlled storage-policy diagnostic. No network/background scheduler races;
// managed progressive advertisements are covered by LazyVerificationTests.
@main struct RestartDiagnostics {
	static func emit(_ phase: String, verified: Int = 0, pending: Int = 0) throws {
		var usage = rusage(); guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw CocoaError(.fileReadUnknown) }
		let value: [String: Any] = ["phase": phase, "time": ProcessInfo.processInfo.systemUptime,
			"cpu": Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6,
			"verified": verified, "pending": pending, "storage": StorageDiagnostics.snapshot()]
		var bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]); bytes.append(10)
		try FileHandle.standardOutput.write(contentsOf: bytes)
	}
	static func main() async throws {
		let args = CommandLine.arguments
		guard args.count == 6, ["single", "many"].contains(args[2]), ["v1", "v2", "hybrid"].contains(args[3]), ["complete", "partial"].contains(args[4]), ["eager", "deferred"].contains(args[5]) else { throw StorageFailure.invalid("ROOT single/many v1/v2/hybrid complete/partial eager/deferred") }
		let root = URL(fileURLWithPath: args[1]), many = args[2] == "many", partial = args[4] == "partial"
		let destination = root.appendingPathComponent("data"), state = root.appendingPathComponent("state"), source = destination.appendingPathComponent(many ? "bundle" : "payload")
		try FileManager.default.createDirectory(at: many ? source : destination, withIntermediateDirectories: true)
		let block = Data((0..<65536).map { UInt8(($0 * 17 + $0 / 97) % 251) })
		for index in 0..<(many ? 128 : 1) {
			let url = many ? source.appendingPathComponent(String(format: "%03d", index)) : source
			guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
			let handle = try FileHandle(forWritingTo: url)
			for _ in 0..<(many ? 16 : 2048) { try handle.write(contentsOf: block) }
			try handle.synchronize(); try handle.close()
		}
		let hybrid = try BencodeDocument(TorrentCreator.create(source: source, trackers: [], isPrivate: false, pieceLength: 1_048_576))
		var document = hybrid.root.dictionary!, info = hybrid.root["info"]!.dictionary!
		for key in args[3] == "v1" ? ["meta version", "file tree"] : args[3] == "v2" ? ["pieces", "files", "length"] : [] { info[Data(key.utf8)] = nil }
		document[Data("info".utf8)] = .dictionary(info)
		if args[3] == "v1" { document[Data("piece layers".utf8)] = nil }
		let metadata = try TorrentMetadata(BencodeValue.dictionary(document).encoded())
		let initial = try await TorrentStorage.open(metadata: metadata, destination: destination, stateDirectory: state, checkpointPolicy: .managed)
		for piece in 0..<128 { guard try await initial.verify(piece: piece) else { throw StorageFailure.invalid("fixture verification") } }
		try await initial.shutdown()
		if partial {
			if many { for index in 64..<128 { try FileManager.default.removeItem(at: source.appendingPathComponent(String(format: "%03d", index))) } }
			else { let handle = try FileHandle(forWritingTo: source); try handle.truncate(atOffset: 64 * 1_048_576); try handle.synchronize(); try handle.close() }
		}
		try emit("begin")
		let storage = try await TorrentStorage.open(metadata: metadata, destination: destination, stateDirectory: state, checkpointPolicy: .managed, verificationPolicy: args[5] == "eager" ? .eager : .deferred)
		let opened = try await storage.snapshot(); try emit("open", verified: opened.verifiedPieces.count, pending: opened.pendingVerificationCount)
		guard try await storage.recoverExistingPiece(0) else { throw StorageFailure.invalid("first availability") }
		try emit("first-verified")
		// Fixed 64-piece demand in the populated half, independent of timings.
		for index in 0..<64 { guard try await storage.recoverExistingPiece((index * 17) % 64) else { throw StorageFailure.invalid("demand verification") } }
		try emit("demand-64")
		for piece in 0..<128 { _ = try await storage.recoverExistingPiece(piece) }
		try await storage.flush()
		let checked = try await storage.snapshot(), expected = partial ? 64 : 128
		guard checked.verifiedPieces.count == expected, checked.pendingVerificationCount == 0 else { throw StorageFailure.invalid("deferred completion") }
		try emit("durable", verified: checked.verifiedPieces.count, pending: checked.pendingVerificationCount)
		try await storage.shutdown(); try emit("stopped")
		// Independent payload equality and eager reopen, outside measurement.
		for index in 0..<(many ? expected : 1) {
			let url = many ? source.appendingPathComponent(String(format: "%03d", index)) : source
			let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
			var actual = SHA256(), expectedHash = SHA256()
			for _ in 0..<(many ? 16 : expected * 16) {
				guard let bytes = try handle.read(upToCount: block.count), bytes.count == block.count else { throw StorageFailure.invalid("independent length") }
				actual.update(data: bytes); expectedHash.update(data: block)
			}
			guard try handle.read(upToCount: 1)?.isEmpty != false, actual.finalize() == expectedHash.finalize() else { throw StorageFailure.invalid("independent digest") }
		}
		let reopened = try await TorrentStorage.open(metadata: metadata, destination: destination, stateDirectory: state)
		guard try await reopened.snapshot().verifiedPieces.count == expected else { throw StorageFailure.invalid("independent reopen") }
		try await reopened.shutdown(); try emit("validated")
	}
}
