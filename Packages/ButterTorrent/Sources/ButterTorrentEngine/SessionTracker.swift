import Foundation
import ButterTorrentMetadata
import ButterTorrentNetworking

public struct SessionTrackerSnapshot: Sendable {
	public let url: String
	public let message: String
}

// Owns one announce lifecycle, with a non-seeding placeholder until metadata is known.
actor SessionTracker {
	private static let stopBudget = TransferPermits(4)
	private let owner: ManagedTransfer?
	private let resolver: SessionMagnetResolver?
	private let announcer: TrackerAnnouncer
	private let clock: any TransportClock
	private let candidates: PeerCandidateQueue<TrackerPeer>?
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
		self.owner = owner; self.clock = clock; resolver = nil
		let candidates = PeerCandidateQueue(connect: peer); self.candidates = candidates
		self.baseline = baseline; counters = Self.counters(initial, metadata: metadata, baseline: baseline); self.initial = counters
		announcer = try Self.makeAnnouncer(tiers: metadata.trackerTiers, hashes: metadata.hashes, peerID: peerID, port: port, preferV2: preferV2,
			counters: counters, client: client, clock: clock, privateTorrent: metadata.inspection.private) { _ in
				await candidates.reset(); try await owner.disconnectPeers()
			}
	}
	init(magnet: Magnet, resolver: SessionMagnetResolver, peerID: Data, port: UInt16, preferV2: Bool, client: any TrackerAnnouncing, clock: any TransportClock) throws {
		owner = nil; candidates = nil; self.resolver = resolver; self.clock = clock
		// The reference announces 16 KiB left when there is no file layout yet.
		let unknown = TrackerCounters(left: 16_384); initial = unknown; counters = unknown; baseline = TrackerCounters(left: 0)
		announcer = try Self.makeAnnouncer(tiers: magnet.trackers.map { [$0] }, hashes: magnet.hashes, peerID: peerID, port: port, preferV2: preferV2,
			counters: unknown, client: client, clock: clock, privateTorrent: false) { _ in }
	}
	private static func makeAnnouncer(tiers: [[String]], hashes: InfoHashes, peerID: Data, port: UInt16, preferV2: Bool, counters: TrackerCounters,
		client: any TrackerAnnouncing, clock: any TransportClock, privateTorrent: Bool, beforeSwitch: @escaping @Sendable (URL) async throws -> Void) throws -> TrackerAnnouncer {
		let v2 = hashes.v2.map { Data($0.prefix(20)) }, hash = preferV2 ? v2 ?? hashes.v1! : hashes.v1 ?? v2!
		return try TrackerAnnouncer(tiers: tiers.map { tier in
			try tier.map { guard let url = URL(string: $0) else { throw HTTPServiceError.invalid("tracker URL") }; return url }
		}, request: TrackerRequest(infoHash: hash, peerID: peerID, port: port, counters: counters), client: client, clock: clock,
			additionalInfoHashes: [hashes.v1, v2].compactMap { $0 }.filter { $0 != hash }, privateTorrent: privateTorrent, beforeSwitch: beforeSwitch)
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
	func halt() async { stopped = true; loop?.cancel(); await candidates?.halt() }
	func messages() async -> [URL: String] { await announcer.messages }
	func failure() -> String { lastFailure }
	private func tick() async {
		guard !stopped else { return }
		do {
			if let owner {
				let snapshot = try await owner.snapshot(); guard snapshot.running else { return }
				counters = Self.counters(snapshot, metadata: owner.metadata, baseline: baseline)
			}
			let response: TrackerResponse?
			if !started { started = true; response = try await announcer.start(initial) }
			else if !completion && initial.left > 0 && counters.left == 0 { completion = true; response = try await announcer.complete(counters) }
			else { response = try await announcer.announceIfDue(counters) }
			guard !stopped, !Task.isCancelled else { return }
			lastFailure = ""
			if let response {
				if let resolver { await resolver.enqueue(response.peers.compactMap { try? NetworkEndpoint($0.address, port: $0.port) }) }
				else { await candidates?.enqueue(response.peers) }
			}
		} catch { if !Task.isCancelled { lastFailure = error.localizedDescription } }
	}
	func stop() async {
		let task: Task<Void, Never>
		if let stopping { task = stopping }
		else { stopped = true; loop?.cancel(); task = Task { await self.finish() }; stopping = task }
		await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
	}
	private func finish() async {
		await candidates?.halt(); await loop?.value; loop = nil; await candidates?.stop()
		if let owner, let snapshot = try? await owner.snapshot() { counters = Self.counters(snapshot, metadata: owner.metadata, baseline: baseline) }
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
	deinit { loop?.cancel(); if let candidates { Task { await candidates.stop() } } }
}
