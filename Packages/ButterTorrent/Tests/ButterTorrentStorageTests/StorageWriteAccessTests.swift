import Foundation
import Darwin
import Testing
import ButterTorrentMetadata
@testable import ButterTorrentStorage

@Suite struct StorageWriteAccessTests {
	@Test(arguments: ["file", "parent", "hardlink", "symlink"], [false, true])
	func writesRejectAccessAndLinkChangesBetweenJobs(_ change: String, _ coalesced: Bool) async throws {
		try await storageFixture { root in
			let state = try makeState(root), file = root.appendingPathComponent("data/source/a")
			try write(state, coalesced: coalesced, byte: 1)
			let parent = file.deletingLastPathComponent(), old = root.appendingPathComponent("old")
			defer { _ = chmod(file.path, 0o600); _ = chmod(parent.path, 0o700) }
			switch change {
			case "file": #expect(chmod(file.path, 0o000) == 0)
			case "parent": #expect(chmod(parent.path, 0o300) == 0)
			case "hardlink": try FileManager.default.linkItem(at: file, to: old)
			default:
				try FileManager.default.moveItem(at: file, to: old)
				try FileManager.default.createSymbolicLink(at: file, withDestinationURL: old)
			}
			#expect(throws: (any Error).self) { try write(state, coalesced: coalesced, byte: 2) }
			_ = chmod(file.path, 0o600); _ = chmod(parent.path, 0o700)
			#expect(try Data(contentsOf: change == "symlink" ? old : file) == Data([1]))
		}
	}
	#if os(macOS)
	@Test(arguments: [false, true]) func writesHonourAnAddedDenyACL(_ coalesced: Bool) async throws {
		try await storageFixture { root in
			let state = try makeState(root), file = root.appendingPathComponent("data/source/a")
			try write(state, coalesced: coalesced, byte: 1)
			func chmod(_ arguments: [String]) throws {
				let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/chmod"); process.arguments = arguments + [file.path]
				try process.run(); process.waitUntilExit()
				guard process.terminationStatus == 0 else { throw diskError("Cannot configure test ACL", code: EINVAL) }
			}
			try chmod(["+a", "user:\(NSUserName()) deny read,write"])
			defer { try? chmod(["-N"]) }
			#expect(throws: (any Error).self) { try write(state, coalesced: coalesced, byte: 2) }
			try chmod(["-N"])
			#expect(try Data(contentsOf: file) == Data([1]))
		}
	}
	#endif
	private func write(_ state: StorageState, coalesced: Bool, byte: UInt8) throws {
		try state.writeOperations([StorageWrite(piece: 0, offset: 0, data: Data([byte]))], maximumBytes: 1, maximumCount: 1, coalescing: coalesced, check: {})
	}
	private func makeState(_ root: URL) throws -> StorageState {
		let (metadata, _) = try storageMetadata(root)
		return try StorageState(metadata: metadata, layout: StorageLayout(metadata: metadata), destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"), selected: nil, coordinator: StorageCoordinator(), event: { _ in }, check: {})
	}
}
