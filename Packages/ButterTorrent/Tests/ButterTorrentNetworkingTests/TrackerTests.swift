import Foundation
import Testing
import ButterTorrentMetadata
@testable import ButterTorrentNetworking

@Suite struct TrackerTests {
	@Test func binaryAnnounceAndExistingPasskey() throws {
		var request = trackerRequest()
		request.event = .started; request.trackerID = Data([0, 43, 255])
		let url = try request.url(for: URL(string: "https://tracker.invalid/announce?passkey=a%2Bb")!)
		let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.percentEncodedQuery!
		#expect(query.contains("passkey=a%2Bb") && query.contains("info_hash=%00%01"))
		#expect(query.contains("trackerid=%00%2B%FF") && query.contains("event=started") && query.contains("compact=1"))
		for value in ["http://127.0.0.1/admin", "https://t.invalid/?info_hash=x", "https://t.invalid/?event=stopped", "https://t.invalid/?%74rackerid=x"] {
			#expect(throws: HTTPServiceError.self) { try trackerRequest().url(for: URL(string: value)!) }
		}
		for (host, local, loopback) in [
			("127.0.0.2", true, true), ("localhost", true, true), ("[::1]", true, true), ("[::ffff:127.0.0.1]", true, true),
			("10.0.0.1", true, false), ("172.16.0.1", true, false), ("192.168.1.1", true, false), ("[fc00::1]", true, false),
			("8.8.8.8", false, false), ("[2001:db8::1]", false, false)
		] {
			let url = URL(string: "http://\(host)/announce")!
			#expect(HTTPURL.localLiteral(url) == local)
			#expect(HTTPURL.localLiteral(url, loopbackOnly: true) == loopback)
		}
	}
	@Test func compactAndDictionaryResponses() throws {
		let data = try bencode([
			"interval": .integer(60), "peers": .bytes(Data([127, 0, 0, 1, 0x1a, 0xe1, 127, 0, 0, 1, 0x1a, 0xe1])),
			"peers6": .bytes(Data(repeating: 0, count: 15) + Data([1, 0x1a, 0xe2])),
			"tracker id": .bytes(Data([0, 255])), "complete": .integer(4), "incomplete": .integer(2)
		])
		let response = try TrackerResponse(data)
		#expect(response.peers.map(\.address) == ["127.0.0.1", "::1"])
		#expect(response.peers.map(\.port) == [6881, 6882] && response.complete == 4)
		let entry = BencodeValue.dictionary([Data("ip".utf8): .bytes(Data("2001:db8::1".utf8)), Data("port".utf8): .integer(80)])
		let list = try TrackerResponse(bencode(["interval": .integer(1), "peers": .list([entry])]))
		#expect(list.peers.first?.address == "2001:db8::1")
	}
	@Test func failuresAndMalformedPeerBounds() throws {
		let cases: [[String: BencodeValue]] = [
			["failure reason": .bytes(Data("denied".utf8))],
			["interval": .integer(0)], ["interval": .integer(1), "min interval": .bytes(Data())],
			["interval": .integer(1), "peers": .bytes(Data([1]))],
			["interval": .integer(1), "peers6": .bytes(Data(repeating: 0, count: 17))],
			["interval": .integer(1), "peers": .bytes(Data([127, 0, 0, 1, 0, 0]))],
			["interval": .integer(1), "complete": .integer(-1)]
		]
		for fields in cases { let data = try bencode(fields); #expect(throws: (any Error).self) { try TrackerResponse(data) } }
		let peers = try bencode(["interval": .integer(1), "peers": .bytes(Data([127, 0, 0, 1, 0, 80]))])
		#expect(throws: HTTPServiceError.self) { try TrackerResponse(peers, maximumPeers: 0) }
	}
	@Test func localAnnounceRoundTrip() async throws {
		let body = try trackerBody()
		let server = try await HTTPFixture.start { input in
			guard input.target.hasPrefix("/announce?"), input.target.contains("info_hash=%00%01"), input.target.contains("event=started") else { return .init(status: 400) }
			return .init(body: body, chunked: true)
		}
		var request = trackerRequest(); request.event = .started
		do {
			let response = try await HTTPTrackerClient().announce(to: server.url.appendingPathComponent("announce"), request: request)
			#expect(response.interval == 60 && response.peers.isEmpty)
		} catch { await server.stop(); throw error }
		await server.stop()
	}
}

actor ScriptedTracker: TrackerAnnouncing {
	struct Call: Sendable { let url: URL; let request: TrackerRequest }
	var calls: [Call] = []
	var failures: Set<String> = []
	func fail(_ hosts: Set<String>) { failures = hosts }
	func announce(to tracker: URL, request: TrackerRequest) async throws -> TrackerResponse {
		calls.append(Call(url: tracker, request: request))
		if failures.contains(tracker.host!) { throw HTTPServiceError.status(503) }
		return try TrackerResponse(bencode(["interval": .integer(60), "min interval": .integer(90), "peers": .bytes(Data()), "tracker id": .bytes(Data("session".utf8))]))
	}
}

@Suite struct TrackerLifecycleTests {
	@Test(arguments: [false, true]) func privateFailoverKeepsItsTrackerUntilFailure(_ isPrivate: Bool) async throws {
		let a = URL(string: "https://a.invalid/announce")!, b = URL(string: "https://b.invalid/announce")!
		let client = ScriptedTracker(), clock = TestClock(), switched = TrackerSwitchRecorder()
		let session = try TrackerAnnouncer(tiers: [[a], [b]], request: trackerRequest(), client: client, clock: clock,
			privateTorrent: isPrivate, beforeSwitch: { await switched.record($0) })
		try await session.start(TrackerCounters(left: 3))
		await client.fail(["a.invalid"]); clock.advance(90)
		_ = try await session.announceIfDue(TrackerCounters(left: 3))
		#expect(await client.calls.map(\.url) == [a, a, b])
		#expect(await switched.urls == (isPrivate ? [b] : []))
		await client.fail([]); clock.advance(90)
		_ = try await session.announceIfDue(TrackerCounters(left: 3))
		#expect(await client.calls.last?.url == (isPrivate ? b : a))
		await client.fail(["b.invalid"]); clock.advance(90)
		_ = try await session.announceIfDue(TrackerCounters(left: 3))
		#expect(await client.calls.last?.url == a)
		#expect(await switched.urls == (isPrivate ? [b, a] : []))
		await client.fail([])
		try await session.stop(TrackerCounters(left: 3))
	}
	@Test func appendingATrackerRecoversAnActiveFailedLifecycle() async throws {
		let a = URL(string: "https://a.invalid/announce")!, b = URL(string: "https://b.invalid/announce")!
		let client = ScriptedTracker(), clock = TestClock()
		await client.fail(["a.invalid"])
		let session = try TrackerAnnouncer(tiers: [[a]], request: trackerRequest(), client: client, clock: clock)
		await #expect(throws: (any Error).self) { try await session.start(TrackerCounters(left: 3)) }
		try await session.append(b); try await session.append(b)
		#expect(try await session.announceIfDue(TrackerCounters(left: 3)) != nil)
		try await session.stop(TrackerCounters(left: 3))
		let calls = await client.calls.filter { $0.url == b }
		#expect(calls.map { $0.request.event } == [.started, .stopped])
		#expect(await session.messages[a] != nil)
	}
	@Test func tiersPromotionAndLifecycle() async throws {
		let a = URL(string: "https://a.invalid/announce")!, b = URL(string: "https://b.invalid/announce")!, c = URL(string: "https://c.invalid/announce")!
		let client = ScriptedTracker(), clock = TestClock()
		await client.fail(["a.invalid"])
		let session = try TrackerAnnouncer(tiers: [[a, b], [c]], request: trackerRequest(), client: client, clock: clock, order: { $0 })
		try await session.start(TrackerCounters(left: 3))
		#expect(await client.calls.map(\.url) == [a, b])
		#expect(try await session.announceIfDue(TrackerCounters(left: 2)) == nil)
		clock.advance(90)
		_ = try await session.announceIfDue(TrackerCounters(left: 2))
		let periodic = await client.calls.last
		#expect(periodic?.url == b && periodic?.request.event == nil)
		try await session.complete(TrackerCounters(downloaded: 3, left: 0))
		try await session.complete(TrackerCounters(downloaded: 3, left: 0))
		try await session.stop(TrackerCounters(downloaded: 3, left: 0))
		let calls = await client.calls
		#expect(calls.map { $0.request.event?.rawValue ?? "periodic" } == ["started", "started", "periodic", "completed", "stopped"])
		#expect(calls.last?.request.trackerID == Data("session".utf8))
		#expect(await session.status.phase == .stopped)
	}
	@Test func backoffFallbackAndInitiallyCompleteSeed() async throws {
		let a = URL(string: "https://a.invalid/announce")!, b = URL(string: "https://b.invalid/announce")!
		let client = ScriptedTracker(), clock = TestClock()
		await client.fail(["a.invalid", "b.invalid"])
		let session = try TrackerAnnouncer(tiers: [[a], [b]], request: trackerRequest(left: 0), client: client, clock: clock, order: { $0 })
		do { try await session.start(TrackerCounters(left: 0)); Issue.record("Failed trackers returned success") } catch { }
		let failed = await session.status
		#expect(failed.nextAnnounce == 130 && failed.consecutiveFailures == 1)
		#expect(try await session.announceIfDue(TrackerCounters(left: 0)) == nil)
		clock.advance(30)
		do { _ = try await session.announceIfDue(TrackerCounters(left: 0)); Issue.record("Failed trackers returned success") } catch { }
		#expect(await session.status.nextAnnounce == 190)
		await client.fail([]); clock.advance(60)
		_ = try await session.announceIfDue(TrackerCounters(left: 0))
		#expect(try await session.complete(TrackerCounters(left: 0)) == nil)
		try await session.stop(TrackerCounters(left: 0))
		#expect(await client.calls.filter { $0.request.event == .completed }.isEmpty)
	}
	@Test func cancellationSettlesWithoutBackoffAndBlocksOverlappingCommands() async throws {
		let http = BlockingHTTP()
		let session = try TrackerAnnouncer(tiers: [[URL(string: "https://tracker.invalid/announce")!]], request: trackerRequest(), client: HTTPTrackerClient(transport: http))
		let task = Task { try await session.start(TrackerCounters(left: 3)) }
		try await http.waitForRequests(1)
		do { try await session.stop(TrackerCounters(left: 3)); Issue.record("Overlapping stop admitted") }
		catch { #expect(error as? HTTPServiceError == .busy) }
		task.cancel()
		do { _ = try await task.value; Issue.record("Cancelled tracker returned success") } catch { #expect(error is CancellationError) }
		#expect(await http.cancelled == 1)
		#expect(await session.status.consecutiveFailures == 0)
		let retry = Task { try await session.announceIfDue(TrackerCounters(left: 3)) }
		try await http.waitForRequests(2)
		await http.release(HTTPResponse(status: 200, body: try trackerBody()))
		#expect(try await retry.value?.interval == 60)
	}
}

private actor TrackerSwitchRecorder {
	var urls: [URL] = []
	func record(_ url: URL) { urls.append(url) }
}
