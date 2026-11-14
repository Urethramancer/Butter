import Foundation
import Darwin
import Testing
@testable import ButterTorrentStorage

@Suite struct StorageVerificationParentTests {
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
}
