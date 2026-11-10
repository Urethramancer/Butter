import Foundation
import Darwin
import ButterTorrentMetadata

public enum TrackerEvent: String, Sendable { case started, completed, stopped }

/// TrackerCounters records payload bytes and remaining verified work for an announce.
public struct TrackerCounters: Sendable {
	public let uploaded: Int64
	public let downloaded: Int64
	public let left: Int64
	public let corrupt: Int64
	public let redundant: Int64
	public init(uploaded: Int64 = 0, downloaded: Int64 = 0, left: Int64, corrupt: Int64 = 0, redundant: Int64 = 0) {
		self.uploaded = uploaded; self.downloaded = downloaded; self.left = left
		self.corrupt = corrupt; self.redundant = redundant
	}
}

/// TrackerRequest announces one swarm: v1 SHA-1 or the 20-byte prefix of v2 SHA-256.
public struct TrackerRequest: Sendable {
	public let infoHash: Data
	public let peerID: Data
	public let port: UInt16
	public var counters: TrackerCounters
	public var event: TrackerEvent?
	public var trackerID: Data?
	public var wantedPeers: Int
	public init(infoHash: Data, peerID: Data, port: UInt16, counters: TrackerCounters,
		event: TrackerEvent? = nil, trackerID: Data? = nil, wantedPeers: Int = 50) {
		self.infoHash = infoHash; self.peerID = peerID; self.port = port; self.counters = counters
		self.event = event; self.trackerID = trackerID; self.wantedPeers = wantedPeers
	}
	public func url(for tracker: URL) throws -> URL {
		try HTTPURL.validate(tracker, tracker: true)
		return try announceURL(for: tracker)
	}
	func announceURL(for tracker: URL) throws -> URL {
		try validateFields()
		var fields = [
			("info_hash", HTTPURL.encode(infoHash)), ("peer_id", HTTPURL.encode(peerID)), ("port", String(port)),
			("uploaded", String(counters.uploaded)), ("downloaded", String(counters.downloaded)),
			("left", String(counters.left)), ("corrupt", String(counters.corrupt)), ("redundant", String(counters.redundant)), ("compact", "1"), ("numwant", String(wantedPeers))
		]
		if let event { fields.append(("event", event.rawValue)) }
		if let trackerID { fields.append(("trackerid", HTTPURL.encode(trackerID))) }
		return try HTTPURL.query(tracker, fields: fields, reserved: ["info_hash", "peer_id", "port", "uploaded", "downloaded", "left", "corrupt", "redundant", "compact", "numwant", "event", "trackerid", "ip", "ipv4", "ipv6", "key", "supportcrypto", "no_peer_id"])
	}
	func validateFields() throws {
		guard infoHash.count == 20, peerID.count == 20, port > 0, counters.uploaded >= 0,
			counters.downloaded >= 0, counters.left >= 0, counters.corrupt >= 0, counters.redundant >= 0, (0...200).contains(wantedPeers),
			(trackerID?.count ?? 0) <= 1024 else { throw HTTPServiceError.invalid("announce fields") }
	}
}

/// TrackerPeer holds a validated numeric IPv4 or IPv6 endpoint.
public struct TrackerPeer: Hashable, Sendable {
	public let address: String
	public let port: UInt16
	public init(address: String, port: UInt16) throws {
		guard port > 0 else { throw HTTPServiceError.invalid("peer port") }
		var v4 = in_addr(), v6 = in6_addr()
		let family: Int32
		if inet_pton(AF_INET, address, &v4) == 1 { family = AF_INET }
		else if inet_pton(AF_INET6, address, &v6) == 1 { family = AF_INET6 }
		else { throw HTTPServiceError.invalid("peer IP address") }
		var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
		if family == AF_INET { _ = inet_ntop(family, &v4, &buffer, socklen_t(buffer.count)) }
		else { _ = inet_ntop(family, &v6, &buffer, socklen_t(buffer.count)) }
		self.address = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self); self.port = port
	}
}

