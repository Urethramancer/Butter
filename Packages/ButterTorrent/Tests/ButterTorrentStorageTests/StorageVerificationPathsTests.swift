import Foundation
import Darwin
import Testing
@testable import ButterTorrentStorage

@Suite struct StorageVerificationPathsTests {
	enum Change: CaseIterable, Sendable { case replacement, originalFile, symlink, permissions }
	@Test(arguments: Change.allCases) func verificationRefreshesParentsBeforeReadback(_ change: Change) async throws {
		try await storageFixture { root in
			let (metadata, bytes) = try storageMetadata(root)
			let state = try StorageState(metadata: metadata, layout: StorageLayout(metadata: metadata), destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"), selected: nil, coordinator: StorageCoordinator(), event: { _ in }, check: {})
			try state.write(piece: 0, offset: 0, data: bytes.prefix(16384), check: {})
			let parent = root.appendingPathComponent("data/source"), old = root.appendingPathComponent("old")
			defer { _ = chmod(parent.path, 0o700) }
			var changed = false
			let result = Result { try state.verify(piece: 0) {
				guard !changed else { return }; changed = true
				if change == .permissions { guard chmod(parent.path, 0o300) == 0 else { throw diskError("Cannot change test permissions") }; return }
				try FileManager.default.moveItem(at: parent, to: old)
				if change == .symlink { try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: old); return }
				try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
				if change == .originalFile { try FileManager.default.moveItem(at: old.appendingPathComponent("a"), to: parent.appendingPathComponent("a")) }
				else { try bytes.prefix(16384).write(to: parent.appendingPathComponent("a")) }
			} }
			#expect(changed)
			if case .success = result { Issue.record("Changed verification parent was accepted") }
			#expect(!state.record.contains(0))
		}
	}
	#if os(macOS)
	@Test func parentACLChangesApplyToRetainedHandles() async throws {
		try await storageFixture { root in
			let directory = try StorageDirectory(root), paths = StorageVerificationPaths()
			try directory.atomic(Data([1]), path: "parent/payload")
			#expect(try paths.inspect("parent/payload", in: directory) != nil)
			let parent = root.appendingPathComponent("parent")
			func acl(_ arguments: [String]) throws {
				let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/chmod"); process.arguments = arguments + [parent.path]
				try process.run(); process.waitUntilExit()
				guard process.terminationStatus == 0 else { throw diskError("Cannot configure test ACL", code: EINVAL) }
			}
			try acl(["+a", "user:\(NSUserName()) deny read"]); defer { try? acl(["-N"]) }
			#expect(throws: (any Error).self) { try paths.inspect("parent/payload", in: directory) }
			#expect(throws: (any Error).self) { try paths.openFile("parent/payload", in: directory) }
			try acl(["-N"])
			#expect(try paths.inspect("parent/payload", in: directory) != nil)
		}
	}
	#endif
	@Test func cursorKeepsRootsUnicodeAndFallbackPathsSeparate() async throws {
		try await storageFixture { root in
			let first = try StorageDirectory(root.appendingPathComponent("first")), second = try StorageDirectory(root.appendingPathComponent("second"))
			let paths = StorageVerificationPaths()
			for directory in [first, second, first] {
				for (index, path) in ["parent/a", "parent/\u{0301}leaf", "parent/deep/a", "root", "other/a", "parent/a"].enumerated() {
					let bytes = Data([UInt8(index)])
					try directory.atomic(bytes, path: path)
					#expect(try paths.inspect(path, in: directory) == directory.inspect(path))
					let file = try paths.openFile(path, in: directory); defer { close(file) }
					#expect(try StorageDirectory.read(file, offset: 0, count: 1) == bytes)
				}
			}
			for path in ["parent/../root", "/parent/a", "parent//a", "parent/a\0", "parent/"] {
				#expect(throws: StorageFailure.self) { try paths.inspect(path, in: first) }
				#expect(throws: StorageFailure.self) { try paths.openFile(path, in: first) }
			}
		}
	}
}
