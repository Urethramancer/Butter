import Foundation
import Testing
import ButterTorrentMetadata
import ButterTorrentNetworking
import ButterTorrentStorage
@testable import ButterTorrentEngine

@Suite(.serialized) struct LargePieceTests {
	@Test(arguments: ["v1", "v2", "hybrid"])
	func transfersAndReopensThirtyTwoMiBPieces(_ format: String) async throws {
		try await transferFixture { fixture in
			let length = 32 * 1024 * 1024
			let source = fixture.root.appendingPathComponent("large-source")
			try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
			let bytes = Data(repeating: 73, count: length) + Data([3, 7, 11])
			try bytes.write(to: source.appendingPathComponent("payload"))
			let hybrid = try TorrentMetadata(TorrentCreator.create(source: source.appendingPathComponent("payload"), trackers: [], isPrivate: false, pieceLength: length))
			var document = hybrid.document.root.dictionary!, info = hybrid.document.root["info"]!.dictionary!
			for key in format == "v1" ? ["meta version", "file tree"] : format == "v2" ? ["pieces", "length"] : [] { info[Data(key.utf8)] = nil }
			document[Data("info".utf8)] = .dictionary(info)
			if format == "v1" { document[Data("piece layers".utf8)] = nil }
			let metadata = try TorrentMetadata(BencodeValue.dictionary(document).encoded())
			let seedStorage = try await TorrentStorage.open(metadata: metadata, destination: source, stateDirectory: fixture.root.appendingPathComponent("large-seed-state"))
			fixture.stores.append(seedStorage)
			for piece in 0..<seedStorage.layout.pieceCount { #expect(try await seedStorage.verify(piece: piece)) }
			let resources = try TransferResources()
			let seed = try await TCPTransfer.open(metadata: metadata, storage: seedStorage, configuration: plainTransferConfiguration(), resources: resources)
			fixture.engines.append(seed)
			let destination = fixture.root.appendingPathComponent("large-download"), state = fixture.root.appendingPathComponent("large-download-state")
			let storage = try await TorrentStorage.open(metadata: metadata, destination: destination, stateDirectory: state, checkpointPolicy: .managed)
			fixture.stores.append(storage)
			let download = try await TCPTransfer.open(metadata: metadata, storage: storage, configuration: plainTransferConfiguration(), resources: resources)
			fixture.engines.append(download)
			try await fixture.join(download, seed)
			try await engineDeadline { try await download.waitUntilComplete() }
			try await download.shutdown(); try await storage.shutdown()
			#expect(try Data(contentsOf: destination.appendingPathComponent("payload")) == bytes)
			let usage = await resources.snapshot()
			#expect(usage.cachedBytes + usage.loadingBytes <= 64 * 1024 * 1024)
			let reopened = try await TorrentStorage.open(metadata: metadata, destination: destination, stateDirectory: state)
			fixture.stores.append(reopened)
			#expect(try await reopened.snapshot().verifiedPieces == [0, 1])
		}
	}
	@Test func twoTiBLayoutFitsAndLargerPiecesAreRejected() throws {
		let size: Int64 = 2 * 1024 * 1024 * 1024 * 1024
		for length in [32 * 1024 * 1024, 64 * 1024 * 1024] {
			let info: [Data: BencodeValue] = [Data("name".utf8): .bytes(Data("large".utf8)), Data("length".utf8): .integer(size),
				Data("piece length".utf8): .integer(Int64(length)), Data("pieces".utf8): .bytes(Data(repeating: 0, count: Int(size / Int64(length)) * 20))]
			let metadata = try TorrentMetadata(BencodeValue.dictionary([Data("info".utf8): .dictionary(info)]).encoded())
			if length == 32 * 1024 * 1024 { #expect(try StorageLayout(metadata: metadata).pieceCount == 65_536) }
			else { #expect(throws: StorageFailure.self) { try StorageLayout(metadata: metadata) } }
		}
	}
}
