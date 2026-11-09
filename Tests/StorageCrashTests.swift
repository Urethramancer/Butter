import Foundation
import Darwin

@main struct StorageCrashTests {
	static func main() async throws {
		if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--writer" {
			let root = URL(fileURLWithPath: CommandLine.arguments[2]), storage = StateStorage(root: URL(fileURLWithPath: CommandLine.arguments[2]))
			for generation in 0..<10_000 {
				var state = SavedState()
				state.transfers = (0..<256).map { TransferRecord(id: "item-\($0)", source: "generation-\(generation)", destination: root.path) }
				try await storage.save(state)
				if generation == 0 { try Data().write(to: root.appendingPathComponent("ready")) }
			}
			return
		}
		let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try fm.createDirectory(at: root, withIntermediateDirectories: true)
		defer { try? fm.removeItem(at: root) }
		for iteration in 0..<8 {
			let childRoot = root.appendingPathComponent("child-\(iteration)")
			let process = Process(), done = DispatchSemaphore(value: 0)
			process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
			process.arguments = ["--writer", childRoot.path]
			process.terminationHandler = { _ in done.signal() }
			try process.run()
			defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
			let deadline = ProcessInfo.processInfo.systemUptime + 5
			while !fm.fileExists(atPath: childRoot.appendingPathComponent("ready").path) && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(10)) }
			guard fm.fileExists(atPath: childRoot.appendingPathComponent("ready").path) else { throw CocoaError(.fileReadUnknown) }
			try await Task.sleep(for: .milliseconds(5 + iteration * 3))
			kill(process.processIdentifier, SIGKILL)
			let terminated = await Task.detached { done.wait(timeout: .now() + 5) == .success }.value
			guard terminated else { throw CocoaError(.executableLoad) }
			let saved = try await StateStorage(root: childRoot).load()
			guard saved.transfers.count == 256, Set(saved.transfers.map(\.source)).count == 1 else { throw CocoaError(.coderInvalidValue) }
		}
		print("PASS: eight child-process interruptions preserve complete atomic state generations")
	}
}
