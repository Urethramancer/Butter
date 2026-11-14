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
}
