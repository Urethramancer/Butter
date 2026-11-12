import Foundation
import Darwin
import CryptoKit
import Testing
import ButterTorrentMetadata
@testable import ButterTorrentStorage

private func layoutMetadata(_ sizes: [Int], pieces: Data? = nil) throws -> TorrentMetadata {
	let count = (sizes.reduce(0, +) + 16383) / 16384
	let files = sizes.enumerated().map { index, size in
		BencodeValue.dictionary([Data("length".utf8): .integer(Int64(size)), Data("path".utf8): .list([.bytes(Data("\(index)".utf8))])])
	}
	let info: [Data: BencodeValue] = [Data("name".utf8): .bytes(Data("bundle".utf8)), Data("piece length".utf8): .integer(16384),
		Data("pieces".utf8): .bytes(pieces ?? Data(repeating: 0, count: count * 20)), Data("files".utf8): .list(files)]
	return try TorrentMetadata(BencodeValue.dictionary([Data("info".utf8): .dictionary(info)]).encoded())
}

private enum ParentProbeError: Error, Equatable { case stopped }

@Suite struct StorageLayoutTests {
	@Test(arguments: ["\u{0301}folder", "\u{FE0F}folder"], [false, true])
	func byteSeparatorsKeepUnicodePathsAnchored(_ child: String, _ linked: Bool) async throws {
		try await storageFixture { root in
			let managed = root.appendingPathComponent("managed"), outside = root.appendingPathComponent("outside")
			try FileManager.default.createDirectory(at: outside.appendingPathComponent(child), withIntermediateDirectories: true)
			let retained = outside.appendingPathComponent(child).appendingPathComponent("payload"), original = Data([7])
			try original.write(to: retained)
			let directory = try StorageDirectory(managed), path = "parent/" + child + "/payload"
			#expect(try StorageLayout.components(path) == ["parent", child, "payload"])
			if linked {
				try FileManager.default.createSymbolicLink(at: managed.appendingPathComponent("parent"), withDestinationURL: outside)
				#expect(throws: (any Error).self) { try directory.atomic(Data([9]), path: path) }
			} else {
				try directory.atomic(Data([9]), path: path)
				#expect(try directory.read(path, maximum: 1) == Data([9]))
			}
			#expect(try Data(contentsOf: retained) == original)
		}
	}
	@Test(arguments: ["payload", "nested/deeper/payload"], [false, true])
	func parentAnchorSurvivesLastExternalOwnerRelease(_ path: String, _ fail: Bool) async throws {
		try await storageFixture { root in
			var directory: StorageDirectory? = try StorageDirectory(root)
			let bytes = Data([1, 7, 31])
			let result: Result<String, Error> = Result {
				try directory!.parent(path, create: true) { parent, name in
					directory = nil
					var value = stat()
					guard fstat(parent, &value) == 0 else { throw diskError("Lost parent anchor") }
					#expect(value.st_mode & S_IFMT == S_IFDIR)
					let file = openat(parent, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
					guard file >= 0 else { throw diskError("Cannot use retained parent anchor") }; defer { close(file) }
					try StorageDirectory.write(bytes, to: file, offset: 0, check: {})
					if fail { throw ParentProbeError.stopped }; return name
				}
			}
			if fail {
				if case .failure(let error) = result { #expect(error as? ParentProbeError == .stopped) }
				else { Issue.record("Parent callback unexpectedly succeeded") }
			} else { #expect(try result.get() == "payload") }
			#expect(directory == nil)
			#expect(try Data(contentsOf: root.appendingPathComponent(path)) == bytes)
		}
	}
	@Test(arguments: ["payload", "nested/deeper/payload"])
	func throwingParentCallbackLeavesTheRootUsable(_ path: String) async throws {
		try await storageFixture { root in
			let directory = try StorageDirectory(root)
			#expect(throws: ParentProbeError.stopped) { try directory.parent(path, create: true) { _, _ in throw ParentProbeError.stopped } }
			try directory.atomic(Data([9]), path: path)
			#expect(try directory.read(path, maximum: 1) == Data([9]))
		}
	}
	@Test(arguments: ["", ".", "..", "a\0b", String(repeating: "a", count: 256), String(repeating: "é", count: 128)])
	func stampScanValidatesEveryLeafUnderAnAlreadyOpenedParent(_ leaf: String) async throws {
		try await storageFixture { root in
			let directory = try StorageDirectory(root), scan = StorageStampScan()
			try directory.atomic(Data([1]), path: "parent/first")
			#expect(try scan.inspect("parent/first", in: directory) != nil)
			#expect(throws: StorageFailure.invalid("relative file path")) { try scan.inspect("parent/" + leaf, in: directory) }
			#expect(try scan.inspect("parent/first", in: directory) == directory.inspect("parent/first"))
		}
	}
	@Test func stampScanHandlesRootLeavesAndSwitchesBetweenParents() async throws {
		try await storageFixture { root in
			let directory = try StorageDirectory(root), scan = StorageStampScan()
			let paths = ["first", "second", "parent/a", "parent/é", "other/b", "parent/a", "first"]
			for path in Set(paths) { try directory.atomic(Data([1]), path: path) }
			for path in paths { #expect(try scan.inspect(path, in: directory) == directory.inspect(path)) }
			for path in ["parent/./a", "parent/../first", "parent//a", "/first"] {
				#expect(throws: StorageFailure.invalid("relative file path")) { try scan.inspect(path, in: directory) }
			}
		}
	}
	@Test func stampScanAnchorsItsParentAndFreshScansObserveReplacement() async throws {
		try await storageFixture { root in
			let directory = try StorageDirectory(root)
			try directory.atomic(Data([1]), path: "parent/a"); try directory.atomic(Data([2]), path: "parent/b")
			let original = try directory.inspect("parent/b"), scan = StorageStampScan()
			#expect(try scan.inspect("parent/a", in: directory) != nil)
			try FileManager.default.moveItem(at: root.appendingPathComponent("parent"), to: root.appendingPathComponent("retained"))
			try directory.atomic(Data([3]), path: "parent/b")
			#expect(try scan.inspect("parent/b", in: directory) == original)
			#expect(try StorageStampScan().inspect("parent/b", in: directory) != original)
			// The same relative parent in another root must never reuse this descriptor.
			let other = try StorageDirectory(root.appendingPathComponent("other"))
			try other.atomic(Data([4]), path: "parent/b")
			#expect(try scan.inspect("parent/b", in: other) == other.inspect("parent/b"))
			#expect(try scan.inspect("missing/a", in: directory) == nil)
			try directory.atomic(Data([5]), path: "missing/a")
			#expect(try StorageStampScan().inspect("missing/a", in: directory) != nil)
			try FileManager.default.removeItem(at: root.appendingPathComponent("parent"))
			try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("parent"), withDestinationURL: root.appendingPathComponent("retained"))
			#expect(throws: (any Error).self) { try StorageStampScan().inspect("parent/b", in: directory) }
		}
	}
	@Test(arguments: [[0, 7, 16377, 1, 16384, 0], [16384, 0, 16384], [1, 1, 1], [0, 0]])
	func filePieceRangesIncludeSharedBoundariesAndIgnoreEmptyFiles(_ sizes: [Int]) throws {
		let layout = try StorageLayout(metadata: layoutMetadata(sizes))
		for index in sizes.indices {
			let mapped = try (0..<layout.pieceCount).filter { piece in
				try layout.segments(piece: piece, count: layout.length(of: piece)).contains { $0.file == index }
			}
			#expect(Array(try layout.pieces(touchingFile: index)) == mapped)
		}
		#expect(throws: StorageFailure.self) { try layout.pieces(touchingFile: -1) }
		#expect(throws: StorageFailure.self) { try layout.pieces(touchingFile: sizes.count) }
	}
	@Test func externalEditInvalidatesSharedPiecesAndRetainsUnrelatedPieces() async throws {
		try await storageFixture { root in
			let sizes = [7, 32768, 32761], bytes = Data((0..<65536).map { UInt8(truncatingIfNeeded: $0 * 17) })
			var hashes = Data()
			for offset in stride(from: 0, to: bytes.count, by: 16384) { hashes.append(Data(Insecure.SHA1.hash(data: bytes.subdata(in: offset..<(offset + 16384))))) }
			let metadata = try layoutMetadata(sizes, pieces: hashes)
			let storage = try await TorrentStorage.open(metadata: metadata, destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"))
			for piece in 0..<4 {
				try await storage.write(piece: piece, offset: 0, data: bytes.subdata(in: (piece * 16384)..<((piece + 1) * 16384)))
				#expect(try await storage.verify(piece: piece))
			}
			// The middle file spans pieces 0, 1 and 2; piece 3 remains independent.
			try Data(repeating: 42, count: sizes[1]).write(to: root.appendingPathComponent("data/bundle/1"), options: .atomic)
			#expect(try await storage.snapshot().verifiedPieces == [3])
			try await storage.shutdown()
		}
	}
	@Test func descriptorRelativeInspectionRejectsLinksAndSpecialFiles() async throws {
		try await storageFixture { root in
			let directory = try StorageDirectory(root), file = root.appendingPathComponent("file")
			try Data([1]).write(to: file)
			let descriptor = try directory.openFile("file"); defer { close(descriptor) }
			#expect(try directory.inspect("file") == directory.stamp(descriptor))
			#expect(try directory.inspect("missing") == nil && directory.inspect("missing/child") == nil)
			try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: file)
			#expect(throws: StorageFailure.self) { try directory.inspect("link") }
			try FileManager.default.linkItem(at: file, to: root.appendingPathComponent("hard"))
			#expect(throws: StorageFailure.self) { try directory.inspect("hard") }
			#expect(mkfifo(root.appendingPathComponent("fifo").path, 0o600) == 0)
			#expect(throws: StorageFailure.self) { try directory.inspect("fifo") }
		}
	}
}
