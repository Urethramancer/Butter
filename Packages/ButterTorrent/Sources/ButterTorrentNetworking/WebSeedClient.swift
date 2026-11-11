import Foundation

/// WebSeedClient fetches bounded BEP 17 and BEP 19 ranges without trusting them as verified data.
public actor WebSeedClient {
	public struct Status: Sendable {
		public let failures: Int
		public let retryAt: TimeInterval
		public let banned: Bool
		public let error: String?
	}
	private struct State {
		var failures = 0
		var retryAt: TimeInterval = 0
		var banned = false
		var error: String?
	}
	private let transport: any HTTPTransport
	private let clock: any HTTPServiceClock
	private let maximumBytes: Int
	private let wallTime: @Sendable () -> Date
	private var active = 0
	private var states: [URL: State] = [:]
	public init(transport: any HTTPTransport = NetworkHTTPTransport(), clock: any HTTPServiceClock = MonotonicHTTPClock(), maximumBytes: Int = 1_048_576, wallTime: @escaping @Sendable () -> Date = { Date() }) {
		self.transport = transport; self.clock = clock; self.maximumBytes = max(1, min(maximumBytes, 16_777_216))
		self.wallTime = wallTime
	}
	public func status(for seed: URL) -> Status {
		let state = states[seed] ?? State()
		return Status(failures: state.failures, retryAt: state.retryAt, banned: state.banned, error: state.error)
	}
	/// Disables a seed after the caller's piece hash verification fails, including in-flight replies.
	public func reportCorruption(from seed: URL) throws {
		try register(seed)
		states[seed]!.banned = true; states[seed]!.error = "Web seed returned corrupt data."
	}

	/// Fetches a BEP 19 file range. Remote path components must come from original metadata.
	public func fileRange(from seed: URL, path: [String], fileSize: Int64, range: Range<Int64>, multiFile: Bool) async throws -> Data {
		try await fileRange(from: seed, pathBytes: path.map { Data($0.utf8) }, fileSize: fileSize, range: range, multiFile: multiFile)
	}
	/// Fetches a BEP 19 range using the original metadata bytes before local sanitisation.
	public func fileRange(from seed: URL, pathBytes: [Data], fileSize: Int64, range: Range<Int64>, multiFile: Bool) async throws -> Data {
		try HTTPURL.validate(seed)
		guard fileSize >= 0, range.lowerBound >= 0, range.upperBound <= fileSize, !range.isEmpty,
			range.upperBound - range.lowerBound <= maximumBytes, !pathBytes.isEmpty, pathBytes.count <= 100,
			pathBytes.allSatisfy({ !$0.isEmpty && $0.count <= 4096 && $0 != Data(".".utf8) && $0 != Data("..".utf8) && !$0.contains(47) && !$0.contains(0) }),
			pathBytes.reduce(0, { $0 + $1.count }) <= 16_384 else {
			throw HTTPServiceError.invalid("web seed file range or path")
		}
		var parts = URLComponents(url: seed, resolvingAgainstBaseURL: false)!
		if multiFile && !parts.percentEncodedPath.hasSuffix("/") { throw HTTPServiceError.invalid("multifile web seed must be a directory URL") }
		if parts.percentEncodedPath.hasSuffix("/") {
			parts.percentEncodedPath += pathBytes.map(HTTPURL.encode).joined(separator: "/")
		}
		guard let url = parts.url else { throw HTTPServiceError.invalid("web seed path encoding") }
		try HTTPURL.validate(url)
		let headers = ["Range": "bytes=\(range.lowerBound)-\(range.upperBound - 1)", "Accept-Encoding": "identity"]
		return try await fetch(seed: seed, request: HTTPRequest(url: url, headers: headers, maximumResponseBytes: max(1024, Int(range.count))), expected: Int(range.count)) { response in
			if response.status == 206 {
				guard Self.matches(response.headers["content-range"], range: range, size: fileSize) else {
					throw HTTPServiceError.invalid("Content-Range does not match requested bytes")
				}
			} else if response.status != 200 || range.lowerBound != 0 || range.upperBound != fileSize {
				throw HTTPServiceError.invalid("web seed ignored a partial range")
			}
		}
	}

	/// Fetches one contiguous BEP 17 range within a piece; range=nil requests the full piece.
	public func pieceRange(from seed: URL, infoHash: Data, piece: Int, pieceSize: Int, range: Range<Int>? = nil) async throws -> Data {
		guard pieceSize > 0, pieceSize <= 16_777_216 else { throw HTTPServiceError.invalid("HTTP seed piece size") }
		let selected = range ?? 0..<pieceSize
		guard infoHash.count == 20, (0...Int(Int32.max)).contains(piece), pieceSize > 0, pieceSize <= 16_777_216,
			selected.lowerBound >= 0, selected.upperBound <= pieceSize, !selected.isEmpty, selected.count <= maximumBytes else {
			throw HTTPServiceError.invalid("HTTP seed piece range")
		}
		var fields = [("info_hash", HTTPURL.encode(infoHash)), ("piece", String(piece))]
		if range != nil { fields.append(("ranges", "\(selected.lowerBound)-\(selected.upperBound - 1)")) }
		let url = try HTTPURL.query(seed, fields: fields, reserved: ["info_hash", "piece", "ranges"])
		return try await fetch(seed: seed, request: HTTPRequest(url: url, headers: ["Accept-Encoding": "identity"], maximumResponseBytes: max(1024, selected.count)), expected: selected.count, httpSeed: true) { response in
			guard response.status == 200 else { throw HTTPServiceError.status(response.status) }
		}
	}

	private func register(_ seed: URL) throws {
		try HTTPURL.validate(seed)
		guard states[seed] != nil || states.count < 128 else { throw HTTPServiceError.limit("web seed count") }
		if states[seed] == nil { states[seed] = State() }
	}
	private static func matches(_ value: String?, range: Range<Int64>, size: Int64) -> Bool {
		guard let value else { return false }
		let fields = value.split(whereSeparator: \.isWhitespace)
		guard fields.count == 2, fields[0].lowercased() == "bytes" else { return false }
		let extent = fields[1].split(separator: "/", omittingEmptySubsequences: false)
		guard extent.count == 2, extent[1] == "*" || Int64(extent[1]) == size else { return false }
		let bounds = extent[0].split(separator: "-", omittingEmptySubsequences: false)
		return bounds.count == 2 && Int64(bounds[0]) == range.lowerBound && Int64(bounds[1]) == range.upperBound - 1
	}
	private func retryAfter(_ hint: String?, allowDate: Bool) -> TimeInterval? {
		guard let hint else { return nil }
		if let seconds = Int64(hint), hint.utf8.allSatisfy({ (48...57).contains($0) }) { return min(86400, max(1, TimeInterval(seconds))) }
		guard allowDate else { return nil }
		for format in ["EEE, dd MMM yyyy HH:mm:ss z", "EEEE, dd-MMM-yy HH:mm:ss z", "EEE MMM d HH:mm:ss yyyy"] {
			let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
			formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = format; formatter.isLenient = false
			if let date = formatter.date(from: hint) { return min(86400, max(1, date.timeIntervalSince(wallTime()))) }
		}
		return nil
	}
	private func fetch(seed: URL, request: HTTPRequest, expected: Int, httpSeed: Bool = false,
		validate: @Sendable (HTTPResponse) throws -> Void) async throws -> Data {
		try Task.checkCancellation()
		try register(seed)
		guard !states[seed]!.banned else { throw HTTPServiceError.banned }
		guard clock.now() >= states[seed]!.retryAt else { throw HTTPServiceError.deferredUntil(states[seed]!.retryAt) }
		guard active < 3 else { throw HTTPServiceError.busy }
		active += 1; defer { active -= 1 }
		var retryDelay: TimeInterval?
		do {
			let response = try await transport.get(request)
			try Task.checkCancellation()
			guard !states[seed]!.banned else { throw HTTPServiceError.banned }
			if response.status == 503 {
				let hint = httpSeed ? String(data: response.body, encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines) : response.headers["retry-after"]
				retryDelay = retryAfter(hint, allowDate: !httpSeed)
				throw HTTPServiceError.status(503)
			}
			guard response.status == 200 || response.status == 206 else { throw HTTPServiceError.status(response.status) }
			guard response.body.count == expected, response.headers["content-encoding"].map({ $0.lowercased() == "identity" }) ?? true else {
				throw HTTPServiceError.invalid("web seed response length or encoding")
			}
			try validate(response)
			states[seed]!.failures = 0; states[seed]!.retryAt = 0; states[seed]!.error = nil
			return response.body
		} catch {
			if isCancellation(error) { throw CancellationError() }
			if (error as? HTTPServiceError) != .banned {
				states[seed]!.failures = min(states[seed]!.failures + 1, 31)
				states[seed]!.retryAt = clock.now() + (retryDelay ?? min(1800, 30 * pow(2, Double(min(states[seed]!.failures - 1, 6)))))
				states[seed]!.error = error.localizedDescription
			}
			throw error
		}
	}
}
