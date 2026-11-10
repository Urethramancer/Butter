import Foundation
import Darwin

public struct NetworkDatagram: Sendable {
	public let source: NetworkEndpoint
	public let payload: Data
	public init(source: NetworkEndpoint, payload: Data) { self.source = source; self.payload = Data(payload) }
}

public protocol DatagramTransport: Sendable {
	var localEndpoint: NetworkEndpoint { get }
	var datagrams: AsyncStream<NetworkDatagram> { get }
	func send(_ data: Data, to endpoint: NetworkEndpoint) async throws
	func shutdown() async throws
}

/// DatagramSocket owns one nonblocking Darwin UDP socket and a bounded single-consumer stream.
public final class DatagramSocket: DatagramTransport, @unchecked Sendable {
	public let localEndpoint: NetworkEndpoint
	public let datagrams: AsyncStream<NetworkDatagram>
	private let continuation: AsyncStream<NetworkDatagram>.Continuation
	private let fd: Int32
	private let source: DispatchSourceRead
	private let queue = DispatchQueue(label: "Butter.UDP")
	private let lock = NSLock()
	private var closed = false
	private var dropped: UInt64 = 0
	private let ended = NetworkWaiter<Void>()
	public var droppedPackets: UInt64 { lock.withLock { dropped } }
	public init(bind endpoint: NetworkEndpoint, reusePort: Bool = false) throws {
		let fd = socket(endpoint.address.isIPv6 ? AF_INET6 : AF_INET, SOCK_DGRAM, IPPROTO_UDP)
		guard fd >= 0 else { throw NetworkFailure.system(errno) }
		do {
			guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw NetworkFailure.system(errno) }
			var yes: Int32 = 1
			if endpoint.address.isIPv6 { guard setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw NetworkFailure.system(errno) } }
			if reusePort {
				guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0,
					setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw NetworkFailure.system(errno) }
			}
			guard endpoint.withSockAddr({ Darwin.bind(fd, $0, $1) }) == 0 else { throw NetworkFailure.system(errno) }
			var address = sockaddr_storage(), length = socklen_t(MemoryLayout<sockaddr_storage>.size)
			guard withUnsafeMutablePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }) == 0 else { throw NetworkFailure.system(errno) }
			localEndpoint = try NetworkEndpoint(storage: address, length: length)
		} catch { Darwin.close(fd); throw error }
		self.fd = fd
		let pair = AsyncStream<NetworkDatagram>.makeStream(bufferingPolicy: .bufferingNewest(256))
		datagrams = pair.stream; continuation = pair.continuation
		source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
		let ended = self.ended, continuation = self.continuation
		source.setCancelHandler { Darwin.close(fd); continuation.finish(); ended.resolve(.success(())) }
		source.setEventHandler { [weak self] in self?.receive() }
		source.resume()
	}
	public func send(_ data: Data, to endpoint: NetworkEndpoint) async throws {
		try Task.checkCancellation()
		guard !data.isEmpty, data.count <= 65_507, endpoint.port > 0, endpoint.address.isIPv6 == localEndpoint.address.isIPv6 else { throw NetworkFailure.invalid("UDP packet or destination") }
		let waiter = NetworkWaiter<Void>()
		queue.async { [self] in
			guard waiter.isPending else { return }
			guard !lock.withLock({ closed }) else { waiter.resolve(.failure(NetworkFailure.closed)); return }
			let count = data.withUnsafeBytes { bytes in endpoint.withSockAddr { sendto(fd, bytes.baseAddress, bytes.count, 0, $0, $1) } }
			if count == data.count { waiter.resolve(.success(())) }
			else { waiter.resolve(.failure(errno == EAGAIN || errno == EWOULDBLOCK ? NetworkFailure.backpressure : NetworkFailure.system(errno))) }
		}
		try await waiter.value(timeout: 10, clock: ContinuousTransportClock())
	}
	private func receive() {
		guard !lock.withLock({ closed }) else { return }
		var buffer = [UInt8](repeating: 0, count: 65_536)
		for _ in 0..<64 {
			var address = sockaddr_storage(), length = socklen_t(MemoryLayout<sockaddr_storage>.size)
			let count = withUnsafeMutablePointer(to: &address) { pointer in
				pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) }
			}
			if count < 0 {
				if errno == EAGAIN || errno == EWOULDBLOCK { break }
				if errno == EINTR { continue }
				close(); break
			}
			guard count > 0, count <= 65_507, let peer = try? NetworkEndpoint(storage: address, length: length) else { lock.withLock { dropped &+= 1 }; continue }
			if case .dropped = continuation.yield(NetworkDatagram(source: peer, payload: Data(buffer.prefix(count)))) { lock.withLock { dropped &+= 1 } }
		}
	}
	public func joinMulticast(_ group: IPAddress, interfaceAddress: IPAddress? = nil, interfaceIndex: UInt32 = 0, hops: UInt8 = 1) throws {
		guard group.isMulticast, group.isIPv6 == localEndpoint.address.isIPv6, !lock.withLock({ closed }) else { throw NetworkFailure.invalid("multicast group") }
		try queue.sync {
			guard !lock.withLock({ closed }) else { throw NetworkFailure.closed }
			if group.isIPv6 {
				var request = ipv6_mreq()
				request.ipv6mr_multiaddr = group.bytes.withUnsafeBytes { $0.loadUnaligned(as: in6_addr.self) }; request.ipv6mr_interface = interfaceIndex
				guard setsockopt(fd, IPPROTO_IPV6, IPV6_JOIN_GROUP, &request, socklen_t(MemoryLayout<ipv6_mreq>.size)) == 0 else { throw NetworkFailure.system(errno) }
			} else {
				var request = ip_mreq()
				request.imr_multiaddr = group.bytes.withUnsafeBytes { $0.loadUnaligned(as: in_addr.self) }
				if let interfaceAddress {
					guard !interfaceAddress.isIPv6 else { throw NetworkFailure.invalid("multicast interface") }
					request.imr_interface = interfaceAddress.bytes.withUnsafeBytes { $0.loadUnaligned(as: in_addr.self) }
				}
				guard setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &request, socklen_t(MemoryLayout<ip_mreq>.size)) == 0 else { throw NetworkFailure.system(errno) }
			}
			try configureMulticastOnQueue(interfaceAddress: interfaceAddress, interfaceIndex: interfaceIndex, hops: hops)
		}
	}
	public func configureMulticast(interfaceAddress: IPAddress, interfaceIndex: UInt32 = 0) throws {
		try queue.sync {
			guard !lock.withLock({ closed }) else { throw NetworkFailure.closed }
			try configureMulticastOnQueue(interfaceAddress: interfaceAddress, interfaceIndex: interfaceIndex)
		}
	}
	private func configureMulticastOnQueue(interfaceAddress: IPAddress?, interfaceIndex: UInt32, hops: UInt8 = 1) throws {
		guard interfaceAddress == nil || interfaceAddress?.isIPv6 == localEndpoint.address.isIPv6 else { throw NetworkFailure.invalid("multicast interface family") }
		if localEndpoint.address.isIPv6 {
			var index = interfaceIndex == 0 ? (interfaceAddress?.scope ?? 0) : interfaceIndex, hopLimit = Int32(hops)
			guard setsockopt(fd, IPPROTO_IPV6, IPV6_MULTICAST_IF, &index, socklen_t(MemoryLayout<UInt32>.size)) == 0,
				setsockopt(fd, IPPROTO_IPV6, IPV6_MULTICAST_HOPS, &hopLimit, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw NetworkFailure.system(errno) }
		} else {
			var address = interfaceAddress?.bytes.withUnsafeBytes { $0.loadUnaligned(as: in_addr.self) } ?? in_addr(), ttl = hops
			guard setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &address, socklen_t(MemoryLayout<in_addr>.size)) == 0,
				setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size)) == 0 else { throw NetworkFailure.system(errno) }
		}
	}
	public func close() { lock.withLock { closed = true }; source.cancel() }
	public func shutdown() async throws { close(); try await ended.value(timeout: 10, clock: ContinuousTransportClock()) }
	deinit { source.cancel() }
}
