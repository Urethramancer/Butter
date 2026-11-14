import Foundation
import Darwin
import Testing
import ButterTorrentMetadata
@testable import ButterTorrentStorage

@Suite struct StorageWriteProfileTests {
	@Test func nestedTimingAndErrno() {
		var ticks: Int64 = 0
		let profile = StorageWriteProfile(timed: true) {
			ticks += 10; errno = EDOM
			return .init(elapsed: ticks, cpu: ticks / 2)
		}
		errno = EINTR
		profile.enter(.prewriteChecks)
		let previous = profile.enter(.fullScan)
		profile.enter(previous)
		profile.enter(.payloadSyscall)
		profile.finish(outcome: "succeeded")
		#expect(errno == EINTR)
		let values = profile.values
		#expect(values["phase.prewriteChecks.elapsedNs"] == 20)
		#expect(values["phase.fullScan.elapsedNs"] == 10)
		#expect(values["phase.payloadSyscall.elapsedNs"] == 10)
		#expect(values["job.elapsedNs"] == 110)
		#expect(values["remainder.elapsedNs"] == 70)
		#expect(values["remainder.cpuNs"] == 35)
		profile.finish(outcome: "failed")
		#expect(profile.values["jobs"] == 1)
	}
	@Test func countsOnlyNeverReadsClocksAndHistogramsStayBounded() {
		let profile = StorageWriteProfile(timed: false) { Issue.record("Counts-only read a clock"); return .init(elapsed: 0, cpu: 0) }
		for value in 0..<10000 { profile.histogram("size", value) }
		profile.enter(.setup); profile.finish(outcome: "failed")
		#expect(profile.values["sizeCount"] == 10000)
		#expect(profile.values.keys.filter { $0.hasPrefix("sizePower2_") }.count == 15)
		#expect(profile.values["job.cpuNs"] == nil)
		if !StorageDiagnostics.enabled { #expect(StorageWriteProfile.make() == nil) }
	}
	@Test func concurrentOwnersMergeOnce() async {
		let before = StorageDiagnostics.snapshot()["writeProfile.profileTestOwners", default: 0]
		await withTaskGroup(of: Void.self) { group in
			for _ in 0..<32 {
				group.addTask {
					let recorder = StorageWriteProfile(timed: false)
					recorder.count("profileTestOwners", 7); recorder.finish(outcome: "succeeded"); recorder.finish(outcome: "failed")
				}
			}
		}
		#expect(StorageDiagnostics.snapshot()["writeProfile.profileTestOwners", default: 0] - before == 224)
	}
	@Test(arguments: [false, true]) func failedAndCancelledJobsFinalise(_ cancelled: Bool) async throws {
		try await storageFixture { root in
			let state = try makeState(root)
			var ticks: Int64 = 0
			let profile = StorageWriteProfile(timed: true) { ticks += 10; return .init(elapsed: ticks, cpu: ticks) }
			#expect(throws: (any Error).self) {
				try state.writeOperations([], maximumBytes: 1, maximumCount: 1, diagnosticRecorder: profile, check: { if cancelled { throw CancellationError() } })
			}
			#expect(profile.values[cancelled ? "cancelled" : "failed"] == 1)
			#expect(profile.values["jobs"] == 1)
			#expect(profile.values["job.cpuNs", default: 0] > 0)
			#expect(state.writeProfile == nil)
		}
	}
	@Test(arguments: [false, true]) func scansAttributeCreationReplacementAndCheckpoint(_ coalesced: Bool) async throws {
		try await storageFixture { root in
			let state = try makeState(root)
			let origin = coalesced ? "coalesced" : "ordinary"
			func write() throws -> StorageWriteProfile {
				let profile = StorageWriteProfile(timed: true)
				try state.writeOperations([StorageWrite(piece: 0, offset: 0, data: Data(repeating: 0, count: 16384))], maximumBytes: 16384, maximumCount: 1, coalescing: coalesced, diagnosticRecorder: profile, check: {})
				return profile
			}
			let created = try write()
			#expect(created.values["\(origin)MismatchAbsent"] == 1)
			#expect(created.values["scan.\(origin).filesVisited"] == 1)
			#expect(created.values["scan.\(origin).filesChanged"] == 1)
			#expect(try write().values["scan.\(origin).calls"] == nil)
			#expect(try state.verify(piece: 0, check: {}))
			let invalidating = try write()
			#expect(invalidating.values["scan.checkpoint.calls"] == 1)
			#expect(invalidating.values["scan.checkpoint.filesVisited"] == 1)
			#expect(invalidating.values["phase.progressInvalidation.cpuNs", default: 0] > 0)
			let profile = StorageWriteProfile(timed: true)
			state.writeProfile = profile
			let file = root.appendingPathComponent("data/payload")
			try FileManager.default.removeItem(at: file)
			try Data(repeating: 7, count: 16384).write(to: file)
			try state.invalidateChangedFiles(origin: origin)
			try state.save()
			#expect(profile.values["scan.\(origin).filesChanged"] == 1)
			#expect(profile.values["scan.checkpoint.calls"] == 1)
			#expect(profile.values["scan.checkpoint.filesChanged"] == 0)
			#expect(profile.values["scan.checkpoint.filesVisited"] == 1)
			state.writeProfile = nil
		}
	}
	@Test func syscallFailurePreservesErrnoAfterTimedCallback() {
		var ticks: Int64 = 0
		let profile = StorageWriteProfile(timed: true) {
			ticks += 10; errno = EDOM
			return .init(elapsed: ticks, cpu: ticks)
		}
		do {
			try StorageDirectory.write(Data([1]), to: -1, offset: 0, profile: profile, check: {})
			Issue.record("Write to invalid descriptor succeeded")
		} catch {
			#expect((error as NSError).domain == NSPOSIXErrorDomain)
			#expect((error as NSError).code == Int(EBADF))
			#expect(profile.values["syscallAttempts"] == 1)
		}
	}
	@Test(arguments: [false, true]) func cancellationAfterOpeningClosesDescriptors(_ coalesced: Bool) async throws {
		try await storageFixture { root in
			let state = try makeState(root)
			let profile = StorageWriteProfile(timed: true)
			#expect(throws: CancellationError.self) {
				try state.writeOperations([StorageWrite(piece: 0, offset: 0, data: Data([0]))], maximumBytes: 1, maximumCount: 1, coalescing: coalesced, diagnosticRecorder: profile, check: {
					if profile.values["descriptorAcquisitions"] == 1 { throw CancellationError() }
				})
			}
			#expect(profile.values["cancelled"] == 1)
			#expect(profile.values["descriptorCloses"] == 1)
			#expect(profile.values["syscallAttempts"] == nil)
			#expect(profile.values["phase.cleanup.calls"] == 1)
		}
	}
	private func makeState(_ root: URL) throws -> StorageState {
		let data = Data(repeating: 0, count: 16384)
		let info: [Data: BencodeValue] = [Data("name".utf8): .bytes(Data("payload".utf8)), Data("length".utf8): .integer(16384), Data("piece length".utf8): .integer(16384), Data("pieces".utf8): .bytes(TorrentHasher.hash(data).sha1)]
		let metadata = try TorrentMetadata(BencodeValue.dictionary([Data("info".utf8): .dictionary(info)]).encoded())
		return try StorageState(metadata: metadata, layout: StorageLayout(metadata: metadata), destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"), selected: nil, coordinator: StorageCoordinator(), event: { _ in }, check: {})
	}
}
