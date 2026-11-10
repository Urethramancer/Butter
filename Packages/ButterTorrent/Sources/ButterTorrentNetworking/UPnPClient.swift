import Foundation

public enum UPnPFailure: Error, LocalizedError, Equatable, Sendable {
	case result(Int)
	case mappingOwnedByAnotherClient
	public var errorDescription: String? {
		switch self {
		case .result(let code): "The router returned UPnP error \(code)."
		case .mappingOwnedByAnotherClient: "The router port mapping belongs to another client."
		}
	}
}

public struct UPnPService: Sendable {
	public let controlURL: URL
	public let type: String
	public let gateway: IPAddress
	public let bootID: UInt32?
	public static func load(_ candidate: UPnPCandidate, transport: any HTTPTransport = NetworkHTTPTransport()) async throws -> UPnPService {
		let response = try await transport.get(HTTPRequest(url: candidate.location, maximumResponseBytes: 1_048_576, timeout: 10, maximumRedirects: 0))
		guard response.status == 200 else { throw HTTPServiceError.status(response.status) }
		let xml = try UPnPXML.parse(response.body)
		let types = ["urn:schemas-upnp-org:service:WANIPConnection:2", "urn:schemas-upnp-org:service:WANIPConnection:1", "urn:schemas-upnp-org:service:WANPPPConnection:1"]
		guard let service = xml.services.filter({ types.contains($0.type) }).sorted(by: { types.firstIndex(of: $0.type)! < types.firstIndex(of: $1.type)! }).first else { throw NetworkFailure.invalid("UPnP WAN service missing") }
		var base = candidate.location
		if let text = xml.base {
			guard let url = URL(string: text, relativeTo: candidate.location)?.absoluteURL else { throw NetworkFailure.invalid("UPnP URLBase") }
			try HTTPURL.validate(url)
			guard (try? IPAddress(url.host ?? "")) == candidate.gateway else { throw NetworkFailure.invalid("UPnP URLBase origin") }
			base = url
		}
		guard !service.control.isEmpty else { throw NetworkFailure.invalid("UPnP control path") }
		guard let control = URL(string: service.control, relativeTo: base)?.absoluteURL else { throw NetworkFailure.invalid("UPnP control URL") }
		try HTTPURL.validate(control)
		guard let host = control.host, (try? IPAddress(host)) == candidate.gateway,
			candidate.location.scheme?.lowercased() != "https" || control.scheme?.lowercased() == "https" else { throw NetworkFailure.invalid("UPnP control origin") }
		return UPnPService(controlURL: control, type: service.type, gateway: candidate.gateway, bootID: candidate.bootID)
	}
}

