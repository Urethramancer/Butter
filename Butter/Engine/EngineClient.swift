import Foundation

final class EngineClient: @unchecked Sendable {
	let bridge: ButterEngine
	init(storage: URL) { bridge = ButterEngine(storage: storage.path) }
	func perform(_ command: String, _ payload: [String: Any] = [:]) async throws -> Data {
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
