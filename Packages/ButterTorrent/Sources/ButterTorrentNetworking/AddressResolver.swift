import Foundation
import Darwin

public protocol AddressResolving: Sendable {
	func resolve(host: String, port: UInt16, timeout: TimeInterval) async throws -> [NetworkEndpoint]
}

/// SystemAddressResolver bounds outstanding system lookups, including cancelled DNS work.
public actor SystemAddressResolver: AddressResolving {
	private let queue = DispatchQueue(label: "Butter.DNS", attributes: .concurrent)
	private let clock: any TransportClock
	private var active = 0
	public init(clock: any TransportClock = ContinuousTransportClock()) { self.clock = clock }
	public func resolve(host: String, port: UInt16, timeout: TimeInterval = 10) async throws -> [NetworkEndpoint] {
		try Task.checkCancellation()
		guard !host.isEmpty, host.utf8.count <= 253, !host.utf8.contains(0), port > 0 else { throw NetworkFailure.invalid("DNS host or port") }
		if let address = try? IPAddress(host) { return [NetworkEndpoint(address: address, port: port)] }
		guard active < 4 else { throw NetworkFailure.limit("outstanding DNS queries") }
		active += 1
		let waiter = NetworkWaiter<[NetworkEndpoint]>()
		queue.async {
			let result = Result { try Self.lookup(host: host, port: port) }
			waiter.resolve(result)
			Task { await self.finished() }
		}
		// Cancellation returns promptly but retains the worker budget until libc finishes.
		return try await waiter.value(timeout: timeout, clock: clock)
	}
	private func finished() { active -= 1 }
	private nonisolated static func lookup(host: String, port: UInt16) throws -> [NetworkEndpoint] {
		var hints = addrinfo(), list: UnsafeMutablePointer<addrinfo>?
		hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM; hints.ai_flags = AI_NUMERICSERV
		let code = getaddrinfo(host, String(port), &hints, &list)
		guard code == 0 else { throw NetworkFailure.invalid("DNS lookup failed (\(code))") }
		defer { if let list { freeaddrinfo(list) } }
		var current = list, result: [NetworkEndpoint] = [], seen: Set<NetworkEndpoint> = []
		while let entry = current {
			defer { current = entry.pointee.ai_next }
			guard let address = entry.pointee.ai_addr, entry.pointee.ai_addrlen <= MemoryLayout<sockaddr_storage>.size else { continue }
			var storage = sockaddr_storage()
			withUnsafeMutableBytes(of: &storage) { $0.copyBytes(from: UnsafeRawBufferPointer(start: address, count: Int(entry.pointee.ai_addrlen))) }
			let endpoint = try NetworkEndpoint(storage: storage, length: entry.pointee.ai_addrlen)
			if seen.insert(endpoint).inserted {
				guard result.count < 16 else { throw NetworkFailure.limit("DNS answer count") }
				result.append(endpoint)
			}
		}
		guard !result.isEmpty else { throw NetworkFailure.invalid("empty DNS answer") }
		return result
	}
}