/// UPnPClient maps only its own ports and verifies ownership again before renewals/removal.
public actor UPnPClient {
	private let service: UPnPService
	private let client: IPAddress
	private let transport: any HTTPTransport
	private let clock: any HTTPServiceClock
	private var mappings: [MappedTransport: PortMapping] = [:]
	private var busy = false
	private var bootID: UInt32?
	private var bootGeneration: UInt64 = 0
	public private(set) var requiresRemapping = false
	public init(service: UPnPService, internalClient: IPAddress, transport: any HTTPTransport = NetworkHTTPTransport(), clock: any HTTPServiceClock = MonotonicHTTPClock()) throws {
		guard !internalClient.isIPv6, !internalClient.isUnspecified, !internalClient.isMulticast else { throw NetworkFailure.invalid("UPnP internal client") }
		self.service = service; client = internalClient; self.transport = transport; self.clock = clock
		bootID = service.bootID
	}
	public func observeBootID(_ id: UInt32) {
		if let bootID, bootID != id {
			bootGeneration &+= 1
			requiresRemapping = true
			for (kind, mapping) in mappings { mappings[kind] = PortMapping(transport: kind, internalPort: mapping.internalPort, externalPort: mapping.externalPort, lifetime: mapping.lifetime, renewAt: 0) }
		}
		bootID = id
	}
	public func externalAddress() async throws -> IPAddress {
		guard !busy else { throw NetworkFailure.busy }; busy = true; defer { busy = false }
		let response = try await soap("GetExternalIPAddress", [])
		guard let text = response.fields["NewExternalIPAddress"] else { throw NetworkFailure.invalid("UPnP external address") }
		return try IPAddress(text)
	}
	@discardableResult public func map(_ kind: MappedTransport, internalPort: UInt16, externalPort: UInt16, lifetime: UInt32 = 3600) async throws -> PortMapping {
		guard !busy else { throw NetworkFailure.busy }; busy = true; defer { busy = false }
		guard internalPort > 0, externalPort > 0, lifetime <= 86400 else { throw NetworkFailure.invalid("UPnP mapping") }
		if let current = mappings[kind], current.internalPort != internalPort || current.externalPort != externalPort { throw NetworkFailure.invalid("remove the previous UPnP mapping before changing ports") }
		let generation = bootGeneration
		let mapping = try await add(kind, internalPort: internalPort, externalPort: externalPort, lifetime: lifetime)
		let retained = generation == bootGeneration ? mapping : due(mapping)
		mappings[kind] = retained; return retained
	}
	public func renewIfDue() async throws {
		guard !busy else { throw NetworkFailure.busy }; busy = true; defer { busy = false }
		let generation = bootGeneration
		for (kind, mapping) in mappings where clock.now() >= mapping.renewAt {
			let updated = try await add(kind, internalPort: mapping.internalPort, externalPort: mapping.externalPort, lifetime: mapping.lifetime)
			mappings[kind] = generation == bootGeneration ? updated : due(updated)
		}
		if generation == bootGeneration { requiresRemapping = false }
	}
	private func due(_ mapping: PortMapping) -> PortMapping { PortMapping(transport: mapping.transport, internalPort: mapping.internalPort, externalPort: mapping.externalPort, lifetime: mapping.lifetime, renewAt: 0) }
	public func remove(_ kind: MappedTransport) async throws {
		guard !busy else { throw NetworkFailure.busy }; busy = true; defer { busy = false }
		guard let mapping = mappings[kind] else { return }
		if try await owns(kind, internalPort: mapping.internalPort, externalPort: mapping.externalPort) {
			_ = try await soap("DeletePortMapping", identity(kind, port: mapping.externalPort))
		}
		mappings[kind] = nil
	}
	private func identity(_ kind: MappedTransport, port: UInt16) -> [(String, String)] { [("NewRemoteHost", ""), ("NewExternalPort", String(port)), ("NewProtocol", kind.rawValue)] }
	private func owns(_ kind: MappedTransport, internalPort: UInt16, externalPort: UInt16) async throws -> Bool {
		do {
			let existing = try await soap("GetSpecificPortMappingEntry", identity(kind, port: externalPort))
			guard mappings[kind]?.externalPort == externalPort, existing.fields["NewInternalClient"] == client.description,
				existing.fields["NewInternalPort"].flatMap(UInt16.init) == internalPort, existing.fields["NewPortMappingDescription"] == "Butter" else { throw UPnPFailure.mappingOwnedByAnotherClient }
			return true
		} catch UPnPFailure.result(714) { return false }
	}
	private func add(_ kind: MappedTransport, internalPort: UInt16, externalPort: UInt16, lifetime: UInt32) async throws -> PortMapping {
		_ = try await owns(kind, internalPort: internalPort, externalPort: externalPort)
		var duration = lifetime
		func arguments(_ duration: UInt32) -> [(String, String)] {
			identity(kind, port: externalPort) + [("NewInternalPort", String(internalPort)), ("NewInternalClient", client.description), ("NewEnabled", "1"), ("NewPortMappingDescription", "Butter"), ("NewLeaseDuration", String(duration))]
		}
		do { _ = try await soap("AddPortMapping", arguments(duration)) }
		catch UPnPFailure.result(725) { duration = 0; _ = try await soap("AddPortMapping", arguments(0)) }
		return PortMapping(transport: kind, internalPort: internalPort, externalPort: externalPort, lifetime: duration, renewAt: duration == 0 ? .infinity : clock.now() + TimeInterval(duration) * 0.75)
	}
	private func soap(_ action: String, _ fields: [(String, String)]) async throws -> UPnPXML {
		let arguments = fields.map { "<\($0.0)>\(UPnPXML.escape($0.1))</\($0.0)>" }.joined()
		let body = Data("<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:\(action) xmlns:u=\"\(service.type)\">\(arguments)</u:\(action)></s:Body></s:Envelope>".utf8)
		let response = try await transport.post(HTTPRequest(url: service.controlURL, headers: ["Content-Type": "text/xml; charset=\"utf-8\"", "SOAPAction": "\"\(service.type)#\(action)\""], maximumResponseBytes: 65_536, timeout: 10, maximumRedirects: 0, body: body))
		let xml = try UPnPXML.parse(response.body)
		if let code = xml.fields["errorCode"].flatMap(Int.init) { throw UPnPFailure.result(code) }
		guard response.status == 200 else { throw HTTPServiceError.status(response.status) }
		guard xml.responses[action + "Response"] == service.type else { throw NetworkFailure.invalid("UPnP action response") }
		return xml
	}
}
