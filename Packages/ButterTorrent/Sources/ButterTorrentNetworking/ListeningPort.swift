import Foundation
import Darwin
@preconcurrency import Network

/// ListeningPort owns TCP plus IPv4/IPv6 UDP on one port, rolling back partial binds.
public final class ListeningPort: Sendable {
	public let tcp: TCPListener
	public let udp4: UDPDispatcher
	public let udp6: UDPDispatcher
	public let peers: TCPPeerBudget
	public let port: UInt16
	private init(tcp: TCPListener, udp4: UDPDispatcher, udp6: UDPDispatcher, peers: TCPPeerBudget) {
		self.tcp = tcp; self.udp4 = udp4; self.udp6 = udp6; self.peers = peers
		port = tcp.port
	}
	public static func bind(port: UInt16 = 0, maximumPeers: Int = 200, loopbackOnly: Bool = false,
		clock: any TransportClock = ContinuousTransportClock(), budget: TCPPeerBudget? = nil, incomingTCP: Bool = true) async throws -> ListeningPort {
		let budget = budget ?? TCPPeerBudget(limit: maximumPeers)
		return try await select(port: port, loopbackOnly: loopbackOnly, clock: clock, budget: budget, incomingTCP: incomingTCP) {
			try await TCPListener.listen(port: port, maximumPeers: maximumPeers, clock: clock, budget: budget, loopbackOnly: loopbackOnly)
		}
	}
	static func select(port: UInt16, loopbackOnly: Bool, clock: any TransportClock, budget: TCPPeerBudget, incomingTCP: Bool,
		listener: @Sendable () async throws -> TCPListener) async throws -> ListeningPort {
		let deadline = clock.now() + 10
		for attempt in 0..<8 {
			try Task.checkCancellation(); guard clock.now() < deadline else { throw NetworkFailure.timedOut }
			var tcp: TCPListener?, sockets: [DatagramSocket] = []
			do {
				let selected = try await listener(); tcp = selected
				let v4 = try DatagramSocket(bind: NetworkEndpoint(loopbackOnly ? "127.0.0.1" : "0.0.0.0", port: selected.port)); sockets.append(v4)
				let v6 = try DatagramSocket(bind: NetworkEndpoint(loopbackOnly ? "::1" : "::", port: selected.port)); sockets.append(v6)
				let owner = ListeningPort(tcp: selected, udp4: UDPDispatcher(transport: v4, clock: clock), udp6: UDPDispatcher(transport: v6, clock: clock), peers: budget)
				if !incomingTCP { try await selected.shutdown() }; return owner
			} catch {
				for socket in sockets { try? await socket.shutdown() }; try? await tcp?.shutdown()
				// TCP's ephemeral allocator cannot know whether UDP already owns that port.
				let collision = error as? NetworkFailure == .system(EADDRINUSE) || error as? NWError == .posix(.EADDRINUSE)
				guard port == 0, collision, attempt < 7 else { throw error }
			}
		}
		throw NetworkFailure.timedOut
	}
	public func shutdown() async throws {
		var failure: Error?
		for operation in [udp4, udp6] { do { try await operation.shutdown() } catch { failure = error } }
		do { try await tcp.shutdown() } catch { failure = error }
		if let failure { throw failure }
	}
}
