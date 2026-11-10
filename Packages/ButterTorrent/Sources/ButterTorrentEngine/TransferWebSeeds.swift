import Foundation
import ButterTorrentNetworking

/// WebSeedSnapshot reports source progress and failures independently of verified piece progress.
public struct WebSeedSnapshot: Sendable {
	public let id: UUID
	public let url: String
	public let downloaded: Int64
	public let active: Bool
	public let banned: Bool
	public let message: String
}

// Actor-confined source state. The managed owner retains the client's bans across pauses.
final class TransferWebSeed {
	let id = UUID()
	let url: URL
	let pieceProtocol: Bool
	var downloaded: Int64 = 0
	var active = false
	var banned = false
	var registered = false
	var retryAt: TimeInterval = 0
	var message = ""
	init(url: URL, pieceProtocol: Bool) { self.url = url; self.pieceProtocol = pieceProtocol }
	var snapshot: WebSeedSnapshot { WebSeedSnapshot(id: id, url: url.absoluteString, downloaded: downloaded, active: active, banned: banned, message: message) }
}

extension TCPTransfer {
	func startWebSeeds(client: WebSeedClient, admission: TransferPermits) {
		webClient = client; webAdmission = admission
		for (urls, pieceProtocol) in [(metadata.webSeeds, false), (metadata.httpSeeds, true)] {
			for text in urls where webSeeds.count < 128 {
				guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
				!webSeeds.contains(where: { $0.url == url && $0.pieceProtocol == pieceProtocol }) else { continue }
				let seed = TransferWebSeed(url: url, pieceProtocol: pieceProtocol)
				if pieceProtocol && metadata.hashes.v1 == nil { seed.banned = true; seed.message = "HTTP piece seeds require a v1 info hash." }
				webSeeds.append(seed)
			}
		}
		guard !webSeeds.isEmpty else { return }; let clock = clock
		webTask = Task { [weak self] in
			while !Task.isCancelled {
				guard let delay = await self?.webSeedStep() else { return }
				if delay > 0 { do { try await clock.sleep(for: delay) } catch { return } }
			}
		}
	}
	private func webSeedStep() async -> TimeInterval? {
		guard !stopping, storageError == nil, !picker.complete, let client = webClient, let admission = webAdmission else { return nil }
		for seed in webSeeds where !seed.banned && clock.now() >= seed.retryAt {
			let status = await client.status(for: seed.url)
			if status.banned { seed.banned = true; seed.message = status.error ?? ""; continue }
			seed.retryAt = status.retryAt
			guard clock.now() >= seed.retryAt, !Task.isCancelled, !stopping else { continue }
			do {
				if !seed.registered { picker.update(seed.id, bits: try PieceBitfield(count: picker.layout.pieceCount, pieces: picker.wanted)); seed.registered = true }
				guard let block = picker.allocate(seed.id, limit: 1, now: clock.now(), eligible: hashReady).first else { continue }
				seed.active = true
				let initialBytes = seed.downloaded
				var delivered = false
				do {
					let bytes = try await fetchWebBlock(seed, block: block, client: client, admission: admission)
					try Task.checkCancellation()
					try await disk.acquire()
					do { try Task.checkCancellation(); delivered = true; try await receiveBlock(seed.id, block: block, bytes: bytes, payloadBytes: seed.downloaded - initialBytes) }
					catch { await disk.release(); throw error }
					await disk.release(); seed.active = false
					if !seed.banned { seed.message = "" }; fillAll(); return 0
				} catch {
					if !delivered { recordUnusablePayload(seed.downloaded - initialBytes) }
					seed.active = false; picker.rejected(seed.id, block: block)
					if Task.isCancelled || error is CancellationError { picker.remove(seed.id); discardUnretainedPayload(); seed.registered = false; return nil }
					seed.message = error.localizedDescription
					if case PeerFailure.corruptPiece = error { await banWebSeed(seed) }
					else { let status = await client.status(for: seed.url); seed.retryAt = max(clock.now() + 1, status.retryAt) }
					picker.remove(seed.id); discardUnretainedPayload(); seed.registered = false; fillAll()
				}
			} catch { seed.message = error.localizedDescription; seed.retryAt = clock.now() + 30 }
		}
		return 1
	}
	private func fetchWebBlock(_ seed: TransferWebSeed, block: PeerBlock, client: WebSeedClient, admission: TransferPermits) async throws -> Data {
		let url = seed.url
		if seed.pieceProtocol {
			let hash = metadata.hashes.v1!, size = try picker.lengths[block.piece] ?? picker.layout.length(of: block.piece)
			return try await fetchWebData(seed, admission: admission) {
				try await client.pieceRange(from: url, infoHash: hash, piece: block.piece, pieceSize: size, range: block.offset..<(block.offset + block.length))
			}
		}
		var bytes = Data(); bytes.reserveCapacity(block.length)
		let multiFile = metadata.document.root["info"]?["files"] != nil || metadata.inspection.files.contains { $0.path.contains("/") }
		for segment in try picker.layout.segments(piece: block.piece, offset: block.offset, count: block.length) {
			try Task.checkCancellation()
			if segment.padding { bytes.append(Data(repeating: 0, count: segment.count)); continue }
			let file = metadata.inspection.files[segment.file]
			bytes.append(try await fetchWebData(seed, admission: admission) {
				try await client.fileRange(from: url, path: file.path.split(separator: "/").map(String.init), fileSize: file.size,
					range: segment.offset..<(segment.offset + Int64(segment.count)), multiFile: multiFile)
			})
		}
		return bytes
	}
	private func fetchWebData(_ seed: TransferWebSeed, admission: TransferPermits, operation: @Sendable () async throws -> Data) async throws -> Data {
		try await admission.acquire()
		let bytes: Data
		do { bytes = try await operation() } catch { await admission.release(); throw error }
		await admission.release()
		downloaded = min(Int64.max - Int64(bytes.count), downloaded) + Int64(bytes.count); seed.downloaded += Int64(bytes.count)
		try await downloadRate.consume(bytes.count); try Task.checkCancellation()
		return bytes
	}
	func banWebSeed(_ seed: TransferWebSeed) async {
		seed.banned = true; seed.registered = false
		picker.remove(seed.id); discardUnretainedPayload(); try? await webClient?.reportCorruption(from: seed.url)
		seed.message = HTTPServiceError.banned.localizedDescription
	}
}
