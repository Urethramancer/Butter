import Foundation
import Testing
import ButterTorrentMetadata
import ButterTorrentStorage
@testable import ButterTorrentEngine

@Suite struct PeerWireTests {
	@Test func fragmentedHandshakeAndCoalescedFrames() throws {
		let hello = try PeerHandshake(infoHash: Data(repeating: 42, count: 20), peerID: Data(repeating: 7, count: 20))
		let block = PeerBlock(piece: 2, offset: 16384, length: 100)
		let messages: [PeerMessage] = [.keepAlive, .choke, .unchoke, .interested, .notInterested, .have(7), .bitfield(Data([128])), .request(block), .cancel(block), .piece(2, 16384, Data(repeating: 255, count: 100))]
		var parser = PeerWireDecoder()
		for byte in hello.encoded.dropLast() { try parser.feed(Data([byte])); #expect(try parser.handshake() == nil) }
		try parser.feed(Data([hello.encoded.last!])); #expect(try parser.handshake() == hello)
		let wire = try messages.reduce(into: Data()) { $0.append(try $1.encoded()) }
		var decoded: [PeerMessage] = []
		for byte in wire { try parser.feed(Data([byte])); while let message = try parser.next() { decoded.append(message) } }
		#expect(decoded == messages); try parser.finish()
	}
	@Test(arguments: [Data([0, 1, 0, 1]), Data([0, 0, 0, 2, 0, 0]), Data([0, 0, 0, 1, 20]), Data([0, 0, 0, 1, 7])])
	func rejectsMalformedAndUnnegotiatedFrames(_ data: Data) throws {
		var parser = PeerWireDecoder()
		try parser.feed(PeerHandshake(infoHash: Data(repeating: 0, count: 20), peerID: Data(repeating: 1, count: 20)).encoded)
		_ = try parser.handshake(); try parser.feed(data)
		#expect(throws: PeerFailure.self) { try parser.next() }
	}
	@Test func bitfieldSpareBitsAndTruncatedStream() throws {
		#expect(throws: PeerFailure.self) { try PieceBitfield(count: 9, bytes: Data([0, 1])) }
		#expect(throws: PeerFailure.self) { try PieceBitfield(count: 9, bytes: Data([0])) }
		var parser = PeerWireDecoder(); try parser.feed(Data([19]))
		#expect(throws: PeerFailure.self) { try parser.finish() }
	}
}

func pickerLayout(pieces: Int = 3, pieceLength: Int64 = 32768) throws -> StorageLayout {
	let fields: [Data: BencodeValue] = [Data("name".utf8): .bytes(Data("fixture".utf8)), Data("length".utf8): .integer(Int64(pieces) * pieceLength), Data("piece length".utf8): .integer(pieceLength), Data("pieces".utf8): .bytes(Data(repeating: 42, count: pieces * 20))]
	return try StorageLayout(metadata: TorrentMetadata(BencodeValue.dictionary([Data("info".utf8): .dictionary(fields)]).encoded()))
}

@Suite struct PiecePickerTests {
	@Test func rarestFirstPipelinesDisconnectAndCorruptionReset() throws {
		let layout = try pickerLayout(), a = UUID(), b = UUID()
		var picker = PiecePicker(layout: layout, wanted: [0, 1, 2], completed: [], maximumActive: 1)
		picker.update(a, bits: try PieceBitfield(count: 3, pieces: [0, 1, 2])); picker.update(b, bits: try PieceBitfield(count: 3, pieces: [0, 1]))
		let requests = picker.allocate(a, limit: 2, now: 0)
		#expect(requests.map(\.piece) == [2, 2])
		picker.update(b, bits: try PieceBitfield(count: 3, pieces: [0, 1, 2])); picker.remove(a)
		let recovered = picker.allocate(b, limit: 2, now: 1)
		#expect(recovered == requests)
		for block in recovered { #expect(picker.begin(b, block: block) != nil); _ = picker.written(block) }
		#expect(picker.verified(2, valid: false) == [b]); #expect(!picker.complete)
		#expect(picker.allocate(b, limit: 1, now: 2).first?.piece == 0)
	}
	@Test func endgameCancelsOtherOwnersAndExpiresRequests() throws {
		let layout = try pickerLayout(pieces: 1), a = UUID(), b = UUID()
		var picker = PiecePicker(layout: layout, wanted: [0], completed: [])
		for peer in [a, b] { picker.update(peer, bits: try PieceBitfield(count: 1, pieces: [0])) }
		let first = picker.allocate(a, limit: 2, now: 0), second = picker.allocate(b, limit: 2, now: 1)
		#expect(first == second)
		#expect(picker.begin(a, block: first[0]) == [b]); let partial = picker.written(first[0]); #expect(!partial)
		#expect(picker.expired(now: 40, timeout: 30).count == 2)
		let retry = picker.allocate(b, limit: 2, now: 41)
		#expect(retry == [first[1]])
		#expect(picker.begin(b, block: retry[0]) != nil); let ready = picker.written(retry[0]); #expect(ready)
		_ = picker.verified(0, valid: true); #expect(picker.complete)
	}
}
