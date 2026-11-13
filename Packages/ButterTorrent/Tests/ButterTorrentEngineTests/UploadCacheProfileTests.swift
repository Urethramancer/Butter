import Foundation
import Darwin
import Testing
import ButterTorrentNetworking
import ButterTorrentStorage
@testable import ButterTorrentEngine

// Opt-in diagnostic: real guarded reads with warm OS caches, without peer transport.
// This isolates cache policy; it cannot establish an overall transfer CPU win.
@Suite struct UploadCacheProfileTests {
	@Test(.enabled(if: ProcessInfo.processInfo.environment["BUTTER_UPLOAD_CACHE_PROFILE"] == "1"))
	func profileFanOutAndChangingPopularity() async throws {
		let fixture = try TransferFixture(lengths: Array(repeating: 524288, count: 4))
		do {
			_ = try await fixture.transfer("seed", seed: true, readPolicy: .trustedVerified)
			let storage = fixture.stores[0]
			let expected = stride(from: 0, to: fixture.bytes.count, by: 32768).map { fixture.bytes.subdata(in: $0..<($0 + 32768)) }
			let rounds = 32
			let workloads: [(String, [Int])] = [
				("fan-out", (0..<(rounds * 64)).map { $0 % 64 }),
				("popular", (0..<rounds).flatMap { _ in Array(0..<4) + Array(0..<4) + Array(16..<32) + Array(0..<4) }),
				("changing-popularity", (0..<rounds).flatMap { round in
					let first = (round / 4) % 4 * 4
					return Array(first..<(first + 4)) + Array(first..<(first + 4)) + Array(16..<32) + Array(first..<(first + 4))
				})
			]
			for (name, requests) in workloads {
				let cache = SharedPieceCache(limit: 8 * 32768), owner = PieceCacheOwner()
				let before = StorageDiagnostics.snapshot(), start = try Self.cpu()
				try await withThrowingTaskGroup(of: Void.self) { group in
					for _ in 0..<8 {
						group.addTask {
							for piece in requests {
								let data = try await cache.piece(piece, storage: storage, owner: owner)
								guard data == expected[piece] else { throw PeerFailure.invalid("cache profile payload mismatch") }
							}
						}
					}
					try await group.waitForAll()
				}
				let elapsed = try Self.cpu() - start, after = StorageDiagnostics.snapshot()
				let counters = after.map { ($0.key, $0.value - before[$0.key, default: 0]) }
				let record: [String: Any] = ["workload": name, "callers": 8, "requests": requests.count * 8,
					"delivered_bytes": requests.count * 8 * 32768, "cache_bytes": 8 * 32768,
					"cpu_seconds": elapsed, "counters": Dictionary(uniqueKeysWithValues: counters),
					"scope": "cache and guarded reads; warm source; every returned byte checked; not transfer timing acceptance"]
				let json = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
				print("UPLOAD_CACHE_PROFILE " + String(decoding: json, as: UTF8.self))
				await cache.close(owner)
				let (cached, loading) = await cache.usage; #expect(cached == 0 && loading == 0)
			}
			await fixture.clean()
		} catch { await fixture.clean(); throw error }
	}
	private static func cpu() throws -> Double {
		var usage = rusage()
		guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw CocoaError(.fileReadUnknown) }
		return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
	}
}
