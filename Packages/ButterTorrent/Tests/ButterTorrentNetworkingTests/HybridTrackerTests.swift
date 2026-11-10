import Foundation
import Testing
import ButterTorrentMetadata
@testable import ButterTorrentNetworking

@Suite struct HybridTrackerTests {
	private let first = trackerRequest().infoHash
	private let second = Data(repeating: 99, count: 20)
	private let a = URL(string: "https://a.invalid/announce")!
	private let b = URL(string: "https://b.invalid/announce")!
	@Test func identifiersKeepIndependentIntervalsIDsAndLifecycleEvents() async throws {
		let client = HybridTrackerClient(first: first, second: second), clock = TestClock()
		let session = try TrackerAnnouncer(tiers: [[a]], request: trackerRequest(), client: client, clock: clock, additionalInfoHashes: [second])
		let initial = try await session.start(TrackerCounters(left: 3))
		#expect(Set(initial.peers.map(\.port)) == [6880, 6881, 6882])
		#expect(await session.status.nextAnnounce == 190)
		clock.advance(89); #expect(try await session.announceIfDue(TrackerCounters(left: 3)) == nil)
		clock.advance(1)
		let firstUpdate = try await session.announceIfDue(TrackerCounters(left: 3))
		#expect(Set(firstUpdate!.peers.map(\.port)) == [6880, 6881])
		#expect(await client.calls.map { $0.request.infoHash } == [first, second, first])
		#expect(await session.status.nextAnnounce == 220)
		clock.advance(29); #expect(try await session.announceIfDue(TrackerCounters(left: 3)) == nil)
		clock.advance(1)
		let secondUpdate = try await session.announceIfDue(TrackerCounters(left: 3))
		#expect(Set(secondUpdate!.peers.map(\.port)) == [6880, 6882])
		try await session.complete(TrackerCounters(downloaded: 3, left: 0))
		#expect(try await session.complete(TrackerCounters(downloaded: 3, left: 0)) == nil)
		try await session.stop(TrackerCounters(downloaded: 3, left: 0))
		for hash in [first, second] {
			let calls = await client.calls.filter { $0.request.infoHash == hash }
			#expect(calls.map { $0.request.event } == [.started, nil, .completed, .stopped])
			#expect(calls.last?.request.wantedPeers == 0)
		}
	}
	@Test func completionRetriesOnlyTheIdentityWhoseEventFailed() async throws {
		let client = HybridTrackerClient(first: first, second: second), clock = TestClock()
		let session = try TrackerAnnouncer(tiers: [[a]], request: trackerRequest(), client: client, clock: clock, additionalInfoHashes: [second])
		try await session.start(TrackerCounters(left: 3)); await client.failNextCompletion(second)
		try await session.complete(TrackerCounters(downloaded: 3, left: 0))
		#expect(await session.status.consecutiveFailures == 0)
		clock.advance(30); _ = try await session.announceIfDue(TrackerCounters(downloaded: 3, left: 0))
		#expect(await client.calls.filter { $0.request.infoHash == first && $0.request.event == .completed }.count == 1)
		#expect(await client.calls.filter { $0.request.infoHash == second && $0.request.event == .completed }.count == 2)
		let before = await client.calls.count
		#expect(try await session.complete(TrackerCounters(downloaded: 3, left: 0)) == nil)
		#expect(await client.calls.count == before)
		try await session.stop(TrackerCounters(downloaded: 3, left: 0))
	}
	@Test func partialAcceptanceKeepsOnePrivateTrackerAndFailoverDrainsOnce() async throws {
		let client = HybridTrackerClient(first: first, second: second), clock = TestClock(), switches = TrackerSwitchRecorder()
		await client.failHashes([first])
		let session = try TrackerAnnouncer(tiers: [[a], [b]], request: trackerRequest(), client: client, clock: clock,
			additionalInfoHashes: [second], privateTorrent: true, beforeSwitch: { await switches.record($0) })
		let initial = try await session.start(TrackerCounters(left: 3))
		#expect(Set(initial.peers.map(\.port)) == [6880, 6882])
		clock.advance(30)
		#expect(try await session.announceIfDue(TrackerCounters(left: 3))?.peers.isEmpty == true)
		#expect(await client.calls.allSatisfy { $0.url == a }); #expect(await switches.urls.isEmpty)
		await client.failHosts(["a.invalid"]); clock.advance(90)
		_ = try await session.announceIfDue(TrackerCounters(left: 3))
		#expect(await switches.urls == [b])
		#expect(await client.calls.suffix(2).allSatisfy { $0.url == b })
		await client.failHosts([]); await client.failHashes([])
		try await session.stop(TrackerCounters(left: 3))
	}
	@Test func cancelledSecondAnnounceStopsOnlyTheAcknowledgedIdentity() async throws {
		let client = HybridTrackerClient(first: first, second: second)
		await client.block(second)
		let session = try TrackerAnnouncer(tiers: [[a]], request: trackerRequest(), client: client, additionalInfoHashes: [second])
		let task = Task { try await session.start(TrackerCounters(left: 3)) }
		try await deadline { while await client.calls.count < 2 { try await Task.sleep(for: .milliseconds(1)) } }
		task.cancel(); await #expect(throws: CancellationError.self) { try await task.value }
		try await session.stop(TrackerCounters(left: 3))
		#expect(await client.calls.filter { $0.request.event == .stopped }.map { $0.request.infoHash } == [first])
		#expect(await session.status.phase == .stopped)
	}
	@Test func duplicateAndMalformedIdentifiersRemainBounded() async throws {
		for hashes in [[Data(repeating: 0, count: 19)], [first, second]] {
			#expect(throws: HTTPServiceError.self) { try TrackerAnnouncer(tiers: [[a]], request: trackerRequest(), additionalInfoHashes: hashes) }
		}
		let client = HybridTrackerClient(first: first, second: second)
		let session = try TrackerAnnouncer(tiers: [[a]], request: trackerRequest(), client: client, additionalInfoHashes: [first])
		try await session.start(TrackerCounters(left: 3)); try await session.stop(TrackerCounters(left: 3))
		#expect(await client.calls.count == 2)
	}
	@Test func combinedRepliesShareOnePeerLimit() throws {
		func response(_ ports: Range<Int>) throws -> TrackerResponse {
			var peers = Data()
			for port in ports { peers.append(contentsOf: [127, 0, 0, 1, UInt8(port >> 8), UInt8(port & 255)]) }
			return try TrackerResponse(bencode(["interval": .integer(30), "peers": .bytes(peers)]))
		}
		let first = try response(1..<2001), second = try response(1001..<3001)
		let merged = try TrackerResponse(merging: [first, second], peerResponses: [first, second])
		#expect(merged.peers.count == 2000 && Set(merged.peers).count == 2000)
		let fresh = try TrackerResponse(merging: [first, second], peerResponses: [second])
		#expect(fresh.peers.first?.port == 1001 && fresh.peers.last?.port == 3000)
		let disjoint = try response(3001..<5001)
		let balanced = try TrackerResponse(merging: [first, disjoint], peerResponses: [first, disjoint])
		#expect(balanced.peers.filter { $0.port <= 2000 }.count == 1000)
		#expect(balanced.peers.filter { $0.port >= 3001 }.count == 1000)
	}
}

