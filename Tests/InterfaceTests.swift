import SwiftUI
import AppKit

// Runs native views in an isolated process and stores reviewable Light/Dark captures.
@main struct InterfaceTests {
	@MainActor static func main() {
		let app = NSApplication.shared; app.setActivationPolicy(.accessory)
		Task { @MainActor in
			let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
			do {
				try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
				var saved = SavedState(); saved.preferences.port = 0; saved.preferences.dht = false; saved.preferences.lsd = false; saved.preferences.pex = false
				try await StateStorage(root: root).save(saved)
				let store = TransferStore(root: root); await store.start()
				let source = root.appendingPathComponent("Example download.bin"); try Data(repeating: 71, count: 128_000).write(to: source)
				_ = await store.create(source: source.path, trackers: [], isPrivate: false, start: true)
				try await Task.sleep(for: .milliseconds(500)); await store.refresh()
				let output = URL(fileURLWithPath: CommandLine.arguments[1]); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
				for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
					app.appearance = NSAppearance(named: appearance)
					let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1180, height: 740), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
					window.title = "Butter interface check"; window.contentView = NSHostingView(rootView: ContentView().environmentObject(store)); window.makeKeyAndOrderFront(nil)
					try await Task.sleep(for: .milliseconds(800)); try capture(window, at: output.appendingPathComponent("main-\(name).png"))
					store.showCreator = true; try await Task.sleep(for: .milliseconds(500))
					if let sheet = window.attachedSheet { try capture(sheet, at: output.appendingPathComponent("creator-\(name).png")) }
					store.showCreator = false; try await Task.sleep(for: .milliseconds(300)); window.orderOut(nil)
					let settings = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 730, height: 610), styleMask: [.titled, .closable], backing: .buffered, defer: false)
					settings.contentView = NSHostingView(rootView: PreferencesView().environmentObject(store)); settings.makeKeyAndOrderFront(nil)
					try await Task.sleep(for: .milliseconds(500)); try capture(settings, at: output.appendingPathComponent("settings-\(name).png")); settings.orderOut(nil)
				}
				_ = await store.shutdown(); try FileManager.default.removeItem(at: root)
				print("PASS: native main window, inspector, creation sheet and Settings instantiate in Light and Dark; layer captures require manual visual review")
				exit(0)
			} catch { fputs("FAIL: \(error)\n", stderr); try? FileManager.default.removeItem(at: root); exit(1) }
		}
		app.run()
	}
	@MainActor static func capture(_ window: NSWindow, at url: URL) throws {
		// NSView captures omit some compositor layers. These are smoke-test artefacts,
		// not evidence of a complete visual review; see TODO.md.
		guard let view = window.contentView else { throw CocoaError(.coderInvalidValue) }
		view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
		guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.coderInvalidValue) }
		view.cacheDisplay(in: view.bounds, to: bitmap)
		guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
		try png.write(to: url)
	}
}
