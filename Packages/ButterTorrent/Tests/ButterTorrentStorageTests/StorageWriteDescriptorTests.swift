import Foundation
import Darwin
import Testing
import ButterTorrentMetadata
@testable import ButterTorrentStorage

@Suite struct StorageWriteDescriptorTests {
	@Test(arguments: [false, true]) func reuseAcrossJobsRefreshesReplacementIdentity(_ coalesced: Bool) async throws {
		try await storageFixture { root in
			let state = try makeState(root)
			func write(_ byte: UInt8) throws -> StorageWriteProfile {
				let profile = StorageWriteProfile(timed: false)
				try state.writeOperations([StorageWrite(piece: 0, offset: 0, data: Data([byte]))], maximumBytes: 1, maximumCount: 1, coalescing: coalesced, diagnosticRecorder: profile, check: {})
				return profile
			}
			#expect(try write(1).values["persistentDescriptorHits"] == nil)
			#expect(state.writeDescriptors.count == 1)
			#expect(try write(2).values["persistentDescriptorHits"] == 1)
			let file = root.appendingPathComponent("data/source/a"), old = root.appendingPathComponent("old")
			try FileManager.default.moveItem(at: file, to: old)
			try Data([9]).write(to: file)
			#expect(try write(3).values["persistentDescriptorHits"] == nil)
			#expect(try Data(contentsOf: old) == Data([2]))
			#expect(try Data(contentsOf: file) == Data([3]))
		}
	}
	@Test(arguments: ["file", "parent", "hardlink", "symlink"])
	func reuseRejectsAccessAndLinkChangesBetweenJobs(_ change: String) async throws {
		try await storageFixture { root in
			let state = try makeState(root), file = root.appendingPathComponent("data/source/a")
			try state.write(piece: 0, offset: 0, data: Data([1]), check: {})
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
			#expect(throws: (any Error).self) { try state.write(piece: 0, offset: 0, data: Data([2]), check: {}) }
			#expect(state.writeDescriptors.count == 0)
			_ = chmod(file.path, 0o600); _ = chmod(parent.path, 0o700)
			#expect(try Data(contentsOf: change == "symlink" ? old : file) == Data([1]))
		}
	}
	#if os(macOS)
	@Test func reuseHonoursAnAddedDenyACL() async throws {
		try await storageFixture { root in
			let state = try makeState(root), file = root.appendingPathComponent("data/source/a")
			try state.write(piece: 0, offset: 0, data: Data([1]), check: {})
			func chmod(_ arguments: [String]) throws {
				let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/chmod"); process.arguments = arguments + [file.path]
				try process.run(); process.waitUntilExit(); guard process.terminationStatus == 0 else { throw diskError("Cannot configure test ACL", code: EINVAL) }
			}
			try chmod(["+a", "user:\(NSUserName()) deny read,write"])
			defer { try? chmod(["-N"]) }
			#expect(throws: (any Error).self) { try state.write(piece: 0, offset: 0, data: Data([2]), check: {}) }
			#expect(state.writeDescriptors.count == 0)
			try chmod(["-N"])
			#expect(try Data(contentsOf: file) == Data([1]))
		}
	}
	#endif
	@Test func idleLimitEvictsAndGlobalExhaustionClosesInsteadOfWaiting() async throws {
		try await storageFixture { root in
			let directory = try StorageDirectory(root), budget = StorageWriteDescriptorBudget(maximum: 8)
			let cache = StorageWriteDescriptors(budget: budget), other = StorageWriteDescriptors(budget: budget)
			var descriptors: [Int32] = []
			for index in 0..<9 {
				let file = try directory.openFile("file-\(index)", write: true); descriptors.append(file)
				cache.put(index, file: file, directory: directory, path: "file-\(index)", profile: nil)
			}
			#expect(cache.count == 8)
			#expect(fcntl(descriptors[0], F_GETFD) == -1)
			let overflow = try directory.openFile("overflow", write: true)
			other.put(0, file: overflow, directory: directory, path: "overflow", profile: nil)
			#expect(other.count == 0 && fcntl(overflow, F_GETFD) == -1)
			let cached = try cache.take(8, directory: directory, path: "file-8", profile: nil)
			let taken = try #require(cached)
			#expect(taken == descriptors[8])
			let available = try directory.openFile("available", write: true)
			other.put(0, file: available, directory: directory, path: "available", profile: nil)
			#expect(other.count == 1)
			cache.removeAll(); other.removeAll(); close(taken)
			for file in descriptors.dropFirst() { #expect(fcntl(file, F_GETFD) == -1) }
		}
	}
	@Test func flushShutdownAndFilesystemClaimsReleaseIdleHandles() async throws {
		try await storageFixture { root in
			let (metadata, _) = try storageMetadata(root)
			let storage = try await TorrentStorage.open(metadata: metadata, destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"))
			let state = await storage.state, worker = await storage.worker
			try await storage.write(piece: 0, offset: 0, data: Data([1]))
			#expect(try await worker.run { _ in state.writeDescriptors.count } == 1)
			try await storage.flush()
			#expect(try await worker.run { _ in state.writeDescriptors.count } == 0)
			try await storage.write(piece: 0, offset: 0, data: Data([2]))
			try await worker.run { _ in try state.claim(); #expect(state.writeDescriptors.count == 0) }
			try await storage.write(piece: 0, offset: 0, data: Data([3]))
			try await storage.shutdown()
			#expect(try await worker.run { _ in state.writeDescriptors.count } == 0)
		}
	}
	@Test func cancellationBeforeAcquisitionDrainsPreviouslyIdleHandles() async throws {
		try await storageFixture { root in
			let state = try makeState(root)
			try state.write(piece: 0, offset: 0, data: Data([1]), check: {})
			#expect(state.writeDescriptors.count == 1)
			#expect(throws: CancellationError.self) { try state.write(piece: 0, offset: 0, data: Data([2]), check: { throw CancellationError() }) }
			#expect(state.writeDescriptors.count == 0)
			#expect(try Data(contentsOf: root.appendingPathComponent("data/source/a")) == Data([1]))
		}
	}
	private func makeState(_ root: URL) throws -> StorageState {
		let (metadata, _) = try storageMetadata(root)
		return try StorageState(metadata: metadata, layout: StorageLayout(metadata: metadata), destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"), selected: nil, coordinator: StorageCoordinator(), event: { _ in }, check: {})
	}
}
