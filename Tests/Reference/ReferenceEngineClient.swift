import Foundation

final class ReferenceEngineClient: EngineOperations, @unchecked Sendable {
	let bridge: ButterEngine
	init(storage: URL) { bridge = ButterEngine(storage: storage.path) }
	var creationProgress: Double { bridge.creationProgress }
	func cancelCreation() { bridge.cancelCreation() }
	func perform(_ command: String, _ payload: [String: Any]) async throws -> Data {
		let bytes = try JSONSerialization.data(withJSONObject: payload)
		return try await withCheckedThrowingContinuation { continuation in
			bridge.perform(command, payload: bytes) { data, error in
				if let error { continuation.resume(throwing: NSError(domain: "Butter.Reference", code: 1, userInfo: [NSLocalizedDescriptionKey: error])) }
				else { continuation.resume(returning: data ?? Data()) }
			}
		}
	}
	func snapshot() async throws -> EngineSnapshot {
		let bytes: Data = try await withCheckedThrowingContinuation { continuation in
			bridge.snapshot { data, error in
				if let error { continuation.resume(throwing: NSError(domain: "Butter.Reference", code: 1, userInfo: [NSLocalizedDescriptionKey: error])) }
				else { continuation.resume(returning: data ?? Data()) }
			}
		}
		return try JSONDecoder().decode(EngineSnapshot.self, from: bytes)
	}
}
