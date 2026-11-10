import Foundation
import Testing
@testable import ButterTorrentNetworking

@Suite struct HTTPFramingTests {
	@Test func fragmentedChunkedInformationalAndEOF() throws {
		let message = Data("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3;ext=yes\r\nabc\r\n0\r\nX-Note: test\r\n\r\n".utf8)
		var parser = HTTPResponseParser(maximumBytes: 100), response: HTTPResponse?
		for byte in message { response = try parser.feed(Data([byte])) }
		#expect(response?.body == Data("abc".utf8))
		var close = HTTPResponseParser(maximumBytes: 10)
		#expect(try close.feed(Data("HTTP/1.0 200 OK\r\n\r\nabc".utf8)) == nil)
		#expect(try close.feed(Data(), eof: true)?.body == Data("abc".utf8))
	}
	@Test(arguments: [
		"HTTP/1.1 200 OK\r\nContent-Length: 3\r\nContent-Length: 3\r\n\r\nabc",
		"HTTP/1.1 200 OK\r\nContent-Length: 3\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
		"HTTP/1.1 200 OK\r\n folded: header\r\n\r\n",
		"HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n",
		"HTTP/1.1 101 Switching Protocols\r\n\r\n",
		"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nZ\r\n",
		"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n\r\n",
		"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabcXX",
		"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nContent-Length: 1\r\n\r\n",
		"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nabc",
		"HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nab"
	]) func malformedFraming(_ message: String) {
		var parser = HTTPResponseParser(maximumBytes: 100)
		#expect(throws: HTTPServiceError.self) { try parser.feed(Data(message.utf8), eof: true) }
	}
	@Test func compressedBoundsAndChecksums() throws {
		// Fixed RFC 1952 gzip stream for "hello", including CRC32 and input size.
		let gzip = Data([31,139,8,0,0,0,0,0,0,3,203,72,205,201,201,7,0,134,166,16,54,5,0,0,0])
		let head = Data("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 25\r\n\r\n".utf8)
		var parser = HTTPResponseParser(maximumBytes: 100)
		#expect(try parser.feed(head + gzip)?.body == Data("hello".utf8))
		var corrupt = gzip; corrupt[20] ^= 255
		var bad = HTTPResponseParser(maximumBytes: 100)
		#expect(throws: HTTPServiceError.self) { try bad.feed(head + corrupt) }
		var small = HTTPResponseParser(maximumBytes: 4)
		let chunked = Data("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
		// Feed the compressed bytes in tiny chunks so the decoded cap, not wire chunk size, rejects it.
		var wire = chunked
		for byte in gzip { wire.append(Data("1\r\n".utf8)); wire.append(byte); wire.append(Data("\r\n".utf8)) }
		wire.append(Data("0\r\n\r\n".utf8))
		#expect(throws: HTTPServiceError.self) { try small.feed(wire) }
	}
}

actor PinnedResolver: AddressResolving {
	var calls: [String] = []
	let address: String
	init(_ address: String = "127.0.0.1") { self.address = address }
	func resolve(host: String, port: UInt16, timeout: TimeInterval) async throws -> [NetworkEndpoint] {
		calls.append(host)
		guard calls.count == 1 else { throw NetworkFailure.invalid("unexpected second DNS lookup") }
		return [try NetworkEndpoint(address, port: port)]
	}
}

@Suite struct HTTPAddressTests {
	@Test func ipv6LiteralPreservesOnePairOfHostBrackets() async throws {
		let inputs = AsyncStream<HTTPFixture.Input>.makeStream(bufferingPolicy: .bufferingNewest(1))
		let server = try await HTTPFixture.start(host: "::1") { input in
			inputs.continuation.yield(input); return .init(body: Data([42]))
		}
		do {
			let response = try await NetworkHTTPTransport().get(HTTPRequest(url: server.url))
			#expect(response.status == 200 && response.body == Data([42]))
			let input = try await deadline {
				for await input in inputs.stream { return input }
				throw NetworkFailure.closed
			}
			#expect(input.headers["host"] == "[::1]:\(server.url.port!)")
		} catch { await server.stop(); throw error }
		await server.stop()
	}
	@Test func pinnedHostnameUsesOneLookupAndOriginalHost() async throws {
		let server = try await HTTPFixture.start { input in
			input.headers["host"]?.hasPrefix("pinned.invalid:") == true ? .init(body: Data([42])) : .init(status: 400)
		}
		let resolver = PinnedResolver()
		var parts = URLComponents(url: server.url, resolvingAgainstBaseURL: false)!; parts.host = "pinned.invalid"
		do {
			let response = try await NetworkHTTPTransport(resolver: resolver).get(HTTPRequest(url: parts.url!))
			#expect(response.status == 200 && response.body == Data([42]))
			#expect(await resolver.calls == ["pinned.invalid"])
		} catch { await server.stop(); throw error }
		await server.stop()
	}
	@Test func resolvedLoopbackAndRedirectPolicies() async throws {
		let url = URL(string: "https://alias.invalid/admin")!
		let local = [try NetworkEndpoint("127.0.0.1", port: 443)]
		let publicIP = [try NetworkEndpoint("8.8.8.8", port: 443)]
		#expect(throws: HTTPServiceError.self) { try HTTPAddressPolicy.validate(local, port: 443, url: url, tracker: true, originLocal: nil) }
		#expect(throws: HTTPServiceError.self) { try HTTPAddressPolicy.validate(local, port: 443, url: url, tracker: false, originLocal: false) }
		#expect(throws: HTTPServiceError.self) { try HTTPAddressPolicy.validate(local + publicIP, port: 443, url: url, tracker: false, originLocal: nil) }
		#expect(try HTTPAddressPolicy.validate(publicIP, port: 443, url: url, tracker: true, originLocal: false) == false)
		do { _ = try await NetworkHTTPTransport(resolver: PinnedResolver()).get(HTTPRequest(url: url, trackerAnnounce: true)); Issue.record("Resolved loopback admin URL accepted") }
		catch { #expect(error as? HTTPServiceError == .invalid("resolved loopback tracker path")) }
	}
}
