import Testing
@testable import ButterTorrentStorage

@Suite struct StorageWriteQueueDiagnosticsTests {
	@Test func queueElapsedAndCountsOnlyAreSeparate() {
		#expect(StorageWriteQueueProfile(submitted: 100).values(started: 160) == ["jobs": 1, "elapsedNs": 60])
		#expect(StorageWriteQueueProfile(submitted: nil).values(started: nil) == ["jobs": 1])
		#expect(StorageWriteQueueProfile(submitted: nil).began() == nil)
		#expect(StorageWriteQueueProfile.make(forWrite: false) == nil)
		if !StorageDiagnostics.enabled { #expect(StorageWriteQueueProfile.make(forWrite: true) == nil) }
	}
	@Test func synchronousScopesKeepCpuAndElapsedSeparate() {
		let profile = StorageSynchronousProfile(kind: .verification, started: .init(elapsed: 100, cpu: 40))
		#expect(profile.values(ended: .init(elapsed: 180, cpu: 70)) == ["calls": 1, "elapsedNs": 80, "cpuNs": 30, "durationNsPower2_7": 1])
		#expect(StorageSynchronousProfile(kind: .checkpointOther, started: nil).values(ended: nil) == ["calls": 1])
	}
	@Test func failedVerificationRestoresTheCheckpointScope() async throws {
		try await storageFixture { root in
			let (metadata, _) = try storageMetadata(root)
			let state = try StorageState(metadata: metadata, layout: StorageLayout(metadata: metadata), destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"), selected: nil, coordinator: StorageCoordinator(), event: { _ in }, check: {})
			let outer = state.beginVerificationProfile()
			if StorageDiagnostics.enabled { #expect(outer != nil); #expect(state.beginVerificationProfile() == nil) }
			state.finishVerificationProfile(outer)
			state.closed = true
			#expect(throws: StorageFailure.closed) { try state.verify(piece: 0, check: {}) }
			#expect(state.diagnosticVerificationDepth == 0)
		}
	}
}
