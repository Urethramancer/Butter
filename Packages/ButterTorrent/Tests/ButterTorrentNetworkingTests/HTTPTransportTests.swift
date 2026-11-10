import Foundation
import Testing
@testable import ButterTorrentNetworking

@Suite struct HTTPTransportTests {
	@Test func localRedirectAndChunkedResponse() async throws {
		let server = try await HTTPFixture.start { input in
			if input.target == "/redirect" { return .init(status: 302, headers: ["Location": "/body"]) }
			return .init(body: Data("fragmented fixture".utf8), chunked: true)
		}
		do {
			let response = try await FoundationHTTPTransport().get(HTTPRequest(url: server.url.appendingPathComponent("redirect")))
			#expect(response.status == 200 && response.body == Data("fragmented fixture".utf8))
		} catch { await server.stop(); throw error }
		await server.stop()
	}
	@Test func bodyAndDeclaredLengthBounds() async throws {
		for chunked in [false, true] {
			let server = try await HTTPFixture.start { _ in .init(body: Data(repeating: 42, count: 1000), chunked: chunked) }
			do {
				_ = try await FoundationHTTPTransport().get(HTTPRequest(url: server.url, maximumResponseBytes: 32))
				Issue.record("Oversized HTTP body was accepted")
			} catch { #expect(error is HTTPServiceError) }
			await server.stop()
		}
	}
	@Test func redirectLimitAndSchemeRefusal() async throws {
		for location in ["/again", "file:///etc/passwd", "http://user:secret@127.0.0.1/"] {
			let server = try await HTTPFixture.start { _ in .init(status: 302, headers: ["Location": location]) }
			do {
				_ = try await FoundationHTTPTransport().get(HTTPRequest(url: server.url, maximumRedirects: 2))
				Issue.record("Unsafe or endless redirect accepted")
			} catch { #expect(error is HTTPServiceError || error is URLError) }
			await server.stop()
		}
	}
	@Test func cancellationAndDeadline() async throws {
		let server = try await HTTPFixture.start { _ in .init(hang: true) }
		let transport = FoundationHTTPTransport()
		let task = Task { try await transport.get(HTTPRequest(url: server.url, timeout: 2)) }
		task.cancel()
		do { _ = try await task.value; Issue.record("Cancelled request returned success") }
		catch { #expect(error is CancellationError) }
		let start = ProcessInfo.processInfo.systemUptime
		do { _ = try await transport.get(HTTPRequest(url: server.url, timeout: 0.2)); Issue.record("Deadline was ignored") }
		catch { #expect(error as? NetworkFailure == .timedOut) }
		#expect(ProcessInfo.processInfo.systemUptime - start < 5)
		await server.stop()
	}
	@Test func inFlightCancellationAndRequestLimit() async throws {
		let signal = AsyncStream<Void>.makeStream()
		let server = try await HTTPFixture.start { _ in signal.continuation.yield(()); return .init(hang: true) }
		let transport = FoundationHTTPTransport(maximumRequests: 1)
		let task = Task { try await transport.get(HTTPRequest(url: server.url, timeout: 2)) }
		do {
			try await deadline { for await _ in signal.stream { return }; throw HTTPServiceError.invalid("fixture signal ended") }
			do { _ = try await transport.get(HTTPRequest(url: server.url)); Issue.record("Unbounded request admitted") }
			catch { #expect(error as? HTTPServiceError == .busy) }
			for _ in 0..<10 { task.cancel() }
			do { _ = try await task.value; Issue.record("In-flight cancellation returned success") }
			catch { #expect(error is CancellationError) }
		} catch { task.cancel(); await server.stop(); signal.continuation.finish(); throw error }
		await server.stop(); signal.continuation.finish()
	}
}
