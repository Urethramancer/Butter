import Foundation
import Testing
import CryptoKit
import Darwin
@testable import ButterTorrentMetadata

@Suite struct CreationTests {
	private func fixture(_ body: (URL) throws -> Void) throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("ButterCreation-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: root) }
		try body(root)
	}
	@Test func singleFileKnownHashes() throws {
		try fixture { root in
			let file = root.appendingPathComponent("abc")
			try Data("abc".utf8).write(to: file)
			let bytes = try TorrentCreator.create(source: file, trackers: [], isPrivate: false)
			let metadata = try TorrentMetadata(bytes)
			#expect(metadata.document.root["info"]?["pieces"]?.bytes?.hex == "a9993e364706816aba3e25717850c26c9cd0d89d")
			#expect(metadata.document.root["info"]?["file tree"]?["abc"]?[""]?["pieces root"]?.bytes?.hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
			#expect(metadata.hashes.hex.map(\.count) == [40, 64] && metadata.inspection.files.count == 1)
		}
	}
	@Test func multifilePaddingPrivateTrackersAndSymlinkExclusions() throws {
		try fixture { root in
			try Data(repeating: 1, count: 32771).write(to: root.appendingPathComponent("a"))
			try Data().write(to: root.appendingPathComponent("empty"))
			try Data(repeating: 2, count: 33).write(to: root.appendingPathComponent("b"))
			try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("a"))
			try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("cycle"), withDestinationURL: root)
			let metadata = try TorrentMetadata(TorrentCreator.create(source: root, trackers: ["http://127.0.0.1:1/announce"], isPrivate: true, pieceLength: 32768))
			#expect(metadata.inspection.private)
			#expect(metadata.trackerTiers == [["http://127.0.0.1:1/announce"]])
			#expect(metadata.inspection.files.filter { !$0.pad }.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["a", "b", "empty"])
			#expect(metadata.inspection.files.filter(\.pad).map(\.size) == [32765, 32735])
			#expect(metadata.pieceLayers.count == 1)
		}
	}
	@Test func cancellationAndChangedSource() throws {
		try fixture { root in
			let file = root.appendingPathComponent("payload"), data = Data(repeating: 42, count: 65537)
			try data.write(to: file)
			var cancelled = false
			#expect(throws: CancellationError.self) {
				try TorrentCreator.create(source: file, trackers: [], isPrivate: false, progress: { _ in cancelled = true }, isCancelled: { cancelled })
			}
			var changed = false
			#expect(throws: MetadataError.self) {
				try TorrentCreator.create(source: file, trackers: [], isPrivate: false, progress: { _ in
					if !changed { changed = true; try? data.prefix(1).write(to: file) }
				})
			}
			#expect(throws: MetadataError.self) { try TorrentCreator.create(source: file, trackers: [], isPrivate: true) }
			#expect(throws: MetadataError.self) { try TorrentCreator.create(source: file, trackers: [], isPrivate: false, pieceLength: 3) }
		}
	}
	@Test func replacedSourceRejectsFIFOWithoutWaitingForAWriter() throws {
		try fixture { root in
			let first = root.appendingPathComponent("a"), replaced = root.appendingPathComponent("b")
			try Data([1]).write(to: first); try Data([2]).write(to: replaced)
			var changed = false, replacementError: Error?
			// Bound the regression case too: a blocking open receives a writer after one second.
			let release = DispatchWorkItem {
				let descriptor = open(replaced.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
				if descriptor >= 0 { close(descriptor) }
			}
			defer { release.cancel() }
			let began = ContinuousClock.now
			#expect(throws: MetadataError.self) {
				try TorrentCreator.create(source: root, trackers: [], isPrivate: false, progress: { _ in
					guard !changed else { return }; changed = true
					do {
						try FileManager.default.removeItem(at: replaced)
						guard mkfifo(replaced.path, 0o600) == 0 else { throw POSIXError(.EIO) }
						DispatchQueue.global().asyncAfter(deadline: .now() + 1, execute: release)
					} catch { replacementError = error }
				})
			}
			#expect(replacementError == nil && changed)
			#expect(began.duration(to: .now) < .milliseconds(800))
		}
	}
}
