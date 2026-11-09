import Foundation

@main struct EngineContractTests {
	static func main() async {
		do {
			try await EngineContractCases.run { EngineClient(storage: $0) }
			print("PASS: shared engine command, snapshot, error and persistence contract")
		} catch {
			fputs("FAIL: \(error)\n", stderr)
			exit(1)
		}
	}
}
