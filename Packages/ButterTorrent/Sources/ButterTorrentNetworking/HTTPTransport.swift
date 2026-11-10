import Foundation
import Darwin

public enum HTTPServiceError: Error, LocalizedError, Equatable, Sendable {
	case invalid(String)
	case limit(String)
	case status(Int)
	case trackerFailure(String)
	case busy
	case deferredUntil(TimeInterval)
	case banned
	public var errorDescription: String? {
		switch self {
		case .invalid(let reason): "Invalid HTTP service response or request: \(reason)."
		case .limit(let reason): "HTTP service exceeded the \(reason) limit."
		case .status(let code): "HTTP service returned status \(code)."
		case .trackerFailure(let reason): "Tracker refused the announce: \(reason)"
		case .busy: "The HTTP service is already busy."
		case .deferredUntil: "The HTTP service is waiting before retrying."
		case .banned: "The web seed was disabled after returning corrupt data."
		}
	}
}

/// HTTPRequest bounds a single GET, including its redirects and decoded response body.
public struct HTTPRequest: Sendable {
	public let url: URL
	public var headers: [String: String]
	public var maximumResponseBytes: Int
	public var timeout: TimeInterval
	public var maximumRedirects: Int
	public var trackerAnnounce: Bool
	public init(url: URL, headers: [String: String] = [:], maximumResponseBytes: Int = 1_048_576,
		timeout: TimeInterval = 30, maximumRedirects: Int = 5, trackerAnnounce: Bool = false) {
		self.url = url; self.headers = headers; self.maximumResponseBytes = maximumResponseBytes
		self.timeout = timeout; self.maximumRedirects = maximumRedirects
		self.trackerAnnounce = trackerAnnounce
	}
}

/// HTTPResponse contains a bounded response. Header names are normalised to lowercase.
public struct HTTPResponse: Sendable {
	public let status: Int
	public let headers: [String: String]
	public let body: Data
	public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
		self.status = status
		self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
		self.body = body
	}
}

