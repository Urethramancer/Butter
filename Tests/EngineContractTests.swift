import Foundation

@main struct EngineContractTests {
	static func main() async {
		do {
			if ProcessInfo.processInfo.environment["BUTTER_TEST_SYSTEM_TRASH"] == "1" {
				try await EngineContractCases.runSystemTrash { SwiftEngineClient(storage: $0) }
				print("PASS: native app adapter moved a generated file into the system Trash and returned its exact receipt")
				return
			}
			#if BUTTER_REFERENCE_ENGINE
			try await check("reference") { ReferenceEngineClient(storage: $0) }
			#endif
			try await check("native") { SwiftEngineClient(storage: $0) }
		} catch {
			fputs("FAIL: \(error)\n", stderr)
			exit(1)
		}
	}
	static func check(_ name: String, makeEngine: (URL) -> any EngineOperations) async throws {
		do {
			try await EngineContractCases.run(makeEngine: makeEngine)
			try await EngineContractCases.runSimultaneous(makeEngine: makeEngine)
			print("PASS: shared command, snapshot, persistence and simultaneous-transfer contract against \(name)")
		}
		catch { throw EngineContractCases.Failure(description: "\(name): \(error)") }
	}
}