private actor HybridTrackerClient: TrackerAnnouncing {
	struct Call: Sendable { let url: URL; let request: TrackerRequest }
	let first: Data, second: Data
	var calls: [Call] = []
	private var failedHashes: Set<Data> = [], failedHosts: Set<String> = []
	private var completionFailure: Data?, blocked: Data?
	init(first: Data, second: Data) { self.first = first; self.second = second }
	func failHashes(_ hashes: Set<Data>) { failedHashes = hashes }
	func failHosts(_ hosts: Set<String>) { failedHosts = hosts }
	func failNextCompletion(_ hash: Data) { completionFailure = hash }
	func block(_ hash: Data) { blocked = hash }
	func announce(to tracker: URL, request: TrackerRequest) async throws -> TrackerResponse {
		calls.append(Call(url: tracker, request: request))
		let token = Data(tracker.absoluteString.utf8) + request.infoHash
		guard request.infoHash == first || request.infoHash == second else { throw HTTPServiceError.invalid("fixture identity") }
		if request.event != .started, request.trackerID != token { throw HTTPServiceError.invalid("tracker ID crossed identities or endpoints") }
		if request.infoHash == blocked, request.event == .started { try await Task.sleep(for: .seconds(60)) }
		if failedHashes.contains(request.infoHash) || failedHosts.contains(tracker.host!) { throw HTTPServiceError.status(503) }
		if request.event == .completed, completionFailure == request.infoHash { completionFailure = nil; throw HTTPServiceError.status(503) }
		let peers = [6880, request.infoHash == first ? 6881 : 6882].map { port in
			BencodeValue.dictionary([Data("ip".utf8): .bytes(Data("127.0.0.1".utf8)), Data("port".utf8): .integer(Int64(port))])
		}
		return try TrackerResponse(bencode(["interval": .integer(request.infoHash == first ? 30 : 60), "min interval": .integer(request.infoHash == first ? 90 : 120), "peers": .list(peers), "tracker id": .bytes(token)]))
	}
}
