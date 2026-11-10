import Foundation
import Darwin

public enum NetworkFailure: Error, LocalizedError, Equatable, Sendable {
	case invalid(String)
	case limit(String)
	case system(Int32)
	case closed
	case busy
	case timedOut
	case backpressure
	public var errorDescription: String? {
		switch self {
		case .invalid(let reason): "Invalid network operation: \(reason)."
		case .limit(let reason): "Network operation exceeded the \(reason) limit."
		case .system(let code): "Network operation failed: \(String(cString: strerror(code)))."
		case .closed: "The network transport is closed."
		case .busy: "A network operation is already in progress."
		case .timedOut: "The network operation timed out."
		case .backpressure: "The network send buffer is full."
		}
	}
}

/// IPAddress stores canonical numeric addresses, including an IPv6 interface scope.
public struct IPAddress: Hashable, Sendable, CustomStringConvertible {
	public let bytes: Data
	public let scope: UInt32
	public var isIPv6: Bool { bytes.count == 16 }
	public init(_ text: String) throws {
		var host = text.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
		var scope: UInt32 = 0
		if let marker = host.lastIndex(of: "%") {
			let name = String(host[host.index(after: marker)...]); host = String(host[..<marker])
			scope = UInt32(name) ?? if_nametoindex(name)
			guard scope > 0 else { throw NetworkFailure.invalid("IPv6 scope") }
		}
		var v4 = in_addr(), v6 = in6_addr()
		if inet_pton(AF_INET, host, &v4) == 1, scope == 0 {
			try self.init(bytes: withUnsafeBytes(of: &v4) { Data($0) })
		} else if inet_pton(AF_INET6, host, &v6) == 1 {
			try self.init(bytes: withUnsafeBytes(of: &v6) { Data($0) }, scope: scope)
		} else { throw NetworkFailure.invalid("numeric IP address") }
	}
	public init(bytes: Data, scope: UInt32 = 0) throws {
		guard bytes.count == 4 || bytes.count == 16, bytes.count == 16 || scope == 0 else { throw NetworkFailure.invalid("IP address bytes") }
		let bytes = Data(bytes)
		if bytes.count == 16 && bytes.prefix(10).allSatisfy({ $0 == 0 }) && bytes[10] == 255 && bytes[11] == 255 {
			self.bytes = bytes.subdata(in: 12..<16); self.scope = 0
		} else { self.bytes = bytes; self.scope = scope }
	}
	public var description: String {
		var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
		_ = bytes.withUnsafeBytes { inet_ntop(isIPv6 ? AF_INET6 : AF_INET, $0.baseAddress, &buffer, socklen_t(buffer.count)) }
		let host = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
		return scope == 0 ? host : "\(host)%\(scope)"
	}
	private var translatedIPv4: IPAddress? {
		guard isIPv6 else { return nil }
		let nat64: [UInt8] = [0, 100, 255, 155, 0, 0, 0, 0, 0, 0, 0, 0]
		guard bytes.prefix(12).allSatisfy({ $0 == 0 }) || bytes.prefix(12).elementsEqual(nat64) else { return nil }
		return try? IPAddress(bytes: bytes.subdata(in: 12..<16))
	}
	public var isLoopback: Bool { isIPv6 ? translatedIPv4?.isLoopback == true || (bytes.prefix(15).allSatisfy({ $0 == 0 }) && bytes[15] == 1) : bytes[0] == 127 }
	public var isUnspecified: Bool { bytes.allSatisfy { $0 == 0 } }
	public var isMulticast: Bool { isIPv6 ? bytes[0] == 255 : bytes[0] & 0xf0 == 0xe0 }
	public var isLocal: Bool {
		if isLoopback || isUnspecified || isMulticast { return true }
		if isIPv6 { return translatedIPv4?.isLocal == true || bytes[0] & 0xfe == 0xfc || (bytes[0] == 0xfe && bytes[1] & 0x80 != 0) }
		return bytes[0] == 0 || bytes[0] == 10 || bytes[0] >= 240 || (bytes[0] == 169 && bytes[1] == 254)
			|| (bytes[0] == 172 && (16...31).contains(bytes[1])) || (bytes[0] == 192 && bytes[1] == 168)
			|| (bytes[0] == 100 && (64...127).contains(bytes[1]))
	}
}

/// NetworkEndpoint pairs a numeric IP address with a TCP or UDP port.
public struct NetworkEndpoint: Hashable, Sendable, CustomStringConvertible {
	public let address: IPAddress
	public let port: UInt16
	public init(address: IPAddress, port: UInt16) { self.address = address; self.port = port }
	public init(_ host: String, port: UInt16) throws { self.init(address: try IPAddress(host), port: port) }
	public var description: String { address.isIPv6 ? "[\(address)]:\(port)" : "\(address):\(port)" }
	func withSockAddr<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) rethrows -> T {
		if address.isIPv6 {
			var value = sockaddr_in6()
			value.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size); value.sin6_family = sa_family_t(AF_INET6)
			value.sin6_port = port.bigEndian; value.sin6_scope_id = address.scope
			value.sin6_addr = address.bytes.withUnsafeBytes { $0.loadUnaligned(as: in6_addr.self) }
			return try withUnsafePointer(to: &value) { try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
		}
		var value = sockaddr_in()
		value.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); value.sin_family = sa_family_t(AF_INET)
		value.sin_port = port.bigEndian; value.sin_addr = address.bytes.withUnsafeBytes { $0.loadUnaligned(as: in_addr.self) }
		return try withUnsafePointer(to: &value) { try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
	}
	init(storage: sockaddr_storage, length: socklen_t) throws {
		var storage = storage
		if storage.ss_family == AF_INET, length >= MemoryLayout<sockaddr_in>.size {
			var value = withUnsafePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee } }
			self.init(address: try IPAddress(bytes: withUnsafeBytes(of: &value.sin_addr) { Data($0) }), port: UInt16(bigEndian: value.sin_port))
		} else if storage.ss_family == AF_INET6, length >= MemoryLayout<sockaddr_in6>.size {
			var value = withUnsafePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee } }
			self.init(address: try IPAddress(bytes: withUnsafeBytes(of: &value.sin6_addr) { Data($0) }, scope: value.sin6_scope_id), port: UInt16(bigEndian: value.sin6_port))
		} else { throw NetworkFailure.invalid("socket address family or length") }
	}
}
