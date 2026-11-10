import Foundation

public enum PeerTransportKind: Sendable { case tcp, utp }

/// PeerByteStream carries ordered bytes with one reader and one writer; cancellation closes it.
public protocol PeerByteStream: AnyObject, Sendable {
	var remoteEndpoint: NetworkEndpoint? { get }
	var kind: PeerTransportKind { get }
	func read(maximumBytes: Int, timeout: TimeInterval) async throws -> Data
	func write(_ data: Data, timeout: TimeInterval) async throws
	func close()
	func shutdown() async throws
}

extension PeerByteStream {
	public func read(timeout: TimeInterval = 30) async throws -> Data { try await read(maximumBytes: 65_536, timeout: timeout) }
	public func write(_ data: Data) async throws { try await write(data, timeout: 30) }
	public func shutdown() async throws { close() }
}

extension TCPStream: PeerByteStream {
	public var kind: PeerTransportKind { .tcp }
}
