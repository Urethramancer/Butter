import Darwin
import Foundation
import ButterTorrentMetadata
import ButterTorrentStorage

enum StorageReplay {
	struct Job {
		let writes: [StorageWrite]
		let completed: [Int]
	}

	struct Torrent {
		let metadata: TorrentMetadata
		let destination: URL
		let state: URL
		let storage: TorrentStorage
		let jobs: [Job]

		func write(budget: DownloadWriteBufferBudget?) async throws {
			for job in jobs {
				if let first = job.completed.first {
					guard try await storage.writeAndVerifyBatch(job.writes, piece: first, bufferBudget: budget).get() else {
						throw StorageFailure.invalid("replay verification")
					}
					for piece in job.completed.dropFirst() {
						guard try await storage.verify(piece: piece) else { throw StorageFailure.invalid("replay verification") }
					}
				} else if job.writes.count == 1, let block = job.writes.first {
					try await storage.write(piece: block.piece, offset: block.offset, data: block.data)
				} else if let budget {
					try await storage.writeDownloadBatch(job.writes, bufferBudget: budget)
				} else {
					try await storage.writeBatch(job.writes)
				}
			}
			try await storage.checkpoint(downloaded: storage.layout.totalBytes, uploaded: 0)
		}

		func check(seed: URL) async throws {
			try await storage.shutdown()
			for file in storage.layout.files where !file.pad {
				guard FileManager.default.contentsEqual(atPath: seed.appendingPathComponent(file.path).path,
					andPath: destination.appendingPathComponent(file.path).path) else { throw StorageFailure.invalid("replay bytes") }
			}
			let reopened = try await TorrentStorage.open(metadata: metadata, destination: destination, stateDirectory: state)
			guard try await reopened.snapshot().verifiedPieces.count == storage.layout.pieceCount else {
				throw StorageFailure.invalid("replay checkpoint")
			}
			try await reopened.shutdown()
		}
	}

	static func prepare(layout: StorageLayout, seed: URL, capture: URL, whole: Bool) throws -> [Job] {
		guard layout.pieceLength == 262144, layout.files.allSatisfy({ !$0.pad && $0.size.isMultiple(of: 262144) }) else {
			throw StorageFailure.invalid("expected piece-aligned replay fixture")
		}
		let files = try layout.files.map { try Data(contentsOf: seed.appendingPathComponent($0.path)) }
		let pieces = try (0..<layout.pieceCount).map { piece -> Data in
			let segments = try layout.segments(piece: piece, count: layout.pieceLength)
			guard segments.count == 1, let s = segments.first else { throw StorageFailure.invalid("replay segment") }
			return files[s.file][Int(s.offset)..<(Int(s.offset) + s.count)]
		}
		let batches = try JSONDecoder().decode([[Int]].self, from: Data(contentsOf: capture))
		var seen = Array(repeating: UInt16(0), count: pieces.count)
		var jobs: [Job] = []
		for batch in batches {
			guard (1...16).contains(batch.count) else { throw StorageFailure.invalid("replay batch size") }
			var writes: [StorageWrite] = [], completed: [Int] = []
			for block in batch {
				let piece = block / 16, offset = block % 16 * 16384
				guard block >= 0, pieces.indices.contains(piece) else { throw StorageFailure.invalid("replay block index") }
				let mask = UInt16(1) << (block % 16)
				guard seen[piece] & mask == 0 else { throw StorageFailure.invalid("duplicate replay block") }
				seen[piece] |= mask
				let data = pieces[piece]
				if !whole {
					let start = data.startIndex + offset
					writes.append(StorageWrite(piece: piece, offset: offset, data: data[start..<(start + 16384)]))
				}
				if seen[piece] == .max {
					if whole { jobs.append(Job(writes: [StorageWrite(piece: piece, offset: 0, data: data)], completed: [piece])) }
					else { completed.append(piece) }
				}
			}
			if !whole { jobs.append(Job(writes: writes, completed: completed)) }
		}
		guard seen.allSatisfy({ $0 == .max }) else { throw StorageFailure.invalid("incomplete replay capture") }
		return jobs
	}

	static func cpu() throws -> (user: Double, kernel: Double) {
		var usage = rusage()
		guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw POSIXError(.EIO) }
		func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
		return (seconds(usage.ru_utime), seconds(usage.ru_stime))
	}

	static func run(root: URL, workload: String, mode: String) async throws {
		guard ["single", "concurrent", "many"].contains(workload), ["current", "piece"].contains(mode) else {
			throw StorageFailure.invalid("replay arguments")
		}
		let folder = root.appendingPathComponent(workload), seed = folder.appendingPathComponent("seed")
		let run = root.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: run) }
		let budget = workload == "many" ? DownloadWriteBufferBudget() : nil
		var torrents: [Torrent] = []
		for i in 0..<(workload == "concurrent" ? 4 : 1) {
			let format = workload == "many" ? "hybrid" : "v1"
			let file = folder.appendingPathComponent("\(format)-\(i).torrent")
			let metadata = try TorrentMetadata(contentsOf: file)
			let destination = run.appendingPathComponent("data-\(i)"), state = run.appendingPathComponent("state-\(i)")
			let store = try await TorrentStorage.open(metadata: metadata, destination: destination, stateDirectory: state,
				checkpointPolicy: .managed, readPolicy: .trustedVerified)
			let jobs = try prepare(layout: store.layout, seed: seed, capture: file.appendingPathExtension("jobs"), whole: mode == "piece")
			torrents.append(Torrent(metadata: metadata, destination: destination, state: state, storage: store, jobs: jobs))
		}
		guard torrents.reduce(Int64(0), { $0 + $1.storage.layout.totalBytes }) == 1_073_741_824 else {
			throw StorageFailure.invalid("expected 1 GiB")
		}
		let before = StorageDiagnostics.snapshot(), start = try cpu()
		try await withThrowingTaskGroup(of: Void.self) { group in
			for torrent in torrents { group.addTask { try await torrent.write(budget: budget) } }
			try await group.waitForAll()
		}
		let end = try cpu(), after = StorageDiagnostics.snapshot()
		var result: [String: Any] = ["workload": workload, "mode": mode]
		if StorageDiagnostics.enabled {
			for key in ["writeProfile.jobs", "writeProfile.syscallAttempts", "descriptorOpens", "descriptorDuplicates", "fileDescriptorInspections", "bytesHashed"] {
				result[key] = after[key, default: 0] - before[key, default: 0]
			}
		} else {
			result["user"] = end.user - start.user
			result["kernel"] = end.kernel - start.kernel
		}
		for torrent in torrents { try await torrent.check(seed: seed) }
		print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
	}
}
