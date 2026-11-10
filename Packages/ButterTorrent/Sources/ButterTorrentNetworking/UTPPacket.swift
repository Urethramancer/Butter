import Foundation

enum UTPPacketType: UInt8, Sendable { case data = 0, fin = 1, state = 2, reset = 3, syn = 4 }

struct UTPPacket: Sendable {
	let type: UTPPacketType
	let connection: UInt16
	var timestamp: UInt32
	var difference: UInt32
	var window: UInt32
	let sequence: UInt16
	let acknowledgement: UInt16
	var selective = Data()
	var payload = Data()
	init(type: UTPPacketType, connection: UInt16, timestamp: UInt32 = 0, difference: UInt32 = 0, window: UInt32 = 262_144,
		sequence: UInt16, acknowledgement: UInt16, selective: Data = Data(), payload: Data = Data()) {
		self.type = type; self.connection = connection; self.timestamp = timestamp; self.difference = difference; self.window = window
		self.sequence = sequence; self.acknowledgement = acknowledgement; self.selective = selective; self.payload = payload
	}
	init(_ bytes: Data) throws {
		guard (20...4096).contains(bytes.count), bytes[0] & 15 == 1, let type = UTPPacketType(rawValue: bytes[0] >> 4) else { throw NetworkFailure.invalid("µTP header") }
		self.type = type; connection = try PacketBytes.uint16(bytes, at: 2); timestamp = try PacketBytes.uint32(bytes, at: 4)
		difference = try PacketBytes.uint32(bytes, at: 8); window = try PacketBytes.uint32(bytes, at: 12)
		sequence = try PacketBytes.uint16(bytes, at: 16); acknowledgement = try PacketBytes.uint16(bytes, at: 18)
		var next = bytes[1], cursor = 20, extensions = 0
		while next != 0 {
			extensions += 1
			guard extensions <= 8, cursor <= bytes.count - 2 else { throw NetworkFailure.invalid("µTP extension chain") }
			let kind = next, length = Int(bytes[cursor + 1]); next = bytes[cursor]; cursor += 2
			guard length <= bytes.count - cursor else { throw NetworkFailure.invalid("µTP extension length") }
			if kind == 1 {
				guard selective.isEmpty, length >= 4, length % 4 == 0, length <= 252 else { throw NetworkFailure.invalid("µTP selective acknowledgement") }
				selective = bytes.subdata(in: cursor..<cursor + length)
			}
			cursor += length
		}
		payload = bytes.subdata(in: cursor..<bytes.count)
		guard type == .data ? !payload.isEmpty : payload.isEmpty else { throw NetworkFailure.invalid("µTP packet payload") }
	}
	func encoded() throws -> Data {
		guard selective.isEmpty || (selective.count >= 4 && selective.count <= 252 && selective.count % 4 == 0),
			type == .data ? !payload.isEmpty : payload.isEmpty else { throw NetworkFailure.invalid("µTP packet fields") }
		var bytes = Data([type.rawValue << 4 | 1, selective.isEmpty ? 0 : 1]); PacketBytes.append(connection, to: &bytes)
		for word in [timestamp, difference, window] { PacketBytes.append(word, to: &bytes) }
		PacketBytes.append(sequence, to: &bytes); PacketBytes.append(acknowledgement, to: &bytes)
		if !selective.isEmpty { bytes.append(contentsOf: [0, UInt8(selective.count)]); bytes.append(selective) }
		bytes.append(payload); guard bytes.count <= 4096 else { throw NetworkFailure.limit("µTP datagram") }; return bytes
	}
}

func utpDistance(_ a: UInt16, _ b: UInt16) -> Int { Int(a &- b) }
func utpBefore(_ a: UInt16, _ b: UInt16) -> Bool { a != b && (a &- b) & 0x8000 != 0 }
func utpTimestamp(_ now: TimeInterval) -> UInt32 { UInt32(truncatingIfNeeded: UInt64(max(0, now) * 1_000_000)) }
