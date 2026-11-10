import Foundation

/// HTTPServiceClock exposes monotonic time for deterministic lifecycle and backoff tests.
public protocol HTTPServiceClock: Sendable { func now() -> TimeInterval }
public struct MonotonicHTTPClock: HTTPServiceClock {
	public init() {}
	public func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// TrackerAnnouncer manages tiers, events and backoff. The engine calls announceIfDue on its clock.
public actor TrackerAnnouncer {
	public enum Phase: Sendable { case idle, running, stopping, stopped }
	public struct Status: Sendable {
		public let phase: Phase
		public let nextAnnounce: TimeInterval
		public let consecutiveFailures: Int
		public let lastError: String?
	}
	private var tiers: [[URL]]
	private let client: any TrackerAnnouncing
	private let clock: any HTTPServiceClock
	private struct Key: Hashable { let url: URL; let hash: Data }
	private let request: TrackerRequest
	private let hashes: [Data]
	private var contacted: Set<Key> = []
	private var completed: Set<Key> = []
	private var trackerIDs: [Key: Data] = [:]
	private var due: [Key: TimeInterval] = [:]
	private var hashFailures: [Key: Int] = [:]
	private var responses: [Key: TrackerResponse] = [:]
	private var hashMessages: [Key: String] = [:]
	private var phase: Phase = .idle
	private var busy = false
	private var next: TimeInterval = 0
	private var failures = 0
	private var lastError: String?
	private var endpointMessages: [URL: String] = [:]
	private var initialLeft: Int64 = 0
	private var completionPending = false
	private var completionSent = false
	private let privateTorrent: Bool
	private let beforeSwitch: @Sendable (URL) async throws -> Void
	private var activeTracker: URL?
	private var attemptedTracker: URL?
	public init(tiers: [[URL]], request: TrackerRequest, client: any TrackerAnnouncing = HTTPTrackerClient(),
		clock: any HTTPServiceClock = MonotonicHTTPClock(), order: @Sendable ([URL]) -> [URL] = { $0.shuffled() },
		additionalInfoHashes: [Data] = [],
		privateTorrent: Bool = false, beforeSwitch: @escaping @Sendable (URL) async throws -> Void = { _ in }) throws {
		guard tiers.count <= 32, tiers.reduce(0, { $0 + $1.count }) <= 128 else { throw HTTPServiceError.limit("tracker count") }
		guard additionalInfoHashes.count <= 1 else { throw HTTPServiceError.limit("tracker identities") }
		guard additionalInfoHashes.allSatisfy({ $0.count == 20 }) else { throw HTTPServiceError.invalid("tracker identity") }
		for url in tiers.flatMap({ $0 }) {
			try Self.validate(tracker: url, request: request)
		}
		self.tiers = tiers.filter { !$0.isEmpty }.map(order)
		self.request = request; self.client = client; self.clock = clock
		hashes = [request.infoHash] + additionalInfoHashes.filter { $0 != request.infoHash }
		self.privateTorrent = privateTorrent; self.beforeSwitch = beforeSwitch
	}
	public var status: Status { Status(phase: phase, nextAnnounce: next, consecutiveFailures: failures, lastError: lastError) }
	public var messages: [URL: String] { endpointMessages }
	public func append(_ url: URL) throws {
		if tiers.flatMap({ $0 }).contains(url) { return }
		guard tiers.count < 32, tiers.reduce(0, { $0 + $1.count }) < 128 else { throw HTTPServiceError.limit("tracker count") }
		try Self.validate(tracker: url, request: request)
		tiers.append([url]); next = min(next, clock.now())
	}
	public static func validate(tracker: URL, request: TrackerRequest) throws {
		if tracker.scheme?.lowercased() == "udp" { _ = try UDPTrackerClient.destination(tracker); try request.validateFields() }
		else { _ = try request.url(for: tracker) }
	}
	@discardableResult public func start(_ counters: TrackerCounters) async throws -> TrackerResponse {
		guard !busy else { throw HTTPServiceError.busy }
		try validate(counters)
		guard phase == .idle || phase == .stopped else { throw HTTPServiceError.invalid("tracker lifecycle is already started") }
		phase = .running; initialLeft = counters.left; completionPending = false; completionSent = false
		contacted.removeAll(); completed.removeAll(); trackerIDs.removeAll(); due.removeAll(); hashFailures.removeAll(); responses.removeAll(); hashMessages.removeAll(); failures = 0
		activeTracker = nil; attemptedTracker = nil
		return try await announce(counters)
	}
	public func announceIfDue(_ counters: TrackerCounters) async throws -> TrackerResponse? {
		guard !busy else { throw HTTPServiceError.busy }
		try validate(counters)
		guard phase == .running, clock.now() >= next else { return nil }
		return try await announce(counters)
	}
	@discardableResult public func complete(_ counters: TrackerCounters) async throws -> TrackerResponse? {
		guard !busy else { throw HTTPServiceError.busy }
		try validate(counters)
		guard phase == .running, counters.left == 0 else { throw HTTPServiceError.invalid("completion before verified download") }
		guard initialLeft > 0, !completionSent else { return nil }
		completionPending = true
		return try await announce(counters, forceCompletion: true)
	}
	public func stop(_ counters: TrackerCounters) async throws {
		guard !busy else { throw HTTPServiceError.busy }
		try validate(counters)
		phase = .stopping; busy = true; defer { busy = false }
		responses.removeAll()
		var failure: Error?
		for url in tiers.flatMap({ $0 }) {
			let keys = hashes.map { Key(url: url, hash: $0) }.filter { contacted.contains($0) }
			guard !keys.isEmpty else { continue }
			var messages: [String] = []
			for key in keys {
				do {
					try Task.checkCancellation()
					let message = TrackerRequest(infoHash: key.hash, peerID: request.peerID, port: request.port, counters: counters, event: .stopped, trackerID: trackerIDs[key], wantedPeers: 0)
					_ = try await client.announce(to: url, request: message)
					try Task.checkCancellation(); contacted.remove(key)
				} catch {
					if isCancellation(error) { throw CancellationError() }
					failure = error; messages.append(error.localizedDescription)
				}
			}
			endpointMessages[url] = messages.isEmpty ? nil : String(messages.joined(separator: "; ").prefix(1024))
		}
		if let failure { lastError = failure.localizedDescription; throw failure }
		phase = .stopped; lastError = nil
	}
	private func announce(_ counters: TrackerCounters, forceCompletion: Bool = false) async throws -> TrackerResponse {
		busy = true; defer { busy = false }
		var failure: Error = HTTPServiceError.invalid("no available trackers")
		let ordered = tiers.flatMap { $0 }
		let urls: [URL]
		if privateTorrent, let activeTracker { urls = [activeTracker] + ordered.filter { $0 != activeTracker } }
		else { urls = ordered }
		for url in urls {
			do {
				try Task.checkCancellation()
				let keys = hashes.map { Key(url: url, hash: $0) }
				let eligible = keys.filter { clock.now() >= (due[$0] ?? 0) || (forceCompletion && !completed.contains($0)) }
				let cached = keys.filter { !eligible.contains($0) }.compactMap { responses[$0] }
				guard !eligible.isEmpty || !cached.isEmpty else { continue }
				if !eligible.isEmpty {
					if privateTorrent, let attemptedTracker, attemptedTracker != url { try await beforeSwitch(url); try Task.checkCancellation() }
					attemptedTracker = url
				}
				var fresh: [TrackerResponse] = []
				for key in eligible {
					do {
						let response = try await announce(counters, key: key)
						responses[key] = response; hashFailures[key] = nil; hashMessages[key] = response.warning
						due[key] = clock.now() + max(30, response.interval, response.minimumInterval); fresh.append(response)
					} catch {
						if isCancellation(error) { throw CancellationError() }
						failure = error; responses[key] = nil; hashMessages[key] = error.localizedDescription
						let count = min(31, (hashFailures[key] ?? 0) + 1); hashFailures[key] = count; due[key] = clock.now() + backoff(count)
					}
				}
				let messages = keys.compactMap { hashMessages[$0] }
				endpointMessages[url] = messages.isEmpty ? nil : String(messages.joined(separator: "; ").prefix(1024))
				guard !fresh.isEmpty || !cached.isEmpty else { continue }
				let response = try TrackerResponse(merging: fresh + cached, peerResponses: fresh)
				if completionPending, keys.allSatisfy({ completed.contains($0) }) { completionPending = false; completionSent = true }
				if let tier = tiers.firstIndex(where: { $0.contains(url) }) { tiers[tier].removeAll { $0 == url }; tiers[tier].insert(url, at: 0) }
				activeTracker = url
				failures = 0; lastError = nil
				next = keys.compactMap { due[$0] }.min() ?? clock.now() + 30
				return response
			} catch {
				if isCancellation(error) { throw CancellationError() }
				failure = error
				endpointMessages[url] = error.localizedDescription
			}
		}
		failures = min(failures + 1, 31); lastError = failure.localizedDescription
		next = due.values.filter { $0 > clock.now() }.min() ?? clock.now() + backoff(failures)
		throw failure
	}
	private func announce(_ counters: TrackerCounters, key: Key) async throws -> TrackerResponse {
		let event: TrackerEvent? = contacted.contains(key) ? (completionPending && !completed.contains(key) ? .completed : nil) : .started
		var message = TrackerRequest(infoHash: key.hash, peerID: request.peerID, port: request.port, counters: counters, event: event, trackerID: trackerIDs[key], wantedPeers: request.wantedPeers)
		var response = try await client.announce(to: key.url, request: message)
		record(response, key: key, event: event); try Task.checkCancellation()
		if completionPending && event == .started {
			message.event = .completed; message.trackerID = trackerIDs[key]
			response = try await client.announce(to: key.url, request: message)
			record(response, key: key, event: .completed); try Task.checkCancellation()
		}
		return response
	}
	private func record(_ response: TrackerResponse, key: Key, event: TrackerEvent?) {
		contacted.insert(key)
		if let id = response.trackerID { trackerIDs[key] = id }
		if event == .completed { completed.insert(key) }
	}
	private func backoff(_ count: Int) -> TimeInterval { min(1800, 30 * pow(2, Double(min(max(0, count - 1), 6)))) }
	private func validate(_ counters: TrackerCounters) throws {
		guard counters.uploaded >= 0, counters.downloaded >= 0, counters.left >= 0, counters.corrupt >= 0, counters.redundant >= 0 else { throw HTTPServiceError.invalid("announce counters") }
	}
}

func isCancellation(_ error: Error) -> Bool {
	error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled
}
