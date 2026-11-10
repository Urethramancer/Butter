import Foundation
import Darwin
@preconcurrency import Network

public struct NetworkInterfaceAddress: Sendable {
	public let name: String
	public let index: UInt32
	public let address: IPAddress
}
public struct NetworkEnvironmentSnapshot: Sendable {
	public let interfaces: [NetworkInterfaceAddress]
	public let gateways: [IPAddress]
}

/// NetworkEnvironment discovers interface addresses and default gateways without sending probes.
public enum NetworkEnvironment {
	public static func interfaces(includeLoopback: Bool = false) throws -> [NetworkInterfaceAddress] {
		var head: UnsafeMutablePointer<ifaddrs>?
		guard getifaddrs(&head) == 0 else { throw NetworkFailure.system(errno) }
		defer { if let head { freeifaddrs(head) } }
		var current = head, result: [NetworkInterfaceAddress] = []
		while let entry = current {
			defer { current = entry.pointee.ifa_next }
			guard entry.pointee.ifa_flags & UInt32(IFF_UP) != 0, let address = entry.pointee.ifa_addr,
				address.pointee.sa_family == AF_INET || address.pointee.sa_family == AF_INET6 else { continue }
			let length = Int(address.pointee.sa_len)
			guard length <= MemoryLayout<sockaddr_storage>.size else { continue }
			var storage = sockaddr_storage()
			withUnsafeMutableBytes(of: &storage) { $0.copyBytes(from: UnsafeRawBufferPointer(start: address, count: length)) }
			let endpoint = try NetworkEndpoint(storage: storage, length: socklen_t(length))
			guard includeLoopback || !endpoint.address.isLoopback else { continue }
			guard result.count < 256 else { throw NetworkFailure.limit("interface addresses") }
			let name = String(cString: entry.pointee.ifa_name)
			result.append(NetworkInterfaceAddress(name: name, index: if_nametoindex(name), address: endpoint.address))
		}
		return result
	}
	public static func snapshot(timeout: TimeInterval = 10) async throws -> NetworkEnvironmentSnapshot {
		let monitor = NWPathMonitor(), waiter = NetworkWaiter<NetworkEnvironmentSnapshot>()
		monitor.pathUpdateHandler = { path in
			let result = Result {
				let gateways = path.gateways.compactMap { endpoint -> IPAddress? in
					if case .hostPort(let host, _) = endpoint { return try? IPAddress(String(describing: host)) }
					return nil
				}
				return NetworkEnvironmentSnapshot(interfaces: try interfaces(), gateways: Array(Set(gateways)).sorted { $0.description < $1.description })
			}
			waiter.resolve(result)
		}
		monitor.start(queue: DispatchQueue(label: "Butter.NetworkEnvironment"))
		defer { monitor.cancel() }
		return try await waiter.value(timeout: timeout, clock: ContinuousTransportClock())
	}
	public static func sourceAddress(for endpoint: NetworkEndpoint) throws -> IPAddress {
		let fd = socket(endpoint.address.isIPv6 ? AF_INET6 : AF_INET, SOCK_DGRAM, IPPROTO_UDP)
		guard fd >= 0 else { throw NetworkFailure.system(errno) }
		defer { Darwin.close(fd) }
		guard endpoint.withSockAddr({ Darwin.connect(fd, $0, $1) }) == 0 else { throw NetworkFailure.system(errno) }
		var storage = sockaddr_storage(), length = socklen_t(MemoryLayout<sockaddr_storage>.size)
		guard withUnsafeMutablePointer(to: &storage, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }) == 0 else { throw NetworkFailure.system(errno) }
		return try NetworkEndpoint(storage: storage, length: length).address
	}
}
