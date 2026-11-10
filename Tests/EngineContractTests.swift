import Foundation

// Run the same assertions on the original bridge and the production utility adapter.
private final class ReferenceEngineClient: EngineOperations, @unchecked Sendable {
	let bridge: ButterEngine
	init(storage: URL) { bridge = ButterEngine(storage: storage.path) }
	var creationProgress: Double { bridge.creationProgress }
	func cancelCreation() { bridge.cancelCreation() }
	func perform(_ command: String, _ payload: [String: Any]) async throws -> Data {
		let bytes = try JSONSerialization.data(withJSONObject: payload)
		return try await withCheckedThrowingContinuation { continuation in
			bridge.perform(command, payload: bytes) { data, error in
				if let error { continuation.resume(throwing: EngineContractCases.Failure(description: error)) }
				else { continuation.resume(returning: data ?? Data()) }
			}
		}
	}
	func snapshot() async throws -> EngineSnapshot {
		let bytes: Data = try await withCheckedThrowingContinuation { continuation in
			bridge.snapshot { data, error in
				if let error { continuation.resume(throwing: EngineContractCases.Failure(description: error)) }
				else { continuation.resume(returning: data ?? Data()) }
			}
		}
		return try JSONDecoder().decode(EngineSnapshot.self, from: bytes)
	}
}

@main struct EngineContractTests {
	static func main() async {
		do {
			try await EngineContractCases.run { ReferenceEngineClient(storage: $0) }
			try await EngineContractCases.run { EngineClient(storage: $0) }
			try await EngineContractCases.run { SwiftEngineClient(storage: $0) }
			print("PASS: shared command, snapshot, error and persistence contract against reference, production utility adapter and native Swift session adapter")
		} catch {
			fputs("FAIL: \(error)\n", stderr)
			exit(1)
		}
	}
}
