import Foundation
import Testing
@testable import ButterTorrentNetworking

private func vector(_ hex: String) -> Data { Data(stride(from: 0, to: hex.count, by: 2).map { index in let start = hex.index(hex.startIndex, offsetBy: index); return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)! }) }

@Suite struct MSETests {
	@Test func independentDHAndRC4VectorsAndInvalidPublicValues() throws {
		// Cross-checked with Go's math/big and crypto/rc4, without linking either into Butter.
		let a = try MSEKeyPair(secret: vector("0123456789abcdef0123456789abcdef01234567")), b = try MSEKeyPair(secret: vector("fedcba9876543210fedcba9876543210fedcba98"))
		#expect(a.publicKey == vector("6fd4bc7aa649593205ec30348a3ccc737b61fa01e9e1762c2c53eb69033afecbdf7c13b8ac3643af78d0760b0f42db009f2b96c970f009d060faf617f117d0f1c221cea0561b9a86e852fc70a6f09ad0f82378603aa5e56b811deb3f534bf276"))
		#expect(b.publicKey == vector("e2666b9cffca63998c8e806db50c47ac12512b327c5ec48d62e0a43c2961afcf136e7219fe2ec51e656b2f01ed089dd8cc53c78e7d650df59a752131bcf8ffff122144bf10c6269b47886d6af58389223c66153ebb5e3dc18ea849ceb60ac18e"))
		let expected = vector("0bf59f468e43b9f22a5fd0ccbc9bd7825a7495f6e670c31533db364b536ee297a737d565ff7829d4c397de16aec19f893e3d28eaa14eaf7e17e1026697089fdff81c7dc7e4c65e6211443d9dd3e5d8b0c0e8b2888af39637af18a75cc1b17685")
		#expect(try a.shared(b.publicKey) == expected); #expect(try b.shared(a.publicKey) == expected)
		let cipher = try MSECipher(key: mseHash("keyA", expected, Data("12345678901234567890".utf8)))
		#expect(try cipher.apply(Data(repeating: 0, count: 32)) == vector("ec1b934ec2329bf7865d32f65def7942bdeac98b7d45bb0c58b9a831e11fbe2b"))
		for value in [MSEInteger(0).bytes, MSEInteger(1).bytes, MSEInteger.prime.subtract(MSEInteger(1)).bytes, MSEInteger.prime.bytes, Data(repeating: 255, count: 96), Data(repeating: 0, count: 95)] {
			#expect(throws: (any Error).self) { try a.shared(value) }
		}
	}
	@Test(arguments: [0, 512]) func fragmentedNegotiationInitialPayloadAndBothMethods(_ padding: Int) async throws {
		for method in [PeerEncryptionLevel.plaintext, .rc4] {
			let listener = try await TCPListener.listen(address: IPAddress("127.0.0.1"))
			let endpoint = try NetworkEndpoint("127.0.0.1", port: listener.port), hash = Data(repeating: 42, count: 20), clock = ContinuousTransportClock()
			let config = PeerEncryptionConfiguration(incoming: .required, outgoing: .required, levels: method)
			let payload = Data((0..<2000).map { UInt8($0 % 251) })
			let initiating = Task {
				let raw = try await TCPStream.connect(to: endpoint)
				do { var handshake = MSEHandshake(stream: raw, clock: clock, deadline: clock.now() + 8, configuration: config); handshake.paddingLength = padding; handshake.fragmentBytes = 7; return try await handshake.initiate(hash: hash, initial: payload) }
				catch { raw.close(); throw error }
			}
			let raw = try await listener.accept(timeout: 3)
			do {
				var handshake = MSEHandshake(stream: raw, clock: clock, deadline: clock.now() + 8, configuration: config); handshake.paddingLength = padding; handshake.fragmentBytes = 1
				let server = try await handshake.accept(hashes: [Data(repeating: 7, count: 20), hash]), client = try await initiating.value
				defer { server.close(); client.close() }
				#expect(server.mode == (method == .rc4 ? .rc4 : .negotiatedPlaintext))
				#expect(try await server.read() == payload)
				try await server.write(payload); #expect(try await client.read() == payload)
				try await client.write(payload); #expect(try await server.read() == payload)
			} catch { raw.close(); initiating.cancel(); if let channel = try? await initiating.value { channel.close() }; try? await listener.shutdown(); throw error }
			try await listener.shutdown()
		}
	}
	@Test func enabledFallsBackOnceAndCancellationNeverDowngrades() async throws {
		let listener = try await TCPListener.listen(address: IPAddress("127.0.0.1")), endpoint = try NetworkEndpoint("127.0.0.1", port: listener.port)
		let connection = Task { try await PeerStream.connect(to: endpoint, hash: Data(repeating: 1, count: 20)) }
		let first = try await listener.accept(timeout: 3); _ = try await first.read(); first.close()
		let second = try await listener.accept(timeout: 3), channel = try await connection.value
		#expect(channel.mode == .plaintext)
		try await channel.write(Data([1, 2, 3])); #expect(try await second.read() == Data([1, 2, 3])); channel.close(); second.close()
		let cancelled = Task { try await PeerStream.connect(to: endpoint, hash: Data(repeating: 1, count: 20)) }
		let stalled = try await listener.accept(timeout: 3); _ = try await stalled.read(); cancelled.cancel()
		await #expect(throws: CancellationError.self) { try await cancelled.value }
		stalled.close()
		await #expect(throws: NetworkFailure.timedOut) { try await listener.accept(timeout: 0.1) }
		try await listener.shutdown()
	}
}
