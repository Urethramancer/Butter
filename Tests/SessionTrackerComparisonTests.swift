import Foundation
import Darwin
import ButterTorrentMetadata
@testable import ButterTorrentNetworking
import ButterTorrentEngine

extension TCPTransferComparisonTests {
	static func runTrackerComparisons(root: URL, binary: URL) async throws {
		var cases = 0
		for udp in [false, true] { for legacy in [false, true] { for utp in [false, true] { for nativeSeed in [false, true] { for magnetDownload in [false, true] {
			let label = "tracker-hybrid-\(legacy ? "v1-only" : "both")-\(udp ? "udp" : "http")-\(utp ? "utp" : "tcp")-\(nativeSeed ? "up" : "down")\(magnetDownload ? "-magnet" : "")"
			if let filter = ProcessInfo.processInfo.environment["BUTTER_TRACKER_FILTER"], !label.contains(filter) { continue }
			let work = root.appendingPathComponent(label); try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
			let original = try TorrentMetadata(contentsOf: root.appendingPathComponent("single-16384-hybrid.torrent"))
			var fields = original.document.root.dictionary!, info = original.document.root["info"]!.dictionary!
			if !magnetDownload { info[Data("private".utf8)] = .integer(1) }
			fields[Data("info".utf8)] = .dictionary(info)
			let metadata = try TorrentMetadata(BencodeValue.dictionary(fields).encoded())
			let hashes = [metadata.hashes.v1!, Data(metadata.hashes.v2!.prefix(20))], rejected = legacy ? hashes[1] : nil
			let tracker = try await ComparisonTracker.open(udp: udp, hashes: hashes, rejected: rejected)
			let source = work.appendingPathComponent("registered.torrent"); try metadata.withTrackerTiers([[tracker.url.absoluteString]]).write(to: source)
			var configuration = TCPTransferConfiguration(); configuration.encryption = .disabled
			let session = TorrentSession(storage: work.appendingPathComponent("library"), configuration: configuration, loopbackOnly: true)
			let record = work.appendingPathComponent("status.json"), jobURL = work.appendingPathComponent("job.json")
			let process = Process(); process.executableURL = binary; process.arguments = ["--run", jobURL.path]
			do {
				var settings = SessionPeerSettings(); settings.tcp = !utp; settings.utp = utp; settings.pex = false; settings.allowSameIP = true
				let nativePort = try await session.configurePeers(settings)
				let magnet = Magnet(hashes: metadata.hashes, trackers: [tracker.url.absoluteString])
				var job: [String: Any] = ["torrent": source.path, "destination": nativeSeed ? work.appendingPathComponent("reference-download").path : root.appendingPathComponent("reference-seed").path,
					"listen": "127.0.0.1:0", "status": record.path, "remotePort": 0, "transport": utp ? "utp" : "tcp", "encryption": "disabled", "pex": false]
				if magnetDownload && nativeSeed { job["magnet"] = magnet.uri }
				try JSONSerialization.data(withJSONObject: job).write(to: jobURL)
				let accepted = hashes.filter { $0 != rejected }
				if !nativeSeed {
					try process.run()
					try await wait { guard let state = try status(record, process: process) else { return false }; return state.seeding && tracker.state.hasSeeds(hashes: accepted, port: state.port) }
				}
				let destination = nativeSeed ? root.appendingPathComponent("reference-seed") : work.appendingPathComponent("native-download")
				if magnetDownload && !nativeSeed {
					_ = try await session.add(id: "transfer", magnet: magnet, destination: destination)
				} else {
					_ = try await session.add(id: "transfer", source: source, destination: destination)
				}
				try await session.run(id: "transfer", running: true)
				if nativeSeed {
					try await wait { tracker.state.hasSeeds(hashes: accepted, port: nativePort) }
					try process.run()
				}
				let expected = metadata.inspection.files.filter { !$0.pad }.reduce(Int64(0)) { $0 + $1.size }
				try await wait {
					guard let reference = try status(record, process: process), let wire = try await session.snapshot().transfers.first?.state.transfer else { return false }
					return nativeSeed ? reference.complete && reference.downloaded == expected && wire.uploaded == expected : wire.complete && wire.downloaded - wire.corruptBytes - wire.redundantBytes == expected && reference.uploaded == expected
				}
				try await session.shutdown(); try await session.close(); try await stop(process)
				let calls = tracker.state.announces(peerID: session.peerID)
				guard Set(calls.map(\.hash)) == Set(hashes), calls.allSatisfy({ $0.port == nativePort }), tracker.state.failure == nil else { throw PeerFailure.invalid("tracker wire identity, ownership or fixture failure: \(tracker.state.failure ?? "")") }
				for hash in hashes {
					let identityCalls = calls.filter { $0.hash == hash }
					let events = identityCalls.map(\.event)
					if hash == rejected {
						guard !events.isEmpty, events.allSatisfy({ $0 == .started }) else { throw PeerFailure.invalid("rejected tracker identity acquired a lifecycle") }
					} else {
						var expectedEvents: [TrackerEvent?] = nativeSeed ? [.started, .stopped] : [.started, .completed, .stopped]
						if magnetDownload && !nativeSeed {
							expectedEvents.insert(contentsOf: [.started, .stopped], at: 0)
							guard identityCalls.prefix(2).allSatisfy({ $0.left == 16_384 }) else { throw PeerFailure.invalid("pending tracker left differs") }
						}
						guard events == expectedEvents else { throw PeerFailure.invalid("tracker lifecycle differs: \(events)") }
					}
				}
				let output = nativeSeed ? work.appendingPathComponent("reference-download") : destination
				for file in metadata.inspection.files where !file.pad {
					guard try Data(contentsOf: output.appendingPathComponent(file.path)) == Data(contentsOf: root.appendingPathComponent("reference-seed/" + file.path)) else { throw PeerFailure.invalid("tracker-discovered payload differs") }
				}
				await tracker.close(); cases += 1; print("PASS: \(label), peers discovered only through the tracker; identities, events and bytes verified")
			} catch {
				try? FileHandle.standardError.write(contentsOf: Data("FAIL: \(label): \(error); tracker=\(tracker.state.diagnostics)\n".utf8))
				if let bytes = try? Data(contentsOf: record) { try? FileHandle.standardError.write(contentsOf: bytes) }
				try? await session.close()
				if process.isRunning { process.terminate(); try? await stop(process); if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
				await tracker.close(); throw error
			}
		} } } } }
		if cases == 0 { throw PeerFailure.invalid("no tracker comparison matched") }
		print("PASS: \(cases) independent hybrid tracker comparisons in both directions")
	}
}

private actor ComparisonTracker {
	nonisolated let url: URL
	nonisolated let state: ComparisonTrackerState
	private let http: HTTPFixture?
	private let socket: DatagramSocket?
	private var pump: Task<Void, Never>?
	private var closed = false
	private init(url: URL, state: ComparisonTrackerState, http: HTTPFixture?, socket: DatagramSocket?) { self.url = url; self.state = state; self.http = http; self.socket = socket }
	static func open(udp: Bool, hashes: [Data], rejected: Data?) async throws -> ComparisonTracker {
		let state = ComparisonTrackerState(hashes: hashes, rejected: rejected)
		if udp {
			let socket = try DatagramSocket(bind: NetworkEndpoint("127.0.0.1", port: 0))
			let owner = ComparisonTracker(url: URL(string: "udp://127.0.0.1:\(socket.localEndpoint.port)/announce")!, state: state, http: nil, socket: socket)
			await owner.start(); return owner
		}
		let http = try await HTTPFixture.start { state.http($0) }
		return ComparisonTracker(url: http.url.appendingPathComponent("announce"), state: state, http: http, socket: nil)
	}
	private func start() {
		guard let socket else { return }; let state = state
		pump = Task {
			for await packet in socket.datagrams {
				do { try await socket.send(state.udp(packet.payload), to: packet.source) }
				catch is CancellationError { return }
				catch { state.fail(error) }
			}
		}
	}
	func close() async {
		guard !closed else { return }; closed = true; pump?.cancel()
		try? await socket?.shutdown(); await pump?.value; pump = nil; await http?.stop()
	}
}

private final class ComparisonTrackerState: @unchecked Sendable {
	struct Announce: Sendable { let hash: Data; let peerID: Data; let port: UInt16; let event: TrackerEvent?; let left: Int64 }
	private struct Reply { let peers: [UInt16]; let error: String? }
	private let lock = NSLock()
	private let hashes: Set<Data>, rejected: Data?
	private var calls: [Announce] = []
	private var seeds: [Data: [UInt16: Data]] = [:]
	private var error: String?
	init(hashes: [Data], rejected: Data?) { self.hashes = Set(hashes); self.rejected = rejected }
	var failure: String? { lock.withLock { error } }
	var diagnostics: String { lock.withLock { calls.map { "\($0.hash.prefix(4).map { String(format: "%02x", $0) }.joined()) port=\($0.port) \($0.event?.rawValue ?? "periodic") left=\($0.left)" }.joined(separator: "; ") + " error=\(error ?? "")" } }
	func fail(_ failure: Error) { lock.withLock { if error == nil { error = String(describing: failure) } } }
	func announces(peerID: Data) -> [Announce] { lock.withLock { calls.filter { $0.peerID == peerID } } }
	func hasSeeds(hashes: [Data], port: UInt16) -> Bool { lock.withLock { hashes.allSatisfy { seeds[$0]?[port] != nil } } }
	private func apply(_ call: Announce) throws -> Reply {
		try lock.withLock {
			guard hashes.contains(call.hash), call.peerID.count == 20, call.port > 0, call.left >= 0, calls.count < 256 else { throw PeerFailure.invalid("tracker fixture announce") }
			calls.append(call)
			if call.hash == rejected { return Reply(peers: [], error: "unregistered identifier") }
			if call.event == .stopped { if seeds[call.hash]?[call.port] == call.peerID { seeds[call.hash]?[call.port] = nil } }
			else if call.left == 0 { seeds[call.hash, default: [:]][call.port] = call.peerID }
			let peers = (seeds[call.hash] ?? [:]).filter { $0.key != call.port && $0.value != call.peerID }.map(\.key).sorted()
			return Reply(peers: peers, error: nil)
		}
	}
	func http(_ input: HTTPFixture.Input) -> HTTPFixture.Reply {
		do {
			guard input.method == "GET", input.target.hasPrefix("/announce?"), input.target.utf8.count <= 8192 else { throw PeerFailure.invalid("tracker HTTP request") }
			var fields: [String: Data] = [:]
			for part in input.target.dropFirst("/announce?".count).split(separator: "&") {
				let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
				guard pair.count == 2, fields[String(pair[0])] == nil else { throw PeerFailure.invalid("tracker query fields") }
				fields[String(pair[0])] = try Self.unescape(pair[1])
			}
			guard let hash = fields["info_hash"], let peerID = fields["peer_id"], let portText = fields["port"].flatMap({ String(data: $0, encoding: .ascii) }), let port = UInt16(portText),
				let leftText = fields["left"].flatMap({ String(data: $0, encoding: .ascii) }), let left = Int64(leftText) else { throw PeerFailure.invalid("tracker query values") }
			let event = fields["event"].flatMap { String(data: $0, encoding: .ascii) }.flatMap(TrackerEvent.init(rawValue:))
			let reply = try apply(Announce(hash: hash, peerID: peerID, port: port, event: event, left: left))
			if let error = reply.error { return .init(body: try bencode(["failure reason": .bytes(Data(error.utf8))])) }
			var peers = Data(); for port in reply.peers { peers.append(contentsOf: [127, 0, 0, 1, UInt8(port >> 8), UInt8(port & 255)]) }
			return .init(body: try bencode(["interval": .integer(30), "peers": .bytes(peers), "tracker id": .bytes(Data("comparison-tracker".utf8))]))
		} catch { fail(error); return .init(status: 400) }
	}
	func udp(_ bytes: Data) throws -> Data {
		guard bytes.count >= 16 else { throw PeerFailure.invalid("tracker UDP header") }
		let action = try PacketBytes.uint32(bytes, at: 8), id = try PacketBytes.uint32(bytes, at: 12)
		var response = Data(); PacketBytes.append(action, to: &response); PacketBytes.append(id, to: &response)
		if action == 0 {
			guard try PacketBytes.uint64(bytes, at: 0) == 0x41727101980 else { throw PeerFailure.invalid("tracker UDP protocol identifier") }
			PacketBytes.append(UInt64(0x102030405060708), to: &response); return response
		}
		guard action == 1, bytes.count >= 98 else { throw PeerFailure.invalid("tracker UDP announce") }
		guard try PacketBytes.uint64(bytes, at: 0) == 0x102030405060708 else { throw PeerFailure.invalid("tracker UDP connection identifier") }
		let eventValue = try PacketBytes.uint32(bytes, at: 80)
		let event: TrackerEvent? = eventValue == 1 ? .completed : eventValue == 2 ? .started : eventValue == 3 ? .stopped : nil
		let reply = try apply(Announce(hash: bytes.subdata(in: 16..<36), peerID: bytes.subdata(in: 36..<56), port: PacketBytes.uint16(bytes, at: 96), event: event, left: Int64(bitPattern: PacketBytes.uint64(bytes, at: 64))))
		if let error = reply.error {
			response = Data(); PacketBytes.append(UInt32(3), to: &response); PacketBytes.append(id, to: &response); response.append(Data(error.utf8)); return response
		}
		for value in [UInt32(30), 0, UInt32(reply.peers.count)] { PacketBytes.append(value, to: &response) }
		for port in reply.peers { response.append(contentsOf: [127, 0, 0, 1, UInt8(port >> 8), UInt8(port & 255)]) }
		return response
	}
	private static func unescape(_ text: Substring) throws -> Data {
		let bytes = Array(text.utf8); var decoded = Data(), offset = 0
		while offset < bytes.count {
			if bytes[offset] == 37 {
				guard offset + 2 < bytes.count, let value = UInt8(String(decoding: bytes[(offset + 1)...(offset + 2)], as: UTF8.self), radix: 16) else { throw PeerFailure.invalid("tracker query escape") }
				decoded.append(value); offset += 3
			} else { decoded.append(bytes[offset] == 43 ? 32 : bytes[offset]); offset += 1 }
		}
		return decoded
	}
}