/// HTTPTransport allows service tests to inject packet-free responses and cancellation.
public protocol HTTPTransport: Sendable {
	func get(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// FoundationHTTPTransport performs bounded GETs with platform TLS certificate validation.
public actor FoundationHTTPTransport: HTTPTransport {
	private let maximumRequests: Int
	private var active = 0
	public init(maximumRequests: Int = 8) { self.maximumRequests = max(1, min(maximumRequests, 64)) }
	public func get(_ request: HTTPRequest) async throws -> HTTPResponse {
		try Task.checkCancellation()
		try HTTPURL.validate(request.url, tracker: request.trackerAnnounce)
		let token = Set("!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)
		guard request.headers.count <= 16, request.headers.allSatisfy({ name, value in
			!name.isEmpty && name.utf8.count <= 64 && name.utf8.allSatisfy({ token.contains($0) }) && value.utf8.count <= 4096
				&& !value.utf8.contains(where: { $0 == 0 || $0 == 10 || $0 == 13 })
		}) else { throw HTTPServiceError.invalid("HTTP headers") }
		guard (1...16_777_216).contains(request.maximumResponseBytes), request.timeout.isFinite,
			request.timeout > 0, request.timeout <= 300, (0...10).contains(request.maximumRedirects) else {
			throw HTTPServiceError.invalid("HTTP limits")
		}
		guard active < maximumRequests else { throw HTTPServiceError.busy }
		active += 1; defer { active -= 1 }
		return try await HTTPExchange(request).run()
	}
}

enum HTTPURL {
	static func validate(_ url: URL, tracker: Bool = false) throws {
		guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
			["http", "https"].contains(parts.scheme?.lowercased() ?? ""), let host = parts.host, !host.isEmpty,
			parts.user == nil, parts.password == nil, parts.fragment == nil,
			parts.port == nil || (1...65535).contains(parts.port!), url.absoluteString.utf8.count <= 16_384 else {
			throw HTTPServiceError.invalid("HTTP URL")
		}
		if tracker && localLiteral(url, loopbackOnly: true), !parts.percentEncodedPath.hasPrefix("/announce") {
			throw HTTPServiceError.invalid("loopback or local tracker announce path")
		}
	}
	static func localLiteral(_ url: URL, loopbackOnly: Bool = false) -> Bool {
		let host = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.host ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
		if host == "localhost" || host.hasSuffix(".localhost") { return true }
		var v4 = in_addr(), v6 = in6_addr()
		if inet_pton(AF_INET, host, &v4) == 1 {
			let value = UInt32(bigEndian: v4.s_addr)
			if value >> 24 == 127 { return true }
			if loopbackOnly { return false }
			return value >> 24 == 0 || value >> 24 == 10 || value >> 16 == 0xa9fe
				|| value >> 20 == 0xac1 || value >> 16 == 0xc0a8 || value >> 28 >= 14
		}
		if inet_pton(AF_INET6, host, &v6) == 1 {
			let bytes = withUnsafeBytes(of: &v6) { [UInt8]($0) }
			if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 255, bytes[11] == 255 {
				return localLiteral(URL(string: "http://" + bytes[12...15].map(String.init).joined(separator: "."))!, loopbackOnly: loopbackOnly)
			}
			if loopbackOnly { return bytes.prefix(15).allSatisfy({ $0 == 0 }) && bytes[15] == 1 }
			return bytes.prefix(15).allSatisfy({ $0 == 0 }) || bytes[0] & 0xfe == 0xfc || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80) || bytes[0] == 0xff
		}
		return false
	}
	static func encode(_ data: Data) -> String {
		data.map { byte in
			switch byte {
			case 65...90, 97...122, 48...57, 45, 46, 95, 126: String(UnicodeScalar(byte))
			default: String(format: "%%%02X", byte)
			}
		}.joined()
	}
	static func query(_ url: URL, fields: [(String, String)], reserved: Set<String>? = nil) throws -> URL {
		try validate(url)
		var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
		let owned = reserved ?? Set(fields.map(\.0))
		guard !(parts.queryItems ?? []).contains(where: { owned.contains($0.name) }) else {
			throw HTTPServiceError.invalid("URL contains reserved protocol query parameters")
		}
		let query = fields.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
		parts.percentEncodedQuery = [parts.percentEncodedQuery, query].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "&")
		guard let result = parts.url else { throw HTTPServiceError.invalid("query encoding") }
		try validate(result)
		return result
	}
}

private final class HTTPExchange: NSObject, URLSessionDataDelegate, @unchecked Sendable {
	private let request: HTTPRequest
	private let lock = NSLock()
	private var continuation: CheckedContinuation<HTTPResponse, Error>?
	private var session: URLSession?
	private var task: URLSessionDataTask?
	private var cancelled = false
	private var response: HTTPURLResponse?
	private var body = Data()
	private var redirects = 0
	init(_ request: HTTPRequest) { self.request = request }
	func run() async throws -> HTTPResponse {
		try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { continuation in
				let task = lock.withLock { () -> URLSessionDataTask? in
					if cancelled { continuation.resume(throwing: CancellationError()); return nil }
					self.continuation = continuation
					let configuration = URLSessionConfiguration.ephemeral
					configuration.httpCookieStorage = nil; configuration.urlCache = nil; configuration.urlCredentialStorage = nil
					configuration.httpShouldSetCookies = false; configuration.httpMaximumConnectionsPerHost = 1
					configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
					configuration.timeoutIntervalForRequest = min(10, request.timeout)
					configuration.timeoutIntervalForResource = request.timeout
					let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
					var input = URLRequest(url: request.url, timeoutInterval: min(10, request.timeout))
					input.setValue("Butter/Swift", forHTTPHeaderField: "User-Agent")
					for (name, value) in request.headers { input.setValue(value, forHTTPHeaderField: name) }
					let task = session.dataTask(with: input)
					self.session = session; self.task = task
					return task
				}
				task?.resume()
			}
		} onCancel: {
			self.lock.withLock { self.cancelled = true }
			self.finish(.failure(CancellationError()))
		}
	}
	private func finish(_ result: Result<HTTPResponse, Error>) {
		let state = lock.withLock { () -> (CheckedContinuation<HTTPResponse, Error>, URLSession?)? in
			guard let continuation else { return nil }
			let state = (continuation, session)
			self.continuation = nil; session = nil; task = nil
			return state
		}
		guard let (continuation, session) = state else { return }
		session?.invalidateAndCancel()
		continuation.resume(with: result)
	}
	func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
		completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
		guard let response = response as? HTTPURLResponse else {
			completionHandler(.cancel); finish(.failure(HTTPServiceError.invalid("non-HTTP response"))); return
		}
		let headerBytes = response.allHeaderFields.reduce(0) { $0 + String(describing: $1.key).utf8.count + String(describing: $1.value).utf8.count }
		guard headerBytes <= 32_768, response.expectedContentLength <= request.maximumResponseBytes else {
			completionHandler(.cancel); finish(.failure(HTTPServiceError.limit("response size"))); return
		}
		lock.withLock { self.response = response }
		completionHandler(.allow)
	}
	func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
		let overflow = lock.withLock {
			guard continuation != nil else { return false }
			guard data.count <= request.maximumResponseBytes - body.count else { return true }
			body.append(data); return false
		}
		if overflow { finish(.failure(HTTPServiceError.limit("response body"))) }
	}
	func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
		if let error { finish(.failure(error)); return }
		let result: Result<HTTPResponse, Error> = lock.withLock {
			guard let response else { return .failure(HTTPServiceError.invalid("missing HTTP headers")) }
			let headers = Dictionary(response.allHeaderFields.map { (String(describing: $0.key), String(describing: $0.value)) }, uniquingKeysWith: { _, last in last })
			return .success(HTTPResponse(status: response.statusCode, headers: headers, body: body))
		}
		finish(result)
	}
	func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
		newRequest: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
		do {
			guard let url = newRequest.url else { throw HTTPServiceError.invalid("redirect URL") }
			try HTTPURL.validate(url, tracker: request.trackerAnnounce)
			guard HTTPURL.localLiteral(request.url) || !HTTPURL.localLiteral(url) else { throw HTTPServiceError.invalid("redirect to local address") }
			guard response.url?.scheme?.lowercased() != "https" || url.scheme?.lowercased() == "https" else { throw HTTPServiceError.invalid("HTTPS downgrade") }
			try lock.withLock {
				guard redirects < request.maximumRedirects else { throw HTTPServiceError.limit("redirect count") }
				redirects += 1
			}
			var next = newRequest
			// Keep ranges across redirects, without forwarding caller authentication.
			for (name, value) in request.headers where ["range", "accept-encoding"].contains(name.lowercased()) { next.setValue(value, forHTTPHeaderField: name) }
			next.setValue(nil, forHTTPHeaderField: "Authorization"); next.setValue(nil, forHTTPHeaderField: "Cookie")
			completionHandler(next)
		} catch { completionHandler(nil); finish(.failure(error)) }
	}
	func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
		completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
		completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
	}
}
