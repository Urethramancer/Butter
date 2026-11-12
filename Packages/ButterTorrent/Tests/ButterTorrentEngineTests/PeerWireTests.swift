import Foundation
import Testing
import ButterTorrentMetadata
import ButterTorrentStorage
@testable import ButterTorrentEngine

@Suite struct PeerWireTests {
	@Test(arguments: [1, 16384], [false, true]) func pieceEncodingPreservesExactHeaderAndSlicedPayload(_ count: Int, _ sliced: Bool) throws {
		let payload = sliced ? Data(repeating: 91, count: count + 17).suffix(count) : Data(repeating: 91, count: count)
		let wire = try PeerMessage.piece(0x01020304, 8192, payload).encoded(), size = count + 9
		#expect(Array(wire.prefix(13)) == [0, 0, UInt8(size >> 8), UInt8(size & 255), 7, 1, 2, 3, 4, 0, 0, 32, 0])
		#expect(wire.count == count + 13 && wire.suffix(count) == payload)
	}
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
	@Test func wantedCompletionTracksDuplicatesUnselectedPiecesAndStagedVerification() throws {
		let layout = try pickerLayout(pieces: 4), peer = UUID()
		var picker = PiecePicker(layout: layout, wanted: [0, 1, 2], completed: [0, 3])
		picker.update(peer, bits: try PieceBitfield(count: 4, pieces: [0, 1, 2, 3]))
		#expect(!picker.complete && picker.interested(peer))
		for piece in [1, 1, 3] { _ = picker.verified(piece, valid: true) }
		#expect(!picker.complete && picker.interested(peer))
		_ = picker.stage(2); #expect(!picker.complete && !picker.interested(peer))
		let rejected = picker.settleStaged(2, valid: false); #expect(rejected)
		#expect(!picker.complete && picker.interested(peer))
		_ = picker.verified(2, valid: false); #expect(!picker.complete)
		_ = picker.stage(2); let accepted = picker.settleStaged(2, valid: true); #expect(accepted)
		#expect(picker.complete && !picker.interested(peer))
		_ = picker.verified(2, valid: true); #expect(picker.complete)
		let repeated = picker.settleStaged(2, valid: true); #expect(!repeated); #expect(picker.complete)
		let empty = PiecePicker(layout: layout, wanted: [], completed: [3])
		#expect(empty.complete && !empty.interested(peer))
	}
	@Test(arguments: [1, 2, 8]) func boundedCandidatesPreserveGlobalOrderAcrossAvailabilityAndRestrictions(_ maximum: Int) throws {
		let count = 96, layout = try pickerLayout(pieces: count, pieceLength: 16384), peer = UUID(), other = UUID()
		let wanted = Set(0..<count), common = Set((0..<count).filter { $0 % 3 == 0 }), suggestions: Set<Int> = [19, 25, 31, 37, 55, 73, 85]
		let eligible = Set((0..<count).filter { $0 % 2 == 1 }), allowed = Set((0..<count).filter { $0 % 5 != 0 }), excluded: Set<Int> = [7, 19]
		var picker = PiecePicker(layout: layout, wanted: wanted, completed: [1], maximumActive: maximum)
		picker.update(peer, bits: try PieceBitfield(count: count, pieces: wanted)); picker.update(other, bits: try PieceBitfield(count: count, pieces: common))
		let expected = wanted.filter { $0 != 1 && eligible.contains($0) && allowed.contains($0) && !excluded.contains($0) }.sorted {
			if common.contains($0) != common.contains($1) { return !common.contains($0) }
			if suggestions.contains($0) != suggestions.contains($1) { return suggestions.contains($0) }; return $0 < $1
		}
		var received: [Int] = []
		while !picker.complete {
			let blocks = picker.allocate(peer, limit: 64, now: 0, eligible: eligible, allowed: allowed, suggestions: suggestions, excluding: excluded)
			if blocks.isEmpty { break }
			#expect(blocks.count <= maximum)
			for block in blocks {
				#expect(picker.begin(peer, block: block) != nil); let ready = picker.written(block); #expect(ready)
				_ = picker.verified(block.piece, valid: true); received.append(block.piece)
			}
		}
		#expect(received == expected)
	}
	@Test(arguments: [1, 2]) func activePipelinePreservesEligibilityAndFastRestrictions(_ maximum: Int) throws {
		let layout = try pickerLayout(pieces: 4), peer = UUID()
		var picker = PiecePicker(layout: layout, wanted: [0, 1, 2, 3], completed: [], maximumActive: maximum)
		picker.update(peer, bits: try PieceBitfield(count: 4, pieces: [0, 1, 2, 3]))
		let first = picker.allocate(peer, limit: 1, now: 0, eligible: [0, 1], allowed: [1])
		#expect(first == [PeerBlock(piece: 1, offset: 0, length: 16384)])
		let next = picker.allocate(peer, limit: 1, now: 1, suggestions: [2])
		#expect(next == [PeerBlock(piece: 1, offset: 16384, length: 16384)])
		let restricted = picker.allocate(peer, limit: 1, now: 2, eligible: [3], allowed: [3], suggestions: [2])
		#expect(restricted.map(\.piece) == (maximum == 2 ? [3] : []))
		#expect(picker.allocate(peer, limit: 1, now: 3, eligible: [2], allowed: [3]).isEmpty)
	}
	@Test func saturatedActiveBudgetLetsANewPeerRescueBlocksWithoutUnboundedDuplication() throws {
		let layout = try pickerLayout(), a = UUID(), b = UUID(), c = UUID()
		var picker = PiecePicker(layout: layout, wanted: [0, 1, 2], completed: [], maximumActive: 1)
		for peer in [a, b, c] { picker.update(peer, bits: try PieceBitfield(count: 3, pieces: [0, 1, 2])) }
		let stalled = picker.allocate(a, limit: 2, now: 0), rescue = picker.allocate(b, limit: 2, now: 1)
		#expect(stalled == rescue && rescue.count == 2)
		#expect(picker.allocate(c, limit: 2, now: 1).isEmpty)
		for block in rescue { #expect(picker.begin(b, block: block) == [a]); _ = picker.written(block) }
		_ = picker.verified(0, valid: true)
		#expect(picker.allocate(b, limit: 2, now: 2).allSatisfy { $0.piece == 1 })
	}
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
