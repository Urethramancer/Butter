import Foundation
import Network
import ButterTorrentMetadata
@testable import ButterTorrentNetworking

func bencode(_ fields: [String: BencodeValue]) throws -> Data {
	try BencodeValue.dictionary(Dictionary(uniqueKeysWithValues: fields.map { (Data($0.key.utf8), $0.value) })).encoded()
}
func trackerBody(interval: Int64 = 60, minimum: Int64 = 0) throws -> Data {
	try bencode(["interval": .integer(interval), "min interval": .integer(minimum), "peers": .bytes(Data())])
}
func trackerRequest(left: Int64 = 3) -> TrackerRequest {
	TrackerRequest(infoHash: Data(0..<20), peerID: Data(200..<220), port: 6881, counters: TrackerCounters(left: left))
}

final class TestClock: HTTPServiceClock, @unchecked Sendable {
	private let lock = NSLock()
	private var value: TimeInterval = 100
	func now() -> TimeInterval { lock.withLock { value } }
	func advance(_ amount: TimeInterval) { lock.withLock { value += amount } }
}

final class ManualTransportClock: TransportClock, @unchecked Sendable {
	let sleeps = AsyncStream<(UUID, TimeInterval)>.makeStream()
	private let lock = NSLock()
	private var time: TimeInterval = 100
	private var pending: [UUID: (TimeInterval, CheckedContinuation<Void, Error>)] = [:]
	func now() -> TimeInterval { lock.withLock { time } }
	func sleep(for seconds: TimeInterval) async throws {
		let id = UUID()
		try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
				lock.withLock {
					if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
					else { pending[id] = (time + seconds, continuation); _ = sleeps.continuation.yield((id, seconds)) }
				}
			}
		} onCancel: {
			let continuation = self.lock.withLock { self.pending.removeValue(forKey: id)?.1 }
			continuation?.resume(throwing: CancellationError())
		}
	}
	func advance(_ seconds: TimeInterval) {
		let ready = lock.withLock {
			time += seconds
			let ready = pending.filter { $0.value.0 <= time }
			for id in ready.keys { pending[id] = nil }
			return ready.values.map(\.1)
		}
		for continuation in ready { continuation.resume() }
	}
	func waitForSleep(_ seconds: TimeInterval) async throws {
		try await deadline {
			for await (id, value) in self.sleeps.stream { if value == seconds && self.lock.withLock({ self.pending[id] != nil }) { return } }
			throw NetworkFailure.invalid("clock signal ended")
		}
	}
}

actor ScriptedHTTP: HTTPTransport {
	var requests: [HTTPRequest] = []
	var responses: [Result<HTTPResponse, HTTPServiceError>]
	init(_ responses: [Result<HTTPResponse, HTTPServiceError>]) { self.responses = responses }
	func get(_ request: HTTPRequest) async throws -> HTTPResponse {
		requests.append(request)
		guard !responses.isEmpty else { throw HTTPServiceError.invalid("fixture exhausted") }
		return try responses.removeFirst().get()
	}
}

func deadline<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
	try await withThrowingTaskGroup(of: T.self) { group in
		group.addTask(operation: body)
		group.addTask { try await Task.sleep(for: .seconds(5)); throw HTTPServiceError.invalid("test deadline") }
		defer { group.cancelAll() }
		return try await group.next()!
	}
}

actor BlockingHTTP: HTTPTransport {
	let signal = AsyncStream<Int>.makeStream()
	var requests: [HTTPRequest] = []
	var pending: [UUID: CheckedContinuation<HTTPResponse, Error>] = [:]
	var cancelled = 0
	func get(_ request: HTTPRequest) async throws -> HTTPResponse {
		let id = UUID()
		return try await withTaskCancellationHandler {
			try Task.checkCancellation()
			return try await withCheckedThrowingContinuation { continuation in
				requests.append(request); pending[id] = continuation
				signal.continuation.yield(requests.count)
			}
		} onCancel: { Task { await self.cancel(id) } }
	}
	private func cancel(_ id: UUID) {
		if let continuation = pending.removeValue(forKey: id) { cancelled += 1; continuation.resume(throwing: CancellationError()) }
	}
	func release(_ response: HTTPResponse) {
		let all = pending.values; pending.removeAll()
		for continuation in all { continuation.resume(returning: response) }
	}
	func waitForRequests(_ count: Int) async throws {
		if requests.count >= count { return }
		try await deadline {
			for await value in self.signal.stream { if value >= count { return } }
			throw HTTPServiceError.invalid("request signal cancelled")
		}
	}
}

