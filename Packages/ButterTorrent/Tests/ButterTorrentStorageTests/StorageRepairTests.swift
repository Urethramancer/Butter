import Foundation
import Testing
import ButterTorrentMetadata
@testable import ButterTorrentStorage

private func repairMetadata() throws -> TorrentMetadata {
	let bytes = Data(0..<12)
	let files: [BencodeValue] = [("a", 5), ("b", 7)].map { name, size in
		.dictionary([Data("path".utf8): .list([.bytes(Data(name.utf8))]), Data("length".utf8): .integer(Int64(size))])
	}
	let info: [Data: BencodeValue] = [Data("name".utf8): .bytes(Data("bundle".utf8)), Data("files".utf8): .list(files),
		Data("piece length".utf8): .integer(8), Data("pieces".utf8): .bytes(TorrentHasher.hash(bytes.prefix(8)).sha1 + TorrentHasher.hash(bytes.suffix(4)).sha1)]
	return try TorrentMetadata(BencodeValue.dictionary([Data("info".utf8): .dictionary(info)]).encoded())
}

@Suite struct StorageRepairTests {
	@Test(arguments: [false, true]) func boundaryRepairRetainsSourcesAndUsesRenamedSelectiveDestinations(selective: Bool) async throws {
		try await storageFixture { root in
			let metadata = try repairMetadata(), a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
			try Data(0..<5).write(to: a); try Data(5..<12).write(to: b)
			let storage = try await TorrentStorage.open(metadata: metadata, destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"), selected: [true, !selective])
			try await storage.rename([0: "renamed/a", 1: "renamed/b"])
			let first = try await storage.repairFile(0, from: a)
			#expect(first.repairedFiles == 1 && first.verifiedPieces == 0 && first.pendingPieces == 1)
			#expect(try await storage.snapshot().verifiedPieces.isEmpty)
			let second = try await storage.repairFile(1, from: b)
			#expect(second.repairedFiles == 1 && second.verifiedPieces == 2 && second.pendingPieces == 0)
			#expect(try await storage.snapshot().verifiedPieces == [0, 1])
			#expect(try Data(contentsOf: a) == Data(0..<5)); #expect(try Data(contentsOf: b) == Data(5..<12))
			#expect(try Data(contentsOf: root.appendingPathComponent("data/renamed/a")) == Data(0..<5))
			#expect(try Data(contentsOf: root.appendingPathComponent(selective ? "state/unwanted/1" : "data/renamed/b")) == Data(5..<12))
			try await storage.shutdown()
		}
	}
	@Test func mismatchCannotLoseAVerifiedBoundaryPiece() async throws {
		try await storageFixture { root in
			let storage = try await TorrentStorage.open(metadata: repairMetadata(), destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"))
			try await storage.write(piece: 0, offset: 0, data: Data(0..<8)); #expect(try await storage.verify(piece: 0))
			try await storage.write(piece: 1, offset: 0, data: Data(repeating: 255, count: 4))
			let source = root.appendingPathComponent("bad"), previous = try Data(contentsOf: root.appendingPathComponent("data/bundle/b"))
			try (Data(repeating: 255, count: 3) + Data(8..<12)).write(to: source)
			await #expect(throws: StorageFailure.self) { try await storage.repairFile(1, from: source) }
			#expect(try await storage.snapshot().verifiedPieces == [0])
			#expect(try Data(contentsOf: root.appendingPathComponent("data/bundle/b")) == previous)
			#expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("state/operation.plist").path))
			try await storage.shutdown()
		}
	}
	@Test(arguments: ["v1", "v2", "hybrid"]) func repairAuthenticatesEveryFormat(_ format: String) async throws {
		try await storageFixture { root in
			let source = root.appendingPathComponent("payload"), bytes = Data(repeating: 31, count: 32771)
			try bytes.write(to: source)
			let hybrid = try TorrentMetadata(TorrentCreator.create(source: source, trackers: [], isPrivate: false, pieceLength: 16384))
			var document = hybrid.document.root.dictionary!, info = hybrid.document.root["info"]!.dictionary!
			for key in format == "v1" ? ["meta version", "file tree"] : format == "v2" ? ["pieces", "length"] : [] { info[Data(key.utf8)] = nil }
			document[Data("info".utf8)] = .dictionary(info)
			if format == "v1" { document[Data("piece layers".utf8)] = nil }
			let metadata = try TorrentMetadata(BencodeValue.dictionary(document).encoded())
			let storage = try await TorrentStorage.open(metadata: metadata, destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"))
			let result = try await storage.repairFile(0, from: source)
			#expect(result.verifiedPieces == 3 && result.pendingPieces == 0)
			#expect(try Data(contentsOf: source) == bytes)
			try await storage.shutdown()
		}
	}
	@Test(arguments: [StorageEvent.journalDurable, .repairBackup(0), .filePublished(0), .entryDurable(0), .checkpointDurable])
	func interruptedRepairRecoversWithoutItsSource(_ interruption: StorageEvent) async throws {
		try await storageFixture { root in
			let metadata = try repairMetadata(), gate = RepairInterruption(interruption)
			let source = root.appendingPathComponent("replacement"); try Data(0..<5).write(to: source)
			let state = try StorageState(metadata: metadata, layout: StorageLayout(metadata: metadata), destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"), selected: nil, coordinator: StorageCoordinator(), event: gate.record, check: {})
			try state.write(piece: 0, offset: 0, data: Data(repeating: 255, count: 5), check: {})
			#expect(throws: CancellationError.self) { try state.repairFiles([0: source], check: gate.check) }
			#expect(state.hasJournal)
			try FileManager.default.removeItem(at: source)
			try state.recover(acceptMatchingCopies: false, check: {})
			#expect(try !state.hasJournal && state.snapshot().verifiedPieces.isEmpty)
			#expect(try Data(contentsOf: root.appendingPathComponent("data/bundle/a")) == Data(0..<5))
			#expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("data/bundle").path) == ["a"])
		}
	}
	@Test func sourceMutationAndUnsafeSourcesLeaveDestinationsUntouched() async throws {
		try await storageFixture { root in
			let metadata = try repairMetadata(), source = root.appendingPathComponent("replacement")
			try Data(0..<5).write(to: source)
			let state = try StorageState(metadata: metadata, layout: StorageLayout(metadata: metadata), destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"), selected: nil, coordinator: StorageCoordinator(), event: { _ in }, check: {})
			var checks = 0
			#expect(throws: StorageFailure.self) {
				try state.repairFiles([0: source], check: { checks += 1; if checks == 4 { try Data(repeating: 9, count: 5).write(to: source) } })
			}
			#expect(!state.hasJournal && state.record.stamps[0] == nil)
			let link = root.appendingPathComponent("link"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
			#expect(throws: StorageFailure.self) { try state.repairFiles([0: link], check: {}) }
			try state.write(piece: 0, offset: 0, data: Data(0..<5), check: {})
			#expect(throws: StorageFailure.self) { try state.repairFiles([0: root.appendingPathComponent("data/bundle/a")], check: {}) }
			try Data([1]).write(to: source)
			#expect(throws: StorageFailure.self) { try state.repairFiles([0: source], check: {}) }
		}
	}
}

private final class RepairInterruption: @unchecked Sendable {
	private let lock = NSLock()
	private let event: StorageEvent
	private var interrupted = false
	init(_ event: StorageEvent) { self.event = event }
	func record(_ event: StorageEvent) { if event == self.event { lock.withLock { interrupted = true } } }
	func check() throws { if lock.withLock({ interrupted }) { throw CancellationError() } }
}
