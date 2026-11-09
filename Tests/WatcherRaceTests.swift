import Foundation

extension CoreRegressionTests {
	static func watcherRaceBoundaries() async throws {
		let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try fm.createDirectory(at: root, withIntermediateDirectories: true)
		defer { try? fm.removeItem(at: root) }
		for iteration in 0..<32 {
			for boundary in ["before-claim", "before-restore", "remove-failure", "restore-failure"] {
				let folder = root.appendingPathComponent("\(boundary)-\(iteration)")
				try fm.createDirectory(at: folder, withIntermediateDirectories: true)
				let original = folder.appendingPathComponent("fixture.torrent")
				let imported = Data([1, 2, 3]), replacement = Data([4, 5, 6]), newest = Data([7, 8, 9])
				try imported.write(to: original)
				let defaults = WatchedFileOperations()
				var operations = defaults
				if boundary == "remove-failure" || boundary == "restore-failure" {
					operations.remove = { _ in throw CocoaError(.fileWriteNoPermission) }
					if boundary == "restore-failure" {
						operations.moveExclusively = { source, target in
							if source.lastPathComponent.hasPrefix(".butter-import-") { throw CocoaError(.fileWriteNoPermission) }
							try defaults.moveExclusively(source, target)
						}
					}
				} else {
					operations.moveExclusively = { source, target in
						let claiming = source.lastPathComponent == "fixture.torrent"
						if claiming { try replacement.write(to: original, options: .atomic) }
						try defaults.moveExclusively(source, target)
						if claiming && boundary == "before-restore" { try newest.write(to: original, options: .atomic) }
					}
				}
				let watcher = FolderWatcher(operations: operations), now = Date().addingTimeInterval(10)
				_ = try await watcher.scan(folder.path, imported: [], now: now)
				let ready = try await watcher.scan(folder.path, imported: [], now: now.addingTimeInterval(4))
				try require(ready.count == 1, "Race fixture must become ready")
				var message = ""
				do { try await watcher.removeImported(ready[0]) } catch { message = error.localizedDescription }
				try require(!message.isEmpty, "Race/deletion failure must be reported at \(boundary), iteration \(iteration)")
				let remaining = try? Data(contentsOf: original)
				let retained = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".butter-import-") }
				switch boundary {
				case "before-claim": try require(remaining == replacement && retained.isEmpty, "Claimed replacement must be restored intact")
				case "before-restore":
					try require(remaining == newest && retained.count == 1, "Restoration must not overwrite a newer directory entry")
					let hidden = try Data(contentsOf: retained[0])
					try require(hidden == replacement && message.contains(retained[0].path), "Retained replacement must be intact and recoverable from the reported path")
				case "remove-failure": try require(remaining == imported && retained.isEmpty, "Failed deletion must restore the imported original")
				default:
					try require(remaining == nil && retained.count == 1, "Failed restoration must retain the claimed file")
					let hidden = try Data(contentsOf: retained[0])
					try require(hidden == imported && message.contains(retained[0].path), "Restoration errors must report the retained file location")
				}
			}
		}
	}
}
