import Foundation

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

/// HTTPRequest bounds an HTTP request, including redirects and its decoded response body.
public struct HTTPRequest: Sendable {
	public let url: URL
	public var headers: [String: String]
	public var maximumResponseBytes: Int
	public var timeout: TimeInterval
	public var maximumRedirects: Int
	public var trackerAnnounce: Bool
	public var body: Data
	public init(url: URL, headers: [String: String] = [:], maximumResponseBytes: Int = 1_048_576,
		timeout: TimeInterval = 30, maximumRedirects: Int = 5, trackerAnnounce: Bool = false, body: Data = Data()) {
		self.url = url; self.headers = headers; self.maximumResponseBytes = maximumResponseBytes
		self.timeout = timeout; self.maximumRedirects = maximumRedirects
		self.trackerAnnounce = trackerAnnounce
		self.body = body
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
	func post(_ request: HTTPRequest) async throws -> HTTPResponse
}
extension HTTPTransport {
	public func post(_ request: HTTPRequest) async throws -> HTTPResponse { throw HTTPServiceError.invalid("POST is not supported by this transport") }
}

/// FoundationHTTPTransport preserves the phase 4 API name for the pinned Network transport.
public typealias FoundationHTTPTransport = NetworkHTTPTransport

enum HTTPURL {
	static func host(_ url: URL) -> String {
		let host = url.host ?? ""
		return (host.removingPercentEncoding ?? host).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
	}
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
		let host = host(url).lowercased()
		if host == "localhost" || host.hasSuffix(".localhost") { return true }
		guard let address = try? IPAddress(host) else { return false }
		return loopbackOnly ? address.isLoopback : address.isLocal
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
