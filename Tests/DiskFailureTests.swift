import Foundation
import Darwin

@main struct DiskFailureTests {
	static func main() async {
		do { try await run() } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
	}
	static func isFull(_ error: NSError) -> Bool {
		(error.domain == NSPOSIXErrorDomain && error.code == Int(ENOSPC)) ||
		(error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileWriteOutOfSpace.rawValue) ||
		(error.userInfo[NSUnderlyingErrorKey] as? NSError).map(isFull) == true
	}
	static func run() async throws {
		let fm = FileManager.default, volume = URL(fileURLWithPath: CommandLine.arguments[1])
		guard fm.fileExists(atPath: volume.appendingPathComponent(".butter-disk-test").path) else { throw CocoaError(.fileWriteNoPermission) }
		let root = volume.appendingPathComponent("state"), storage = StateStorage(root: volume.appendingPathComponent("state"))
		if CommandLine.arguments.last == "--read-only" {
			let url = root.appendingPathComponent("state.json"), original = try Data(contentsOf: root.appendingPathComponent("state.json"))
			_ = try await storage.load()
			var rejected = false
			do { try await storage.save(SavedState()) } catch {
				let error = error as NSError
				guard error.code == CocoaError.fileWriteVolumeReadOnly.rawValue || (error.domain == NSPOSIXErrorDomain && error.code == Int(EROFS)) else { throw error }
				rejected = true
			}
			guard rejected, try Data(contentsOf: url) == original else { throw CocoaError(.coderInvalidValue) }
			print("PASS: read-only volume rejects saves and preserves the last valid state")
			return
		}
		try await storage.save(SavedState())
		let url = root.appendingPathComponent("state.json"), original = try Data(contentsOf: root.appendingPathComponent("state.json"))
		let filler = volume.appendingPathComponent("filler")
		guard fm.createFile(atPath: filler.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
		let handle = try FileHandle(forWritingTo: filler)
		var full = false
		do {
			let chunk = Data(repeating: 31, count: 1_048_576)
			for _ in 0..<64 { try handle.write(contentsOf: chunk) }
		} catch { guard isFull(error as NSError) else { throw error }; full = true }
		// The filesystem may reject a large write while smaller allocations still fit.
		do {
			let chunk = Data(repeating: 17, count: 4096)
			for _ in 0..<1024 { try handle.write(contentsOf: chunk) }
		} catch { guard isFull(error as NSError) else { throw error }; full = true }
		try handle.close()
		guard full else { throw CocoaError(.fileWriteUnknown) }
		var updated = SavedState(); updated.preferences.groups = [TorrentGroup(name: String(repeating: "x", count: 500_000))]
		var rejected = false
		do { try await storage.save(updated) } catch { guard isFull(error as NSError) else { throw error }; rejected = true }
		guard rejected else { throw NSError(domain: "Butter.Tests", code: 1, userInfo: [NSLocalizedDescriptionKey: "State replacement unexpectedly succeeded on the full fixture volume"]) }
		guard try Data(contentsOf: url) == original else { throw NSError(domain: "Butter.Tests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed atomic replacement changed the last valid state"]) }
		try fm.removeItem(at: filler)
		try await storage.save(updated)
		let restored = try await storage.load()
		guard restored.preferences.groups.first?.name.count == 500_000 else { throw CocoaError(.coderInvalidValue) }
		print("PASS: actual ENOSPC preserves the last valid state and saving recovers after space is freed")
	}
}
