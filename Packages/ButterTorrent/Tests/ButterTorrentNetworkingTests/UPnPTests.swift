import Foundation
import Testing
@testable import ButterTorrentNetworking

private let wanType = "urn:schemas-upnp-org:service:WANIPConnection:1"
private func deviceXML(control: String = "/control") -> Data {
	Data("<?xml version=\"1.0\"?>\n<root><device><serviceList><service><serviceType>\(wanType)</serviceType><controlURL>\(control)</controlURL></service></serviceList></device></root>".utf8)
}
private func soapReply(_ action: String, fields: [String: String] = [:]) -> HTTPResponse {
	let values = fields.map { "<\($0.key)>\($0.value)</\($0.key)>" }.joined()
	return HTTPResponse(status: 200, body: Data("<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><u:\(action)Response xmlns:u=\"\(wanType)\">\(values)</u:\(action)Response></s:Body></s:Envelope>".utf8))
}
private func soapFault(_ code: Int) -> HTTPResponse {
	HTTPResponse(status: 500, body: Data("<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><s:Fault><detail><UPnPError><errorCode>\(code)</errorCode></UPnPError></detail></s:Fault></s:Body></s:Envelope>".utf8))
}
private actor RouterHTTP: HTTPTransport {
	let description: Data
	var replies: [HTTPResponse]
	var posts: [HTTPRequest] = []
	init(description: Data = deviceXML(), replies: [HTTPResponse]) { self.description = description; self.replies = replies }
	func get(_ request: HTTPRequest) async throws -> HTTPResponse { HTTPResponse(status: 200, body: description) }
	func post(_ request: HTTPRequest) async throws -> HTTPResponse {
		posts.append(request)
		guard !replies.isEmpty else { throw NetworkFailure.invalid("router fixture exhausted") }
		return replies.removeFirst()
	}
}

@Suite struct UPnPTests {
	let owned = ["NewInternalClient": "192.168.1.2", "NewInternalPort": "6881", "NewPortMappingDescription": "Butter"]
	private func candidate() throws -> UPnPCandidate { try UPnPCandidate(location: URL(string: "http://192.168.1.1/root.xml")!, gateway: IPAddress("192.168.1.1"), expires: 1000, bootID: 1) }
	@Test func mappingRenewalDeletionAndOwnership() async throws {
		let router = RouterHTTP(replies: [soapFault(714), soapReply("AddPortMapping"), soapReply("GetSpecificPortMappingEntry", fields: owned), soapReply("AddPortMapping"), soapReply("GetSpecificPortMappingEntry", fields: owned), soapReply("DeletePortMapping")])
		let service = try await UPnPService.load(candidate(), transport: router), clock = TestClock()
		let client = try UPnPClient(service: service, internalClient: IPAddress("192.168.1.2"), transport: router, clock: clock)
		let mapping = try await client.map(.tcp, internalPort: 6881, externalPort: 6881, lifetime: 60)
		#expect(mapping.renewAt == 145)
		do { _ = try await client.map(.tcp, internalPort: 6882, externalPort: 6882); Issue.record("Changing ports orphaned the previous mapping") } catch { #expect(error is NetworkFailure) }
		clock.advance(45); try await client.renewIfDue(); try await client.remove(.tcp)
		let posts = await router.posts
		#expect(posts.count == 6 && posts.allSatisfy { $0.url.host == "192.168.1.1" && $0.maximumRedirects == 0 })
		#expect(String(decoding: posts[1].body, as: UTF8.self).contains("<NewInternalClient>192.168.1.2</NewInternalClient>"))
		let foreign = RouterHTTP(replies: [soapReply("GetSpecificPortMappingEntry", fields: owned)])
		let other = try UPnPClient(service: service, internalClient: IPAddress("192.168.1.2"), transport: foreign)
		do { _ = try await other.map(.tcp, internalPort: 6881, externalPort: 6881); Issue.record("Foreign mapping overwritten") }
		catch { #expect(error as? UPnPFailure == .mappingOwnedByAnotherClient) }
		#expect(await foreign.posts.count == 1)
	}
	@Test func permanentLeaseFallbackAndRebootRecovery() async throws {
		let router = RouterHTTP(replies: [soapFault(714), soapFault(725), soapReply("AddPortMapping"), soapFault(714), soapReply("AddPortMapping")])
		let client = try await UPnPClient(service: UPnPService.load(candidate(), transport: router), internalClient: IPAddress("192.168.1.2"), transport: router)
		let mapping = try await client.map(.udp, internalPort: 6881, externalPort: 6881)
		#expect(mapping.lifetime == 0 && mapping.renewAt.isInfinite)
		await client.observeBootID(2); #expect(await client.requiresRemapping)
		try await client.renewIfDue(); #expect(await client.requiresRemapping == false)
		#expect(await router.posts.count == 5)
	}
	@Test func entityAndControlOriginRefusals() async throws {
		for data in [Data("<!DOCTYPE root SYSTEM \"file:///etc/passwd\"><root/>".utf8), Data("<!DOCTYPE root [<!ENTITY a 'expanded'>]><root>&a;</root>".utf8)] {
			#expect(throws: NetworkFailure.self) { try UPnPXML.parse(data) }
		}
		let router = RouterHTTP(description: deviceXML(control: "http://169.254.169.254/metadata"), replies: [])
		do { _ = try await UPnPService.load(candidate(), transport: router); Issue.record("Foreign control origin accepted") } catch { #expect(error as? NetworkFailure == .invalid("UPnP control origin")) }
		let malformed = RouterHTTP(replies: [soapFault(714), HTTPResponse(status: 200, body: Data("<root/>".utf8))])
		let client = try await UPnPClient(service: UPnPService.load(candidate(), transport: malformed), internalClient: IPAddress("192.168.1.2"), transport: malformed)
		do { _ = try await client.map(.tcp, internalPort: 6881, externalPort: 6881); Issue.record("Missing action response accepted") }
		catch { #expect(error as? NetworkFailure == .invalid("UPnP action response")) }
	}
	@Test func realLoopbackDescriptionAndSOAP() async throws {
		let server = try await HTTPFixture.start { input in
			if input.method == "GET" && input.target == "/root.xml" { return .init(body: deviceXML()) }
			guard input.method == "POST", input.target == "/control" else { return .init(status: 400) }
			let action = input.headers["soapaction"] ?? ""
			let response: HTTPResponse
			if action.contains("#GetSpecificPortMappingEntry") { response = soapFault(714) }
			else if action.contains("#AddPortMapping"), String(decoding: input.body, as: UTF8.self).contains("<NewInternalPort>6881</NewInternalPort>") { response = soapReply("AddPortMapping") }
			else { return .init(status: 400) }
			return .init(status: response.status, body: response.body, chunked: true)
		}
		do {
			// An explicitly supplied fixture candidate is distinct from unsolicited SSDP.
			let candidate = try UPnPCandidate(location: server.url.appendingPathComponent("root.xml"), gateway: IPAddress("127.0.0.1"), expires: 1000)
			let service = try await UPnPService.load(candidate)
			let client = try UPnPClient(service: service, internalClient: IPAddress("127.0.0.1"))
			let mapping = try await client.map(.tcp, internalPort: 6881, externalPort: 6881, lifetime: 60)
			#expect(mapping.externalPort == 6881 && mapping.lifetime == 60)
		} catch { await server.stop(); throw error }
		await server.stop()
	}
}
