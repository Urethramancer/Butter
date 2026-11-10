import Foundation
import Testing
@testable import ButterTorrentNetworking

@Suite struct UTPStateTests {
	@Test func reorderedWindowAnnouncementsCannotUndoANewerUpdateAcrossTimestampWrap() throws {
		var state = UTPState(outgoing: true, id: 7, sequence: 1, now: 0)
		let zero = UTPPacket(type: .state, connection: 7, timestamp: 0xfffffff0, window: 0, sequence: 20, acknowledgement: 1)
		try state.receive(zero, capacity: 262144, now: 0.01)
		#expect(state.remoteWindow == 0)
		try state.receive(UTPPacket(type: .state, connection: 7, timestamp: 0x10, window: 4096, sequence: 20, acknowledgement: 1), capacity: 262144, now: 0.02)
		try state.receive(zero, capacity: 262144, now: 0.03)
		#expect(state.remoteWindow == 4096)
	}
	@Test func selectiveACKTriggersFastRetransmissionAndFINWaitsForMissingData() throws {
		var sender = UTPState(outgoing: true, id: 7, sequence: 1, now: 0)
		let syn = sender.initial(window: 262144, now: 0)
		var receiver = UTPState(outgoing: false, id: 7, sequence: 30, syn: syn, now: 0)
		try sender.receive(receiver.initial(window: 262144, now: 0), capacity: 262144, now: 0.01)
		sender.congestion.window = 5900; var offset = 0
		let data = sender.send(Data(repeating: 7, count: 5900), offset: &offset, window: 262144, now: 0.02)
		for packet in data.dropFirst() { try receiver.receive(packet, capacity: 262144, now: 0.03) }
		let replies = try receiver.poll(window: 262144, pendingWrite: false, now: 0.04)
		for reply in replies { try sender.receive(reply, capacity: 262144, now: 0.05) }
		let beforeLoss = sender.congestion.window
		let retries = try sender.poll(window: 262144, pendingWrite: false, now: 0.06)
		#expect(retries.count == 1 && retries[0].sequence == data[0].sequence && retries[0].payload == data[0].payload)
		#expect(sender.congestion.window == beforeLoss / 2 && sender.retransmissions == 1)
		var earlyFIN = UTPState(outgoing: false, id: 7, sequence: 40, syn: syn, now: 0)
		try earlyFIN.receive(UTPPacket(type: .fin, connection: 8, sequence: 3, acknowledgement: 39), capacity: 1000, now: 0.1)
		#expect(!earlyFIN.eof && earlyFIN.received == 1)
		try earlyFIN.receive(UTPPacket(type: .data, connection: 8, sequence: 2, acknowledgement: 39, payload: Data([1, 2])), capacity: 1000, now: 0.2)
		#expect(earlyFIN.received == 3 && earlyFIN.ready == Data([1, 2]) && !earlyFIN.eof)
		earlyFIN.ready.removeAll(); #expect(earlyFIN.eof)
	}
	@Test func headerVectorAndExtensionBounds() throws {
		let bytes = Data([0x21, 0, 0x12, 0x34, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0x10, 0, 0xff, 0xff, 0, 0])
		let packet = try UTPPacket(bytes)
		#expect(packet.type == .state && packet.connection == 0x1234 && packet.timestamp == 1 && packet.difference == 2 && packet.window == 4096 && packet.sequence == 65535 && packet.acknowledgement == 0)
		#expect(try packet.encoded() == bytes)
		var unknown = bytes; unknown[1] = 99; unknown.append(contentsOf: [0, 3, 1, 2, 3])
		#expect(try UTPPacket(unknown).payload.isEmpty)
		for suffix in [Data([0, 3, 1, 2, 3]), Data([0, 4, 1]), Data([1, 4, 0, 0, 0, 0, 0, 4, 0, 0, 0, 0])] {
			var malformed = bytes; malformed[1] = 1; malformed.append(suffix)
			#expect(throws: (any Error).self) { try UTPPacket(malformed) }
		}
		#expect(utpBefore(65535, 0) && utpDistance(0, 65535) == 1 && !utpBefore(0, 65535))
	}
	@Test func wraparoundReorderingSelectiveACKAndFIN() throws {
		var client = UTPState(outgoing: true, id: 100, sequence: 65534, now: 0)
		let syn = client.initial(window: 262144, now: 0)
		var server = UTPState(outgoing: false, id: 100, sequence: 65535, syn: syn, now: 0)
		try client.receive(server.initial(window: 262144, now: 0.01), capacity: 262144, now: 0.02)
		#expect(client.phase == .connected && client.flights.isEmpty)
		let bytes = Data((0..<2360).map { UInt8($0 % 251) }); var offset = 0
		let packets = client.send(bytes, offset: &offset, window: 262144, now: 0.03)
		#expect(packets.map(\.sequence) == [65535, 0] && offset == bytes.count)
		try server.receive(packets[1], capacity: 262144, now: 0.04)
		let selective = try #require(server.poll(window: 262144, pendingWrite: false, now: 0.04).first)
		#expect(selective.acknowledgement == 65534 && selective.selective[0] & 1 != 0 && server.ready.isEmpty)
		try client.receive(selective, capacity: 262144, now: 0.05)
		#expect(client.flights.map(\.sequence) == [65535])
		try server.receive(packets[0], capacity: 262144, now: 0.06)
		try server.receive(packets[0], capacity: 262144, now: 0.07) // Duplicate must not duplicate application bytes.
		#expect(server.ready == bytes && server.received == 0)
		for ack in try server.poll(window: 262144, pendingWrite: false, now: 0.08) { try client.receive(ack, capacity: 262144, now: 0.09) }
		#expect(client.flights.isEmpty)
		let finishing = client.finish(window: 262144, now: 0.1), fin = try #require(finishing); #expect(fin.sequence == 1)
		try server.receive(fin, capacity: 262144, now: 0.11)
		#expect(!server.eof); server.ready.removeAll(); #expect(server.eof)
		for ack in try server.poll(window: 262144, pendingWrite: false, now: 0.12) { try client.receive(ack, capacity: 262144, now: 0.13) }
		#expect(client.finAcknowledged)
	}
	@Test func retransmissionDeadlineFlowControlAndFutureACK() throws {
		var state = UTPState(outgoing: true, id: 7, sequence: 1, now: 0)
		#expect(try state.poll(window: 1000, pendingWrite: false, now: 0.9).isEmpty)
		let retry = try state.poll(window: 1000, pendingWrite: false, now: 1)
		#expect(retry.count == 1 && retry[0].type == .syn && retry[0].sequence == 1 && state.retransmissions == 1)
		try state.receive(UTPPacket(type: .state, connection: 7, window: 0, sequence: 20, acknowledgement: 1), capacity: 1000, now: 1.1)
		var offset = 0
		let blocked = state.send(Data(repeating: 1, count: 200), offset: &offset, window: 1000, now: 1.2)
		#expect(blocked.isEmpty && offset == 0)
		#expect(try state.poll(window: 1000, pendingWrite: true, now: 2).first?.sequence == state.next &- 1)
		try state.receive(UTPPacket(type: .state, connection: 7, window: 200, sequence: 20, acknowledgement: 1), capacity: 1000, now: 2.1)
		_ = state.send(Data(repeating: 1, count: 200), offset: &offset, window: 1000, now: 2.2)
		let pending = state.flights.map(\.sequence)
		try state.receive(UTPPacket(type: .state, connection: 7, sequence: 20, acknowledgement: state.next &+ 10), capacity: 1000, now: 2.3)
		#expect(state.flights.map(\.sequence) == pending)
	}
	@Test func congestionYieldsToDelayAndLossAndBoundsRTO() {
		var control = UTPCongestion()
		control.sampleRTT(0.01); #expect(control.timeout == 0.5)
		for index in 0..<5 { control.acknowledged(bytes: 1180, delay: 10_000, now: Double(index)) }
		let growing = control.window; #expect(growing > 2360)
		for index in 5..<10 { control.acknowledged(bytes: 1180, delay: 510_000, now: Double(index)) }
		#expect(control.window < growing)
		control.lost(now: 20, timedOut: false); #expect(control.window >= 130)
		control.lost(now: 21, timedOut: true); #expect(control.window == 130 && control.packetSize == 130 && control.retransmitAfter >= 1)
	}
}
