import Foundation

/// PeerSwarmCatalog bounds and indexes the swarm candidates for incoming MSE routing.
public struct PeerSwarmCatalog: Sendable {
	private let requested: [Data: Data]
	public init(hashes: [Data]) throws {
		guard (1...20_000).contains(hashes.count), hashes.allSatisfy({ $0.count == 20 }) else { throw NetworkFailure.invalid("MSE swarm candidates") }
		var index: [Data: Data] = [:]
		for hash in hashes {
			let key = mseHash("req2", hash)
			guard index[key] == nil || index[key] == hash else { throw NetworkFailure.invalid("ambiguous MSE swarm") }; index[key] = hash
		}
		requested = index
	}
	func resolve(_ request: Data) -> Data? { requested[request] }
}
