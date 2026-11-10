import Foundation
import ButterTorrentMetadata
import ButterTorrentNetworking

public struct SessionTrackerSnapshot: Sendable {
	public let url: String
	public let message: String
}

// Owns one announce lifecycle. All counters come from verified managed storage.
actor SessionTracker {
	private static let stopBudget = TransferPermits(4)
	private let owner: ManagedTransfer
	private let announcer: TrackerAnnouncer
	private let clock: any TransportClock
	private let candidates: PeerCandidateQueue<TrackerPeer>
	private let initial: TrackerCounters
	private let baseline: TrackerCounters
	private var counters: TrackerCounters
	private var started = false
	private var completion = false
	private var stopped = false
	private var loop: Task<Void, Never>?
	private var stopping: Task<Void, Never>?
	private var lastFailure = ""
	init(metadata: TorrentMetadata, owner: ManagedTransfer, peerID: Data, port: UInt16, preferV2: Bool, initial: ManagedTransferSnapshot,
		baseline: TrackerCounters, client: any TrackerAnnouncing, clock: any TransportClock, peer: @escaping @Sendable (TrackerPeer) async -> Void) throws {
		self.owner = owner; self.clock = clock
		let candidates = PeerCandidateQueue(connect: peer); self.candidates = candidates
		self.baseline = baseline; counters = Self.counters(initial, metadata: metadata, baseline: baseline); self.initial = counters
		let hash = preferV2 ? metadata.hashes.v2.map { Data($0.prefix(20)) } ?? metadata.hashes.v1! : metadata.hashes.v1 ?? Data(metadata.hashes.v2!.prefix(20))
		announcer = try TrackerAnnouncer(tiers: metadata.trackerTiers.map { tier in
			try tier.map { guard let url = URL(string: $0) else { throw HTTPServiceError.invalid("tracker URL") }; return url }
		}, request: TrackerRequest(infoHash: hash, peerID: peerID, port: port, counters: counters), client: client, clock: clock,
			privateTorrent: metadata.inspection.private, beforeSwitch: { _ in await candidates.reset(); try await owner.disconnectPeers() })
	}
	func start() {
		guard loop == nil, !stopped else { return }; let clock = clock
		loop = Task { [weak self] in
			while !Task.isCancelled {
				await self?.tick()
				do { try await clock.sleep(for: 1) } catch { return }
			}
		}
	}
	func append(_ url: URL) async throws { try await announcer.append(url) }
	func halt() async { stopped = true; loop?.cancel(); await candidates.halt() }
	func messages() async -> [URL: String] { await announcer.messages }
	func failure() -> String { lastFailure }
	private func tick() async {
		guard !stopped else { return }
		do {
			let snapshot = try await owner.snapshot(); guard snapshot.running else { return }
			counters = Self.counters(snapshot, metadata: owner.metadata, baseline: baseline)
			let response: TrackerResponse?
			if !started { started = true; response = try await announcer.start(initial) }
			else if !completion && initial.left > 0 && counters.left == 0 { completion = true; response = try await announcer.complete(counters) }
			else { response = try await announcer.announceIfDue(counters) }
			guard !stopped, !Task.isCancelled else { return }
			lastFailure = ""
			if let response { await candidates.enqueue(response.peers) }
		} catch { if !Task.isCancelled { lastFailure = error.localizedDescription } }
	}
	func stop() async {
		let task: Task<Void, Never>
		if let stopping { task = stopping }
		else { stopped = true; loop?.cancel(); task = Task { await self.finish() }; stopping = task }
		await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
	}
	private func finish() async {
		await candidates.halt(); await loop?.value; loop = nil; await candidates.stop()
		if let snapshot = try? await owner.snapshot() { counters = Self.counters(snapshot, metadata: owner.metadata, baseline: baseline) }
		guard started else { return }
		do {
			let counters = counters, announcer = announcer, clock = clock, complete = !completion && initial.left > 0 && counters.left == 0
			if complete { completion = true }
			try await withThrowingTaskGroup(of: Void.self) { group in
				group.addTask {
					try await Self.stopBudget.acquire()
					do { if complete { _ = try? await announcer.complete(counters) }; try await announcer.stop(counters) }
					catch { await Self.stopBudget.release(); throw error }
					await Self.stopBudget.release()
				}
				group.addTask { try await clock.sleep(for: 3); throw NetworkFailure.timedOut }
				defer { group.cancelAll() }; _ = try await group.next()
			}
			lastFailure = ""
		} catch { lastFailure = error.localizedDescription }
	}
	private static func counters(_ snapshot: ManagedTransferSnapshot, metadata: TorrentMetadata, baseline: TrackerCounters) -> TrackerCounters {
		let disk = snapshot.storage, progress = TransferProgress(metadata: metadata, storage: disk)
		let corrupt = max(0, (snapshot.transfer?.corruptBytes ?? disk.corruptBytes) - baseline.corrupt), redundant = max(0, (snapshot.transfer?.redundantBytes ?? disk.redundantBytes) - baseline.redundant)
		let received = max(0, (snapshot.transfer?.downloaded ?? disk.downloaded) - baseline.downloaded)
		return TrackerCounters(uploaded: max(0, (snapshot.transfer?.uploaded ?? disk.uploaded) - baseline.uploaded), downloaded: max(0, received - corrupt - redundant), left: progress.total - progress.verifiedBytes, corrupt: corrupt, redundant: redundant)
	}
	deinit { loop?.cancel(); let candidates = candidates; Task { await candidates.stop() } }
}
