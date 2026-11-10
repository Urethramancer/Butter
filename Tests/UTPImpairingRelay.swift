import Foundation
import ButterTorrentNetworking

// A disposable loopback-only UDP proxy. Faults affect each original packet at most once.
actor UTPImpairingRelay {
	nonisolated let port: UInt16
	private let front: DatagramSocket, back: DatagramSocket
	private let target: NetworkEndpoint
	private let loseSYN: Bool
	private let loseSYNACK: Bool
	private var client: NetworkEndpoint?
	private var pumps: [Task<Void, Never>] = []
	private var delayed: [Bool: (Data, NetworkEndpoint)] = [:]
	private var timers: [Bool: Task<Void, Never>] = [:]
	private var seen: Set<Data> = []
	private var droppedSYN: Set<Bool> = []
	private var droppedSYNACK = false
	private var counts: [Bool: Int] = [:]
	private var closed = false
	private(set) var dropped = 0, duplicated = 0, reordered = 0
	private var received: [Bool: Int] = [:]
	private var syns: [String] = []
	private var sendError: String?
	func diagnostics() -> String { "UDP proxy received=\(received) dropped=\(dropped) duplicated=\(duplicated) reordered=\(reordered) SYN=\(syns) error=\(sendError ?? "none")" }
	private init(front: DatagramSocket, back: DatagramSocket, target: NetworkEndpoint, loseSYN: Bool, loseSYNACK: Bool) {
		self.front = front; self.back = back; self.target = target; self.loseSYN = loseSYN; self.loseSYNACK = loseSYNACK; port = front.localEndpoint.port
	}
	static func open(host: String, target: NetworkEndpoint, loseSYN: Bool = true, loseSYNACK: Bool = false) async throws -> UTPImpairingRelay {
		guard target.address.isLoopback else { throw NetworkFailure.invalid("fixture target must be loopback") }
		let front = try DatagramSocket(bind: NetworkEndpoint(host, port: 0)), back = try DatagramSocket(bind: NetworkEndpoint(host, port: 0))
		let relay = UTPImpairingRelay(front: front, back: back, target: target, loseSYN: loseSYN, loseSYNACK: loseSYNACK); await relay.start(); return relay
	}
	private func start() {
		for (direction, socket) in [(true, front), (false, back)] {
			pumps.append(Task { [weak self] in for await packet in socket.datagrams { if Task.isCancelled { break }; await self?.forward(packet, outgoing: direction) } })
		}
	}
	private func forward(_ packet: NetworkDatagram, outgoing: Bool) async {
		guard !closed, (20...4096).contains(packet.payload.count), packet.payload[0] & 15 == 1 else { return }
		let type = packet.payload[0] >> 4
		received[outgoing, default: 0] += 1
		if outgoing {
			if client == nil { guard type == 4, packet.source.address.isLoopback else { return }; client = packet.source }
			guard client == packet.source else { return }
		} else { guard packet.source == target else { return } }
		guard let destination = outgoing ? target : client else { return }
		var identity = Data([outgoing ? 1 : 0, type]); identity.append(packet.payload.subdata(in: 2..<4)); identity.append(packet.payload.subdata(in: 16..<18))
		let original = seen.insert(identity).inserted
		if type == 4, syns.count < 8 { syns.append("\(outgoing ? "front" : "back") \(packet.payload.prefix(20).map { String(format: "%02x", $0) }.joined()) original=\(original)") }
		if loseSYN, original, type == 4, droppedSYN.insert(outgoing).inserted { dropped += 1; return }
		if loseSYNACK, type == 2, !outgoing, !droppedSYNACK { droppedSYNACK = true; dropped += 1; return }
		if original, type == 0 {
			counts[outgoing, default: 0] += 1; let count = counts[outgoing]!
			if count == 3 || count == 19 { dropped += 1; return }
			if count % 7 == 0, delayed[outgoing] == nil {
				delayed[outgoing] = (packet.payload, destination)
				timers[outgoing] = Task { [weak self] in do { try await Task.sleep(for: .milliseconds(20)); await self?.flush(outgoing, fromTimer: true) } catch {} }; return
			}
			if count % 5 == 0 { duplicated += 1; try? await send(packet.payload, destination: destination, outgoing: outgoing) }
		}
		try? await send(packet.payload, destination: destination, outgoing: outgoing)
		if delayed[outgoing] != nil { reordered += 1; await flush(outgoing) }
	}
	private func send(_ bytes: Data, destination: NetworkEndpoint, outgoing: Bool) async throws {
		guard !closed else { return }
		do { try await (outgoing ? back : front).send(bytes, to: destination) } catch { sendError = String(describing: error); throw error }
	}
	private func flush(_ outgoing: Bool, fromTimer: Bool = false) async {
		guard let packet = delayed.removeValue(forKey: outgoing) else { return }
		let timer = timers.removeValue(forKey: outgoing); if !fromTimer { timer?.cancel() }
		try? await send(packet.0, destination: packet.1, outgoing: outgoing)
	}
	func close() async {
		closed = true; for timer in timers.values { timer.cancel() }; timers.removeAll(); delayed.removeAll()
		for task in pumps { task.cancel() }; try? await front.shutdown(); try? await back.shutdown()
		for task in pumps { await task.value }; pumps.removeAll()
	}
}
