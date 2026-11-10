import Foundation

/// NetworkHTTPTransport pins each HTTP hop to validated DNS answers without weakening TLS trust.
public actor NetworkHTTPTransport: HTTPTransport {
	private let maximumRequests: Int
	private let resolver: any AddressResolving
	private let clock: any TransportClock
	private var active = 0
	public init(maximumRequests: Int = 8, resolver: any AddressResolving = SystemAddressResolver(), clock: any TransportClock = ContinuousTransportClock()) {
		self.maximumRequests = max(1, min(maximumRequests, 64)); self.resolver = resolver; self.clock = clock
	}
	public func get(_ request: HTTPRequest) async throws -> HTTPResponse {
		guard request.body.isEmpty else { throw HTTPServiceError.invalid("GET body") }
		return try await execute(request, method: "GET")
	}
	public func post(_ request: HTTPRequest) async throws -> HTTPResponse { try await execute(request, method: "POST") }
	private func execute(_ request: HTTPRequest, method: String) async throws -> HTTPResponse {
		try Task.checkCancellation()
		try HTTPURL.validate(request.url, tracker: request.trackerAnnounce)
		guard request.headers.count <= 16, request.headers.allSatisfy({ name, value in
			!name.isEmpty && name.utf8.count <= 64 && name.utf8.allSatisfy({ httpHeaderToken.contains($0) }) && value.utf8.count <= 4096
				&& !value.utf8.contains(where: { $0 == 0 || $0 == 10 || $0 == 13 })
				&& !["host", "connection", "content-length", "transfer-encoding"].contains(name.lowercased())
		}), request.body.count <= 65_536 else { throw HTTPServiceError.invalid("HTTP headers or request body") }
		guard (1...16_777_216).contains(request.maximumResponseBytes), request.timeout.isFinite,
			request.timeout > 0, request.timeout <= 300, (0...10).contains(request.maximumRedirects) else { throw HTTPServiceError.invalid("HTTP limits") }
		guard active < maximumRequests else { throw HTTPServiceError.busy }
		active += 1; defer { active -= 1 }
		let deadline = clock.now() + request.timeout
		var url = request.url, headers = request.headers, originLocal: Bool?
		for hop in 0...request.maximumRedirects {
			try Task.checkCancellation()
			try HTTPURL.validate(url, tracker: request.trackerAnnounce)
			let host = HTTPURL.host(url)
			let port = UInt16(url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80))
			let answers = try await resolver.resolve(host: host, port: port, timeout: remaining(deadline))
			let local = try HTTPAddressPolicy.validate(answers, port: port, url: url, tracker: request.trackerAnnounce, originLocal: originLocal)
			if originLocal == nil { originLocal = local }
			let response = try await exchange(url: url, answers: answers, headers: headers, request: request, method: method, deadline: deadline)
			guard [301, 302, 303, 307, 308].contains(response.status) else { return response }
			guard hop < request.maximumRedirects else { throw HTTPServiceError.limit("redirect count") }
			guard method == "GET", let location = response.headers["location"], let next = URL(string: location, relativeTo: url)?.absoluteURL else { throw HTTPServiceError.invalid("HTTP redirect") }
			guard url.scheme?.lowercased() != "https" || next.scheme?.lowercased() == "https" else { throw HTTPServiceError.invalid("HTTPS downgrade") }
			headers = headers.filter { !["authorization", "cookie"].contains($0.key.lowercased()) }; url = next
		}
		throw HTTPServiceError.limit("redirect count")
	}
	private func remaining(_ deadline: TimeInterval) throws -> TimeInterval {
		let seconds = deadline - clock.now()
		guard seconds > 0 else { throw NetworkFailure.timedOut }
		return min(seconds, 300)
	}
	private func exchange(url: URL, answers: [NetworkEndpoint], headers: [String: String], request: HTTPRequest, method: String, deadline: TimeInterval) async throws -> HTTPResponse {
		var stream: TCPStream?, failure: Error = NetworkFailure.closed
		for endpoint in answers {
			do { stream = try await TCPStream.connect(to: endpoint, tlsServerName: url.scheme?.lowercased() == "https" ? HTTPURL.host(url) : nil, timeout: min(10, remaining(deadline)), clock: clock); break }
			catch { if isCancellation(error) { throw CancellationError() }; failure = error }
		}
		guard let stream else { throw failure }
		defer { stream.close() }
		let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
		var target = parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath
		if let query = parts.percentEncodedQuery { target += "?" + query }
		let host = HTTPURL.host(url)
		var authority = host.contains(":") ? "[\(host.replacingOccurrences(of: "%", with: "%25"))]" : host
		if let port = url.port { authority += ":\(port)" }
		var fields = headers
		if !fields.keys.contains(where: { $0.lowercased() == "accept-encoding" }) { fields["Accept-Encoding"] = "identity" }
		if !fields.keys.contains(where: { $0.lowercased() == "user-agent" }) { fields["User-Agent"] = "Butter/Swift" }
		var head = "\(method) \(target) HTTP/1.1\r\nHost: \(authority)\r\nConnection: close\r\n"
		for (name, value) in fields { head += "\(name): \(value)\r\n" }
		if method == "POST" { head += "Content-Length: \(request.body.count)\r\n" }
		var bytes = Data((head + "\r\n").utf8); bytes.append(request.body)
		try await stream.write(bytes, timeout: min(10, remaining(deadline)))
		var parser = HTTPResponseParser(maximumBytes: request.maximumResponseBytes)
		while true {
			let bytes = try await stream.read(timeout: min(10, remaining(deadline)))
			if let response = try parser.feed(bytes, eof: bytes.isEmpty) { return response }
		}
	}
}

enum HTTPAddressPolicy {
	static func validate(_ answers: [NetworkEndpoint], port: UInt16, url: URL, tracker: Bool, originLocal: Bool?) throws -> Bool {
		guard !answers.isEmpty, answers.count <= 16, answers.allSatisfy({ $0.port == port && !$0.address.isUnspecified && !$0.address.isMulticast }) else { throw HTTPServiceError.invalid("DNS endpoints") }
		let local = answers.allSatisfy { $0.address.isLocal }
		guard local || answers.allSatisfy({ !$0.address.isLocal }) else { throw HTTPServiceError.invalid("mixed public and local DNS answers") }
		guard originLocal != false || !local else { throw HTTPServiceError.invalid("redirect resolved to a local address") }
		if tracker && answers.contains(where: { $0.address.isLoopback }) && !URLComponents(url: url, resolvingAgainstBaseURL: false)!.percentEncodedPath.hasPrefix("/announce") {
			throw HTTPServiceError.invalid("resolved loopback tracker path")
		}
		return local
	}
}
