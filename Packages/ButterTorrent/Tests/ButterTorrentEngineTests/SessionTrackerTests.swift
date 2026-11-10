import Foundation
import Testing
import ButterTorrentMetadata
@testable import ButterTorrentNetworking
@testable import ButterTorrentEngine

// Each case owns several sessions; keep independent fixtures within the process-wide disk budget.
extension NativeSessionTests { @Suite struct SessionTrackerTests {
	@Test(arguments: [false, true]) func corruptPayloadIsExcludedFromAnnouncesAcrossPauseAndResume(_ udp: Bool) async throws {
		let fixture = try TrackerSessionFixture(), tracker = RecordingTracker(), clock = ContinuousTransportClock()
		let udpTracker = udp ? LocalUDPTracker(socket: try DatagramSocket(bind: NetworkEndpoint("127.0.0.1", port: 0))) : nil
		await udpTracker?.start()
		do {
			let listener = try await fixture.source.listen()
			await tracker.setPeer(try TrackerPeer(address: "127.0.0.1", port: listener.port))
			await udpTracker?.setPeer(try NetworkEndpoint("127.0.0.1", port: listener.port))
			let url = udpTracker.map { "udp://127.0.0.1:\($0.socket.localEndpoint.port)/announce" } ?? "http://tracker.test/announce"
			let down = try await fixture.download(tiers: [[url]], tracker: tracker, clock: clock)
			try await down.run(id: "transfer", running: true)
			let bad = WirePeer(stream: try await listener.accept(timeout: 3)); defer { bad.stream.close() }
			try await bad.hello(hash: fixture.metadata.hashes.v1!, identity: 13)
			try await bad.seed(pieceCount: 3)
			for block in try await bad.requests(6) where block.piece == 0 { try await bad.reply(block, bytes: fixture.source.bytes, corrupt: block.offset == 0) }
			try await eventually { try await down.snapshot().transfers[0].state.transfer?.corruptBytes == 32768 }
			try await down.pause(id: "transfer")
			if let udpTracker { #expect(await udpTracker.requests.last?.downloaded == 0) }
			else {
				let stopped = await tracker.requests.last!.1.counters
				#expect(stopped.downloaded == 0 && stopped.corrupt == 32768 && stopped.redundant == 0)
			}
			let seed = try await fixture.seed()
			await tracker.setPeer(try TrackerPeer(address: "127.0.0.1", port: seed.snapshot().network.port))
			await udpTracker?.setPeer(try NetworkEndpoint("127.0.0.1", port: seed.snapshot().network.port))
			try await down.run(id: "transfer", running: true)
			try await eventually { try await down.snapshot().transfers[0].state.transfer?.complete == true }
			if let udpTracker { try await eventually { await udpTracker.requests.contains { $0.event == 1 } } }
			else { try await eventually { await tracker.requests.contains { $0.1.event == .completed } } }
			try await down.pause(id: "transfer")
			if let udpTracker {
				let completed = await udpTracker.requests.last!
				#expect(completed.downloaded == Int64(fixture.source.bytes.count) && completed.left == 0)
			} else {
				let completed = await tracker.requests.last!.1.counters
				#expect(completed.downloaded == Int64(fixture.source.bytes.count) && completed.corrupt == 32768 && completed.redundant == 0)
			}
			let state = try await down.snapshot().transfers[0].state.storage
			#expect(state.downloaded == Int64(fixture.source.bytes.count + 32768) && state.corruptBytes == 32768)
		} catch { await fixture.close(); await udpTracker?.close(); throw error }; await fixture.close(); await udpTracker?.close()
	}
	@Test(arguments: [false, true]) func privateFailoverDrainsOldPeersBeforeContactingTheReplacement(_ initialFailure: Bool) async throws {
		let fixture = try TrackerSessionFixture(), clock = EngineClock()
		do {
			let old = try await fixture.seed(empty: true), seed = try await fixture.seed()
			let oldPort = try await old.snapshot().network.port, newPort = try await seed.snapshot().network.port
			let tracker = SwitchingSessionTracker(old: try TrackerPeer(address: "127.0.0.1", port: oldPort), new: try TrackerPeer(address: "127.0.0.1", port: newPort), initialFailure: initialFailure)
			let down = try await fixture.download(tiers: [["http://old.test/announce"], ["http://new.test/announce"]], tracker: tracker, clock: clock)
			await tracker.checkBeforeReplacement { try await down.snapshot().transfers[0].state.transfer?.peers.isEmpty == true }
			try await down.run(id: "transfer", running: true)
			if initialFailure {
				try await eventually { await tracker.initialStarted }
				_ = try await old.connect(id: "transfer", to: NetworkEndpoint("127.0.0.1", port: down.snapshot().network.port))
			}
			try await eventually { try await down.snapshot().transfers[0].state.transfer?.peers.contains { $0.peerID == old.peerID } == true }
			if initialFailure { await tracker.releaseInitialFailure() }
			else { await tracker.failPrimary(true); clock.advance(31) }
			try await eventually { try await down.snapshot().transfers[0].state.transfer?.complete == true }
			#expect(await tracker.oldPeersWereDrained)
			let peers = try await down.snapshot().transfers[0].state.transfer?.peers ?? []
			#expect(!peers.isEmpty && peers.allSatisfy { $0.endpoint?.port == newPort })
			await tracker.failPrimary(false)
			let previous = await tracker.hosts.count; clock.advance(31)
			try await eventually { await tracker.hosts.count > previous }
			#expect(await tracker.hosts.filter { $0 == "old.test" }.count == (initialFailure ? 1 : 2))
		} catch { await fixture.close(); throw error }; await fixture.close()
	}
	@Test(arguments: [true, false]) func settingsRestartTrackersAfterPeerAdmissionReopens(_ rebind: Bool) async throws {
		let fixture = try TrackerSessionFixture(), tracker = RecordingTracker(), clock = EngineClock()
		do {
			let seed = try await fixture.seed()
			let down = try await fixture.download(tiers: [["http://tracker.test/announce"]], tracker: tracker, clock: clock)
			try await down.run(id: "transfer", running: true)
			try await eventually { await tracker.requests.count == 1 }
			await tracker.setPeer(try TrackerPeer(address: "127.0.0.1", port: seed.snapshot().network.port))
			if rebind { var settings = SessionPeerSettings(); settings.utp = false; _ = try await down.configurePeers(settings) }
			else { try await down.setBlocklist([]) }
			// No clock advance: the restarted announce must connect immediately.
			try await eventually { try await down.snapshot().transfers[0].state.transfer?.complete == true }
			try await down.pause(id: "transfer")
			#expect(await tracker.requests.compactMap { $0.1.event } == [.started, .stopped, .started, .completed, .stopped])
		} catch { await fixture.close(); throw error }; await fixture.close()
	}
	@Test(arguments: [true, false]) func pauseDrainsActiveAnnouncesAndBoundsStoppedRequests(_ blockStart: Bool) async throws {
		let fixture = try TrackerSessionFixture(), clock = EngineClock(), tracker = BlockingSessionTracker(blockStart: blockStart)
		do {
			let down = try await fixture.download(tiers: [["http://tracker.test/announce"]], tracker: tracker, clock: clock)
			try await down.run(id: "transfer", running: true)
			try await eventually { await tracker.started }
			let pause = Task { try await down.pause(id: "transfer") }
			defer { pause.cancel() }
			if !blockStart {
				try await eventually { await tracker.stopping }
				while try await clock.nextSleep() != 3 { }
				clock.advance(3)
			}
			try await engineDeadline { try await pause.value }
			#expect(await tracker.cancelled)
			let snapshot = try await down.snapshot()
			#expect(!snapshot.transfers[0].state.running)
			if !blockStart { #expect(!snapshot.transfers[0].trackers[0].message.isEmpty) }
		} catch { await fixture.close(); throw error }; await fixture.close()
	}
	@Test func trackerPeersStartPrivateTransfersAndLifecycleUsesVerifiedCounters() async throws {
		let fixture = try TrackerSessionFixture(), tracker = RecordingTracker(), clock = EngineClock()
		do {
			let seed = try await fixture.seed(), port = try await seed.snapshot().network.port
			await tracker.setPeer(try TrackerPeer(address: "127.0.0.1", port: port))
			let down = try await fixture.download(tiers: [["http://broken.test/announce"], ["https://tracker.test/announce"]], tracker: tracker, clock: clock)
			try await down.run(id: "transfer", running: true)
			try await eventually { try await down.snapshot().transfers[0].state.transfer?.complete == true }
			clock.advance(1)
			try await eventually { await tracker.requests.contains { $0.0.host == "tracker.test" && $0.1.event == .completed } }
			for _ in 0..<5 { try await down.run(id: "transfer", running: true) }
			let snapshot = try await down.snapshot(), good = await tracker.requests.filter { $0.0.host == "tracker.test" }
			#expect(good.first?.1.peerID == down.peerID && good.first?.1.port == snapshot.network.port)
			#expect(good.first?.1.counters.left == Int64(fixture.source.bytes.count) && good.last?.1.counters.left == 0)
			#expect(snapshot.transfers[0].metadata.inspection.private && snapshot.transfers[0].trackers[0].message.contains("fixture failure"))
			try await down.pause(id: "transfer")
			let events = await tracker.requests.filter { $0.0.host == "tracker.test" }.compactMap { $0.1.event }
			#expect(events == [.started, .completed, .stopped])
			#expect(await tracker.requests.last?.1.wantedPeers == 0)
		} catch { await fixture.close(); throw error }; await fixture.close()
	}
	@Test func selectiveCompletionDoesNotAnnounceACompleteTorrent() async throws {
		let fixture = try TrackerSessionFixture(), tracker = RecordingTracker(), clock = EngineClock()
		do {
			let seed = try await fixture.seed(); await tracker.setPeer(try TrackerPeer(address: "127.0.0.1", port: seed.snapshot().network.port))
			let down = try await fixture.download(tiers: [["http://tracker.test/announce"]], tracker: tracker, clock: clock, selected: [true, false, false, false])
			try await down.run(id: "transfer", running: true)
			try await eventually { try await down.snapshot().transfers[0].state.transfer?.complete == true }
			clock.advance(31)
			try await eventually { await tracker.requests.count >= 2 }
			try await down.pause(id: "transfer")
			let requests = await tracker.requests.map(\.1)
			#expect(!requests.contains { $0.event == .completed })
			#expect(requests.last?.counters.left == Int64(fixture.source.bytes.count - 32768))
		} catch { await fixture.close(); throw error }; await fixture.close()
	}
	@Test func UDPTrackersUseTheOwnedListeningPortAndSessionPeerIdentity() async throws {
		let fixture = try TrackerSessionFixture(), socket = try DatagramSocket(bind: NetworkEndpoint("127.0.0.1", port: 0))
		let tracker = LocalUDPTracker(socket: socket); await tracker.start()
		do {
			let seed = try await fixture.seed(); await tracker.setPeer(try NetworkEndpoint("127.0.0.1", port: seed.snapshot().network.port))
			let down = try await fixture.download(tiers: [["udp://127.0.0.1:\(socket.localEndpoint.port)/announce"]], tracker: RecordingTracker(), clock: ContinuousTransportClock())
			try await down.run(id: "transfer", running: true)
			try await eventually { try await down.snapshot().transfers[0].state.transfer?.complete == true }
			let port = try await down.snapshot().network.port
			try await down.pause(id: "transfer") // Completion is flushed before the stopped event.
			let requests = await tracker.requests
			#expect(requests.map(\.event) == [2, 1, 3])
			#expect(requests.allSatisfy { $0.source.port == port && $0.port == port && $0.peerID == down.peerID })
			#expect(await tracker.failure == nil)
		} catch { await tracker.close(); await fixture.close(); throw error }; await tracker.close(); await fixture.close()
	}
	@Test func restartResetsAnnouncedCountersWithoutLosingPersistentTotals() async throws {
		let fixture = try TrackerSessionFixture(), tracker = RecordingTracker(), clock = ContinuousTransportClock()
		do {
			let seed = try await fixture.seed(); await tracker.setPeer(try TrackerPeer(address: "127.0.0.1", port: seed.snapshot().network.port))
			let down = try await fixture.download(tiers: [["http://tracker.test/announce"]], tracker: tracker, clock: clock)
			try await down.run(id: "transfer", running: true)
			try await eventually { try await down.snapshot().transfers[0].state.transfer?.complete == true }
			try await down.pause(id: "transfer"); try await down.run(id: "transfer", running: true)
			try await eventually { await tracker.requests.filter { $0.1.event == .started }.count == 2 }
			#expect(await tracker.requests.last?.1.counters.downloaded == Int64(fixture.source.bytes.count))
			try await down.close()
			let restoredTracker = RecordingTracker()
			let restored = try await fixture.download(tiers: [["http://tracker.test/announce"]], tracker: restoredTracker, clock: clock, restore: true)
			try await restored.run(id: "transfer", running: true)
			try await eventually { await restoredTracker.requests.count == 1 }
			let recorded = await restoredTracker.requests, request = recorded[0].1
			#expect(request.event == .started && request.counters.downloaded == 0 && request.counters.left == 0)
			#expect(try await restored.snapshot().transfers[0].state.storage.downloaded == Int64(fixture.source.bytes.count))
			try await restored.pause(id: "transfer")
			#expect(await restoredTracker.requests.compactMap { $0.1.event } == [.started, .stopped])
		} catch { await fixture.close(); throw error }; await fixture.close()
	}
}

}

private actor BlockingSessionTracker: TrackerAnnouncing {
	let blockStart: Bool
	var started = false
	var stopping = false
	var cancelled = false
	init(blockStart: Bool) { self.blockStart = blockStart }
	func announce(to url: URL, request: TrackerRequest) async throws -> TrackerResponse {
		started = true; if request.event == .stopped { stopping = true }
		if (blockStart && request.event == .started) || (!blockStart && request.event == .stopped) {
			do { try await Task.sleep(for: .seconds(60)) } catch { cancelled = true; throw error }
		}
		return try TrackerResponse(BencodeValue.dictionary([Data("interval".utf8): .integer(30), Data("peers".utf8): .bytes(Data())]).encoded())
	}
}

private actor RecordingTracker: TrackerAnnouncing {
	var requests: [(URL, TrackerRequest)] = []
	var peer: TrackerPeer?
	func setPeer(_ peer: TrackerPeer) { self.peer = peer }
	func announce(to url: URL, request: TrackerRequest) throws -> TrackerResponse {
		requests.append((url, request))
		if url.host == "broken.test" { throw HTTPServiceError.trackerFailure("fixture failure") }
		let peers = peer.map { [BencodeValue.dictionary([Data("ip".utf8): .bytes(Data($0.address.utf8)), Data("port".utf8): .integer(Int64($0.port))])] } ?? []
		return try TrackerResponse(BencodeValue.dictionary([Data("interval".utf8): .integer(30), Data("peers".utf8): .list(peers)]).encoded())
	}
}

private actor SwitchingSessionTracker: TrackerAnnouncing {
	let old: TrackerPeer
	let new: TrackerPeer
	var hosts: [String] = []
	var oldPeersWereDrained = false
	var initialStarted = false
	private var initialFailure: Bool
	private var failing = false
	private var check: (@Sendable () async throws -> Bool)?
	init(old: TrackerPeer, new: TrackerPeer, initialFailure: Bool) { self.old = old; self.new = new; self.initialFailure = initialFailure }
	func releaseInitialFailure() { initialFailure = false }
	func failPrimary(_ failure: Bool) { failing = failure }
	func checkBeforeReplacement(_ check: @escaping @Sendable () async throws -> Bool) { self.check = check }
	func announce(to url: URL, request: TrackerRequest) async throws -> TrackerResponse {
		let host = url.host!; hosts.append(host)
		if host == "old.test", initialFailure {
			initialStarted = true
			while initialFailure { try await Task.sleep(for: .milliseconds(5)) }
			throw HTTPServiceError.status(503)
		}
		if host == "old.test", failing { throw HTTPServiceError.status(503) }
		if host == "new.test", !oldPeersWereDrained { oldPeersWereDrained = try await check?() == true }
		let peer = host == "old.test" ? old : new
		let entry = BencodeValue.dictionary([Data("ip".utf8): .bytes(Data(peer.address.utf8)), Data("port".utf8): .integer(Int64(peer.port))])
		return try TrackerResponse(BencodeValue.dictionary([Data("interval".utf8): .integer(30), Data("peers".utf8): .list([entry])]).encoded())
	}
}

private final class TrackerSessionFixture {
	let source: TransferFixture
	let metadata: TorrentMetadata
	private var sessions: [TorrentSession] = []
	init() throws {
		source = try TransferFixture()
		var info = source.metadata.document.root["info"]!.dictionary!; info[Data("private".utf8)] = .integer(1)
		metadata = try TorrentMetadata(BencodeValue.dictionary([Data("info".utf8): .dictionary(info)]).encoded())
	}
	func seed(empty: Bool = false) async throws -> TorrentSession {
		let session = TorrentSession(storage: source.root.appendingPathComponent(empty ? "empty-seed-library" : "seed-library"), configuration: plainTransferConfiguration(), loopbackOnly: true); sessions.append(session)
		var settings = SessionPeerSettings(); settings.utp = false
		_ = try await session.configurePeers(settings)
		let input = source.root.appendingPathComponent("seed.torrent"); try metadata.document.original.write(to: input)
		_ = try await session.add(id: "transfer", source: input, destination: source.root.appendingPathComponent(empty ? "empty-seed" : "source"), selected: empty ? metadata.inspection.files.map { _ in false } : nil); try await session.run(id: "transfer", running: true); return session
	}
	func download(tiers: [[String]], tracker: any TrackerAnnouncing, clock: any TransportClock, selected: [Bool]? = nil, restore: Bool = false) async throws -> TorrentSession {
		let session = TorrentSession(storage: source.root.appendingPathComponent("down-library"), configuration: plainTransferConfiguration(), loopbackOnly: true, clock: clock, httpTracker: tracker); sessions.append(session)
		let input = source.root.appendingPathComponent("down.torrent"); try metadata.withTrackerTiers(tiers).write(to: input)
		_ = try await session.add(id: "transfer", source: input, destination: source.root.appendingPathComponent("download"), restore: restore, selected: selected); return session
	}
	func close() async { for session in sessions { try? await session.close() }; await source.clean() }
}

private actor LocalUDPTracker {
	struct Request: Sendable { let source: NetworkEndpoint; let peerID: Data; let port: UInt16; let event: UInt32; let downloaded: Int64; let left: Int64 }
	let socket: DatagramSocket
	var peer: NetworkEndpoint?
	var requests: [Request] = []
	var failure: String?
	var pump: Task<Void, Never>?
	init(socket: DatagramSocket) { self.socket = socket }
	func setPeer(_ peer: NetworkEndpoint) { self.peer = peer }
	func start() {
		pump = Task { [weak self, socket] in for await packet in socket.datagrams { await self?.receive(packet) } }
	}
	func receive(_ packet: NetworkDatagram) async {
		do {
			let action = try PacketBytes.uint32(packet.payload, at: 8), id = try PacketBytes.uint32(packet.payload, at: 12)
			var response = Data(); PacketBytes.append(action, to: &response); PacketBytes.append(id, to: &response)
			if action == 0 { PacketBytes.append(UInt64(123), to: &response) }
			else {
				guard packet.payload.count >= 98, action == 1 else { throw NetworkFailure.invalid("fixture announce") }
				requests.append(Request(source: packet.source, peerID: packet.payload.subdata(in: 36..<56), port: try PacketBytes.uint16(packet.payload, at: 96), event: try PacketBytes.uint32(packet.payload, at: 80), downloaded: Int64(bitPattern: try PacketBytes.uint64(packet.payload, at: 56)), left: Int64(bitPattern: try PacketBytes.uint64(packet.payload, at: 64))))
				for value in [UInt32(30), 0, 1] { PacketBytes.append(value, to: &response) }
				if let peer { response.append(peer.address.bytes); PacketBytes.append(peer.port, to: &response) }
			}
			try await socket.send(response, to: packet.source)
		} catch { failure = error.localizedDescription }
	}
	func close() async { pump?.cancel(); try? await socket.shutdown(); await pump?.value; pump = nil }
}
