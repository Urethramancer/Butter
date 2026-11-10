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
	private var request: TrackerRequest
	private var contacted: Set<URL> = []
	private var trackerIDs: [URL: Data] = [:]
	private var phase: Phase = .idle
	private var busy = false
	private var next: TimeInterval = 0
	private var failures = 0
	private var lastError: String?
	private var initialLeft: Int64 = 0
	private var completionPending = false
	private var completionSent = false
	public init(tiers: [[URL]], request: TrackerRequest, client: any TrackerAnnouncing = HTTPTrackerClient(),
		clock: any HTTPServiceClock = MonotonicHTTPClock(), order: @Sendable ([URL]) -> [URL] = { $0.shuffled() }) throws {
		guard tiers.count <= 32, tiers.reduce(0, { $0 + $1.count }) <= 128 else { throw HTTPServiceError.limit("tracker count") }
		for url in tiers.flatMap({ $0 }) {
			if url.scheme?.lowercased() == "udp" { _ = try UDPTrackerClient.destination(url); try request.validateFields() }
			else { _ = try request.url(for: url) }
		}
		self.tiers = tiers.filter { !$0.isEmpty }.map(order)
		self.request = request; self.client = client; self.clock = clock
	}
	public var status: Status { Status(phase: phase, nextAnnounce: next, consecutiveFailures: failures, lastError: lastError) }
	@discardableResult public func start(_ counters: TrackerCounters) async throws -> TrackerResponse {
		guard !busy else { throw HTTPServiceError.busy }
		try validate(counters)
		guard phase == .idle || phase == .stopped else { throw HTTPServiceError.invalid("tracker lifecycle is already started") }
		phase = .running; initialLeft = counters.left; completionPending = false; completionSent = false
		contacted.removeAll(); trackerIDs.removeAll(); failures = 0
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
		return try await announce(counters)
	}
	public func stop(_ counters: TrackerCounters) async throws {
		guard !busy else { throw HTTPServiceError.busy }
		try validate(counters)
		phase = .stopping; busy = true; defer { busy = false }
		var failure: Error?
		for url in tiers.flatMap({ $0 }) where contacted.contains(url) {
			do {
				try Task.checkCancellation()
				var message = request; message.counters = counters; message.event = .stopped; message.wantedPeers = 0; message.trackerID = trackerIDs[url]
				_ = try await client.announce(to: url, request: message)
				try Task.checkCancellation()
				contacted.remove(url)
			} catch {
				if isCancellation(error) { throw CancellationError() }
				failure = error
			}
		}
		if let failure { lastError = failure.localizedDescription; throw failure }
		phase = .stopped; lastError = nil
	}
	private func announce(_ counters: TrackerCounters) async throws -> TrackerResponse {
		busy = true; defer { busy = false }
		var failure: Error = HTTPServiceError.invalid("no HTTP trackers")
		for tier in tiers.indices {
			for url in tiers[tier] {
				do {
					try Task.checkCancellation()
					var message = request; message.counters = counters; message.trackerID = trackerIDs[url]
					message.event = contacted.contains(url) ? (completionPending ? .completed : nil) : .started
					var response = try await client.announce(to: url, request: message)
					try Task.checkCancellation()
					contacted.insert(url)
					if let id = response.trackerID { trackerIDs[url] = id }
					if completionPending && message.event == .started {
						message.event = .completed; message.trackerID = trackerIDs[url]
						response = try await client.announce(to: url, request: message)
						try Task.checkCancellation()
						if let id = response.trackerID { trackerIDs[url] = id }
					}
					if completionPending { completionPending = false; completionSent = true }
					tiers[tier].removeAll { $0 == url }; tiers[tier].insert(url, at: 0)
					failures = 0; lastError = nil
					next = clock.now() + max(30, response.interval, response.minimumInterval)
					return response
				} catch {
					if isCancellation(error) { throw CancellationError() }
					failure = error
				}
			}
		}
		failures = min(failures + 1, 31); lastError = failure.localizedDescription
		next = clock.now() + min(1800, 30 * pow(2, Double(min(failures - 1, 6))))
		throw failure
	}
	private func validate(_ counters: TrackerCounters) throws {
		guard counters.uploaded >= 0, counters.downloaded >= 0, counters.left >= 0 else { throw HTTPServiceError.invalid("announce counters") }
	}
}

func isCancellation(_ error: Error) -> Bool {
	error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled
}