/// TrackerResponse decodes compact IPv4/IPv6 and dictionary peer lists within fixed bounds.
public struct TrackerResponse: Sendable {
	public let interval: TimeInterval
	public let minimumInterval: TimeInterval
	public let peers: [TrackerPeer]
	public let trackerID: Data?
	public let warning: String?
	public let complete: Int64?
	public let incomplete: Int64?
	public init(_ data: Data, maximumPeers: Int = 2000) throws {
		guard (0...10_000).contains(maximumPeers) else { throw HTTPServiceError.invalid("peer response limit") }
		let root = try BencodeDocument(data, limits: .init(bytes: 1_048_576, depth: 12, values: 60_000)).root
		guard root.dictionary != nil else { throw HTTPServiceError.invalid("tracker response dictionary") }
		if let failure = root["failure reason"] {
			guard let text = failure.text else { throw HTTPServiceError.invalid("tracker failure reason") }
			throw HTTPServiceError.trackerFailure(String(text.prefix(1024)))
		}
		guard let interval = root["interval"]?.integer, (1...604_800).contains(interval) else { throw HTTPServiceError.invalid("announce interval") }
		if let node = root["min interval"], node.integer == nil { throw HTTPServiceError.invalid("minimum announce interval") }
		let minimum = root["min interval"]?.integer ?? 0
		guard (0...604_800).contains(minimum) else { throw HTTPServiceError.invalid("minimum announce interval") }
		var peers: [TrackerPeer] = []
		func append(_ peer: TrackerPeer) throws {
			guard peers.count < maximumPeers else { throw HTTPServiceError.limit("tracker peer count") }
			peers.append(peer)
		}
		func compact(_ data: Data, ipv6: Bool) throws {
			let width = ipv6 ? 18 : 6
			guard data.count % width == 0, data.count / width <= maximumPeers - peers.count else { throw HTTPServiceError.invalid("compact peer list length") }
			let bytes = [UInt8](data)
			for offset in stride(from: 0, to: bytes.count, by: width) {
				let port = UInt16(bytes[offset + width - 2]) << 8 | UInt16(bytes[offset + width - 1])
				let address: String
				if ipv6 {
					address = stride(from: offset, to: offset + 16, by: 2).map { String(UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]), radix: 16) }.joined(separator: ":")
				} else { address = bytes[offset..<offset + 4].map(String.init).joined(separator: ".") }
				try append(TrackerPeer(address: address, port: port))
			}
		}
		if let node = root["peers"] {
			if let bytes = node.bytes { try compact(bytes, ipv6: false) }
			else if let list = node.list {
				guard list.count <= maximumPeers else { throw HTTPServiceError.limit("tracker peer count") }
				for entry in list {
					guard let address = entry["ip"]?.text, let port = entry["port"]?.integer, (1...65535).contains(port) else { throw HTTPServiceError.invalid("dictionary peer") }
					if let id = entry["peer id"], id.bytes?.count != 20 { throw HTTPServiceError.invalid("peer identifier") }
					try append(TrackerPeer(address: address, port: UInt16(port)))
				}
			} else { throw HTTPServiceError.invalid("peer list") }
		}
		if let node = root["peers6"] {
			guard let bytes = node.bytes else { throw HTTPServiceError.invalid("IPv6 peer list") }
			try compact(bytes, ipv6: true)
		}
		var seen: Set<TrackerPeer> = []
		self.peers = peers.filter { seen.insert($0).inserted }
		self.interval = TimeInterval(interval); minimumInterval = TimeInterval(minimum)
		if let node = root["tracker id"] {
			guard let id = node.bytes, id.count <= 1024 else { throw HTTPServiceError.invalid("tracker identifier") }
			trackerID = id
		} else { trackerID = nil }
		if let node = root["warning message"] {
			guard let text = node.text else { throw HTTPServiceError.invalid("tracker warning") }
			warning = String(text.prefix(1024))
		} else { warning = nil }
		func counter(_ key: String) throws -> Int64? {
			guard let node = root[key] else { return nil }
			guard let value = node.integer, value >= 0 else { throw HTTPServiceError.invalid("tracker counter") }
			return value
		}
		complete = try counter("complete"); incomplete = try counter("incomplete")
	}
	// Keep the representative reply's fields; the announcer owns per-identity timing.
	init(merging responses: [TrackerResponse], peerResponses: [TrackerResponse]) throws {
		guard let first = responses.first, responses.count <= 2, peerResponses.count <= 2 else { throw HTTPServiceError.invalid("combined tracker response") }
		interval = first.interval; minimumInterval = first.minimumInterval; trackerID = first.trackerID
		warning = first.warning; complete = first.complete; incomplete = first.incomplete
		var seen: Set<TrackerPeer> = [], merged: [TrackerPeer] = []
		let truncated = peerResponses.reduce(0) { $0 + $1.peers.count } > 2000
		let lists = peerResponses.map { truncated ? $0.peers.shuffled() : $0.peers }
		for index in 0..<(lists.map(\.count).max() ?? 0) {
			for list in lists where index < list.count && merged.count < 2000 {
				if seen.insert(list[index]).inserted { merged.append(list[index]) }
			}
			if merged.count == 2000 { break }
		}
		peers = merged
	}
}

public protocol TrackerAnnouncing: Sendable {
	func announce(to tracker: URL, request: TrackerRequest) async throws -> TrackerResponse
}

/// HTTPTrackerClient implements bounded HTTP/HTTPS announces independently of the engine.
public struct HTTPTrackerClient: TrackerAnnouncing {
	private let transport: any HTTPTransport
	public init(transport: any HTTPTransport = NetworkHTTPTransport()) { self.transport = transport }
	public func announce(to tracker: URL, request: TrackerRequest) async throws -> TrackerResponse {
		try Task.checkCancellation()
		let response = try await transport.get(HTTPRequest(url: request.url(for: tracker), trackerAnnounce: true))
		try Task.checkCancellation()
		guard response.status == 200 else { throw HTTPServiceError.status(response.status) }
		return try TrackerResponse(response.body)
	}
}
