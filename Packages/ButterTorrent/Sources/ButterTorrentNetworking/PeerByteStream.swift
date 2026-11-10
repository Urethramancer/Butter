import Foundation

public enum PeerTransportKind: Sendable { case tcp, utp }

/// PeerByteStream carries ordered bytes with one reader and one writer; cancellation closes it.
public protocol PeerByteStream: AnyObject, Sendable {
	var remoteEndpoint: NetworkEndpoint? { get }
	var kind: PeerTransportKind { get }
	func read(maximumBytes: Int, timeout: TimeInterval) async throws -> Data
	func write(_ data: Data, timeout: TimeInterval) async throws
	func close()
}

extension TCPStream: PeerByteStream {
	public var kind: PeerTransportKind { .tcp }
}