final class HTTPFixture: @unchecked Sendable {
	struct Input: Sendable {
		let target: String
		let headers: [String: String]
		let method: String
		let body: Data
	}
	struct Reply: Sendable {
		var status = 200
		var headers: [String: String] = [:]
		var body = Data()
		var chunked = false
		var hang = false
	}
	private let queue = DispatchQueue(label: "Butter.HTTPFixture")
	private let listener: NWListener
	private let host: String
	private let handler: @Sendable (Input) -> Reply
	private var connections: [UUID: NWConnection] = [:]
	private var ready: CheckedContinuation<URL, Error>?
	private var stopped = false
	private init(host: String, tls: NWProtocolTLS.Options?, handler: @escaping @Sendable (Input) -> Reply) throws {
		let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
		parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: .any)
		listener = try NWListener(using: parameters)
		self.host = host; self.handler = handler
	}
	static func start(host: String = "127.0.0.1", tls: NWProtocolTLS.Options? = nil, handler: @escaping @Sendable (Input) -> Reply) async throws -> HTTPFixture {
		let server = try HTTPFixture(host: host, tls: tls, handler: handler)
		_ = try await server.start()
		return server
	}
	var url: URL { URL(string: "http://\(host.contains(":") ? "[\(host)]" : host):\(listener.port!.rawValue)")! }
	private func start() async throws -> URL {
		try await withCheckedThrowingContinuation { continuation in
			queue.async { [self] in
				self.ready = continuation
				self.listener.stateUpdateHandler = { [weak self] state in
					guard let self else { return }
					switch state {
					case .ready: self.ready?.resume(returning: self.url); self.ready = nil
					case .failed(let error): self.ready?.resume(throwing: error); self.ready = nil; self.listener.cancel()
					default: break
					}
				}
				self.listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
				self.listener.start(queue: self.queue)
				self.queue.asyncAfter(deadline: .now() + 5) { [weak self] in
					guard let self, let ready = self.ready else { return }
					self.ready = nil; ready.resume(throwing: HTTPServiceError.invalid("fixture listen deadline")); self.listener.cancel()
				}
			}
		}
	}
	func stop() async {
		await withCheckedContinuation { continuation in
			queue.async {
				self.stopped = true; self.listener.cancel()
				for connection in self.connections.values { connection.cancel() }
				self.connections.removeAll(); continuation.resume()
			}
		}
	}
	private func accept(_ connection: NWConnection) {
		guard !stopped else { connection.cancel(); return }
		let id = UUID(); connections[id] = connection
		connection.stateUpdateHandler = { [weak self] state in
			if case .cancelled = state { self?.connections[id] = nil }
			if case .failed = state { self?.connections[id] = nil }
		}
		connection.start(queue: queue)
		receive(connection, input: Data())
	}
	private func receive(_ connection: NWConnection, input: Data) {
		connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
			guard let self else { connection.cancel(); return }
			let bytes = input + (data ?? Data())
			guard bytes.count <= 81_920 else { connection.cancel(); return }
			if let boundary = bytes.range(of: Data("\r\n\r\n".utf8)), boundary.upperBound <= 16_384,
				let text = String(data: bytes.prefix(boundary.lowerBound), encoding: .utf8) {
				let lines = text.components(separatedBy: "\r\n")
				let target = lines[0].split(separator: " ").dropFirst().first.map(String.init) ?? ""
				var headers: [String: String] = [:]
				for line in lines.dropFirst() {
					let pair = line.split(separator: ":", maxSplits: 1)
					if pair.count == 2 { headers[pair[0].lowercased()] = pair[1].trimmingCharacters(in: .whitespaces) }
				}
				let length = Int(headers["content-length"] ?? "0") ?? -1
				guard (0...65_536).contains(length) else { connection.cancel(); return }
				guard bytes.count >= boundary.upperBound + length else { self.receive(connection, input: bytes); return }
				self.send(self.handler(Input(target: target, headers: headers, method: String(lines[0].prefix { $0 != " " }), body: bytes.subdata(in: boundary.upperBound..<(boundary.upperBound + length)))), on: connection)
			} else if !complete && error == nil { self.receive(connection, input: bytes) }
			else { connection.cancel() }
		}
	}
	private func send(_ reply: Reply, on connection: NWConnection) {
		if reply.hang { return }
		var headers = reply.headers
		headers["Connection"] = "close"
		if reply.chunked { headers["Transfer-Encoding"] = "chunked" }
		else if headers["Content-Length"] == nil { headers["Content-Length"] = String(reply.body.count) }
		var data = Data(("HTTP/1.1 \(reply.status) Fixture\r\n" + headers.map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n").utf8)
		if reply.chunked {
			for start in stride(from: 0, to: reply.body.count, by: 17) {
				let chunk = reply.body.subdata(in: start..<min(start + 17, reply.body.count))
				data.append(Data("\(String(chunk.count, radix: 16))\r\n".utf8)); data.append(chunk); data.append(Data("\r\n".utf8))
			}
			data.append(Data("0\r\n\r\n".utf8))
		} else { data.append(reply.body) }
		connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
	}
}
