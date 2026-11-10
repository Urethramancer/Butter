import Foundation
import Testing
@testable import ButterTorrentNetworking

@Suite struct WebSeedTests {
	let seed = URL(string: "https://seed.invalid/pub/")!
	@Test func encodedMultifileRangeAndWholeFileFallback() async throws {
		let http = ScriptedHTTP([
			.success(HTTPResponse(status: 206, headers: ["Content-Range": "bytes 2-4/9"], body: Data([2, 3, 4]))),
			.success(HTTPResponse(status: 200, body: Data([0, 1, 2])))
		])
		let client = WebSeedClient(transport: http)
		#expect(try await client.fileRange(from: seed, path: ["Å &", "a?#.bin"], fileSize: 9, range: 2..<5, multiFile: true) == Data([2, 3, 4]))
		let request = await http.requests[0]
		#expect(request.url.absoluteString.contains("/%C3%85%20%26/a%3F%23.bin"))
		#expect(request.headers["Range"] == "bytes=2-4")
		let exact = URL(string: "https://seed.invalid/exact.bin?token=1")!
		#expect(try await client.fileRange(from: exact, path: ["ignored.bin"], fileSize: 3, range: 0..<3, multiFile: false) == Data([0, 1, 2]))
		#expect(await http.requests[1].url == exact)
	}
	@Test func invalidRangesAndServerMisbehaviour() async throws {
		for response in [
			HTTPResponse(status: 200, body: Data([1, 2])),
			HTTPResponse(status: 206, headers: ["Content-Range": "bytes 0-1/4"], body: Data([1, 2])),
			HTTPResponse(status: 206, headers: ["Content-Range": "bytes 1-2/4"], body: Data([1])),
			HTTPResponse(status: 206, headers: ["Content-Range": "bytes 1-2/4", "Content-Encoding": "gzip"], body: Data([1, 2]))
		] {
			let client = WebSeedClient(transport: ScriptedHTTP([.success(response)]))
			do { _ = try await client.fileRange(from: seed, path: ["a"], fileSize: 4, range: 1..<3, multiFile: false); Issue.record("Malformed range accepted") }
			catch { #expect(error is HTTPServiceError) }
		}
		let http = ScriptedHTTP([]), client = WebSeedClient(transport: http)
		for path in [[".."], ["/absolute"], ["a/b"], [""]] {
			do { _ = try await client.fileRange(from: seed, path: path, fileSize: 1, range: 0..<1, multiFile: true); Issue.record("Unsafe path accepted") } catch { }
		}
		do { _ = try await client.pieceRange(from: seed, infoHash: Data(), piece: 0, pieceSize: -1); Issue.record("Invalid piece accepted") } catch { }
		#expect(await http.requests.isEmpty)
	}
	@Test func busyRetryHintsAndRecovery() async throws {
		let http = ScriptedHTTP([
			.success(HTTPResponse(status: 503, headers: ["Retry-After": "11"])),
			.success(HTTPResponse(status: 206, headers: ["Content-Range": "bytes 0-2/3"], body: Data([1, 2, 3])))
		])
		let clock = TestClock(), client = WebSeedClient(transport: http, clock: clock)
		do { _ = try await client.fileRange(from: seed, path: ["a"], fileSize: 3, range: 0..<3, multiFile: true); Issue.record("Busy server returned data") } catch { }
		#expect(await client.status(for: seed).retryAt == 111)
		do { _ = try await client.fileRange(from: seed, path: ["a"], fileSize: 3, range: 0..<3, multiFile: true); Issue.record("Cooldown ignored") }
		catch { #expect(error as? HTTPServiceError == .deferredUntil(111)) }
		#expect(await http.requests.count == 1)
		clock.advance(11)
		_ = try await client.fileRange(from: seed, path: ["a"], fileSize: 3, range: 0..<3, multiFile: true)
		#expect(await client.status(for: seed).failures == 0)
	}
	@Test func httpSeedQueryAndRetryBody() async throws {
		let http = ScriptedHTTP([.success(HTTPResponse(status: 200, body: Data([4, 5]))), .success(HTTPResponse(status: 503, body: Data("42".utf8)))])
		let clock = TestClock(), client = WebSeedClient(transport: http, clock: clock)
		let url = URL(string: "https://seed.invalid/seed.php?passkey=abc")!
		#expect(try await client.pieceRange(from: url, infoHash: Data(0..<20), piece: 7, pieceSize: 10, range: 4..<6) == Data([4, 5]))
		let query = await http.requests[0].url.absoluteString
		#expect(query.contains("passkey=abc") && query.contains("piece=7&ranges=4-5") && query.contains("info_hash=%00%01"))
		do { _ = try await client.pieceRange(from: url, infoHash: Data(0..<20), piece: 7, pieceSize: 10); Issue.record("Busy HTTP seed accepted") } catch { }
		#expect(await client.status(for: url).retryAt == 142)
	}
	@Test func boundedConcurrencyAndCorruptionDuringFetch() async throws {
		let http = BlockingHTTP(), client = WebSeedClient(transport: http)
		let tasks = (0..<3).map { _ in Task { try await client.fileRange(from: seed, path: ["a"], fileSize: 3, range: 0..<3, multiFile: true) } }
		try await http.waitForRequests(3)
		do { _ = try await client.fileRange(from: seed, path: ["a"], fileSize: 3, range: 0..<3, multiFile: true); Issue.record("Fourth web seed request admitted") }
		catch { #expect(error as? HTTPServiceError == .busy) }
		try await client.reportCorruption(from: seed)
		await http.release(HTTPResponse(status: 206, headers: ["Content-Range": "bytes 0-2/3"], body: Data([1, 2, 3])))
		for task in tasks {
			do { _ = try await task.value; Issue.record("Banned in-flight data returned") }
			catch { #expect(error as? HTTPServiceError == .banned) }
		}
		#expect(await client.status(for: seed).banned)
	}
	@Test func httpDateRetryAndCancelledFetch() async throws {
		let http = ScriptedHTTP([.success(HTTPResponse(status: 503, headers: ["Retry-After": "Wed, 21 Oct 2015 07:28:00 GMT"]))])
		let clock = TestClock()
		let client = WebSeedClient(transport: http, clock: clock, wallTime: { Date(timeIntervalSince1970: 1_445_412_420) })
		do { _ = try await client.fileRange(from: seed, path: ["a"], fileSize: 3, range: 0..<3, multiFile: true); Issue.record("503 accepted") } catch { }
		#expect(await client.status(for: seed).retryAt == 160)
		let blocked = BlockingHTTP(), cancellable = WebSeedClient(transport: blocked)
		let task = Task { try await cancellable.pieceRange(from: seed, infoHash: Data(0..<20), piece: 0, pieceSize: 3) }
		try await blocked.waitForRequests(1); task.cancel()
		do { _ = try await task.value; Issue.record("Cancelled seed fetch returned data") } catch { #expect(error is CancellationError) }
		#expect(await cancellable.status(for: seed).failures == 0)
	}
}
