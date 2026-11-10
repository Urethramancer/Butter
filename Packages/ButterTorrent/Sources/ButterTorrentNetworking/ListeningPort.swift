import Foundation

/// ListeningPort owns TCP plus IPv4/IPv6 UDP on one port, rolling back partial binds.
public final class ListeningPort: Sendable {
	public let tcp: TCPListener
	public let udp4: UDPDispatcher
	public let udp6: UDPDispatcher
	public let peers: TCPPeerBudget
	public var port: UInt16 { tcp.port }
	private init(tcp: TCPListener, udp4: UDPDispatcher, udp6: UDPDispatcher, peers: TCPPeerBudget) {
		self.tcp = tcp; self.udp4 = udp4; self.udp6 = udp6; self.peers = peers
	}
	public static func bind(port: UInt16 = 0, maximumPeers: Int = 200, loopbackOnly: Bool = false,
		clock: any TransportClock = ContinuousTransportClock()) async throws -> ListeningPort {
		let budget = TCPPeerBudget(limit: maximumPeers)
		let tcp = try await TCPListener.listen(port: port, maximumPeers: maximumPeers, clock: clock, budget: budget, loopbackOnly: loopbackOnly)
		var sockets: [DatagramSocket] = []
		do {
			let v4 = try DatagramSocket(bind: NetworkEndpoint(loopbackOnly ? "127.0.0.1" : "0.0.0.0", port: tcp.port)); sockets.append(v4)
			let v6 = try DatagramSocket(bind: NetworkEndpoint(loopbackOnly ? "::1" : "::", port: tcp.port)); sockets.append(v6)
			return ListeningPort(tcp: tcp, udp4: UDPDispatcher(transport: v4, clock: clock), udp6: UDPDispatcher(transport: v6, clock: clock), peers: budget)
		} catch {
			for socket in sockets { try? await socket.shutdown() }
			try? await tcp.shutdown()
			throw error
		}
	}
	public func shutdown() async throws {
		var failure: Error?
		for operation in [udp4, udp6] { do { try await operation.shutdown() } catch { failure = error } }
		do { try await tcp.shutdown() } catch { failure = error }
		if let failure { throw failure }
	}
}
