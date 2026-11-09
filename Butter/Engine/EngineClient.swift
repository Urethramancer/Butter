import Foundation

protocol EngineOperations: Sendable {
	func perform(_ command: String, _ payload: [String: Any]) async throws -> Data
	func snapshot() async throws -> EngineSnapshot
	var creationProgress: Double { get }
	func cancelCreation()
}
extension EngineOperations {
	func perform(_ command: String) async throws -> Data { try await perform(command, [:]) }
}
final class EngineClient: EngineOperations, @unchecked Sendable {
	let bridge: ButterEngine
	private let metadata = MetadataInspectionWorker()
	init(storage: URL) { bridge = ButterEngine(storage: storage.path) }
	var creationProgress: Double { bridge.creationProgress }
	func cancelCreation() { bridge.cancelCreation() }
	func perform(_ command: String, _ payload: [String: Any] = [:]) async throws -> Data {
		do {
			if command == "inspect" {
				guard let source = payload["source"] as? String, !source.isEmpty, !source.utf8.contains(0) else {
					throw MetadataError.invalid("a torrent path is required")
				}
				return try await metadata.inspect(URL(fileURLWithPath: source))
			}
			if command == "magnet" {
				let data = try await bridgePerform("magnetFields", payload)
				let fields = try JSONDecoder().decode(MagnetFields.self, from: data)
				let magnet = Magnet(hashes: try InfoHashes(hex: fields.hashes), name: fields.name, trackers: fields.trackers)
				return try JSONEncoder().encode(["magnet": magnet.uri])
			}
			return try await bridgePerform(command, payload)
		} catch {
			throw NSError(domain: "Butter.Engine", code: 1, userInfo: [NSLocalizedDescriptionKey: error.localizedDescription])
		}
	}
	private struct MagnetFields: Decodable { let hashes: [String]; let name: String; let trackers: [String] }
	private func bridgePerform(_ command: String, _ payload: [String: Any]) async throws -> Data {
		let input = try JSONSerialization.data(withJSONObject: payload)
		return try await withCheckedThrowingContinuation { continuation in
			bridge.perform(command, payload: input) { data, error in
				if let error { continuation.resume(throwing: NSError(domain: "Butter.Engine", code: 1, userInfo: [NSLocalizedDescriptionKey: error])) }
				else { continuation.resume(returning: data ?? Data()) }
			}
		}
	}
	func snapshot() async throws -> EngineSnapshot {
		let data: Data = try await withCheckedThrowingContinuation { continuation in
			bridge.snapshot { data, error in
				if let error { continuation.resume(throwing: NSError(domain: "Butter.Engine", code: 1, userInfo: [NSLocalizedDescriptionKey: error])) }
				else { continuation.resume(returning: data ?? Data()) }
			}
		}
		return try JSONDecoder().decode(EngineSnapshot.self, from: data)
	}
}

// Serialise bounded metadata reads/hashing away from the app's main actor.
private actor MetadataInspectionWorker {
	func inspect(_ url: URL) throws -> Data {
		try Task.checkCancellation()
		return try JSONEncoder().encode(TorrentMetadata(contentsOf: url).inspection)
	}
}
