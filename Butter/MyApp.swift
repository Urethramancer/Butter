import SwiftUI
import AppKit

@main struct ButterApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
	@StateObject private var store = makeStore()
	@MainActor private static func makeStore() -> TransferStore {
		#if DEBUG
		if let path = ProcessInfo.processInfo.environment["BUTTER_UI_TEST_ROOT"] {
			let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
			let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"
			// Only explicit disposable fixtures can enable integration stubs.
			if root.path.hasPrefix(temporary), FileManager.default.fileExists(atPath: root.appendingPathComponent(".butter-ui-test").path) {
				return TransferStore(root: root, allowsSystemIntegration: false)
			}
			fatalError("Invalid isolated UI test directory")
		}
		#endif
		return TransferStore()
	}
	private var colourScheme: ColorScheme? { store.preferences.appearance == "Light" ? .light : store.preferences.appearance == "Dark" ? .dark : nil }
	var body: some Scene {
		Window("Butter", id: "transfers") {
			ContentView().environmentObject(store).preferredColorScheme(colourScheme)
				.task { delegate.store = store; await store.start() }
				.onOpenURL { url in Task { await store.open(url.absoluteString) } }
		}.defaultSize(width: 1180, height: 740)
		.commands {
			CommandGroup(replacing: .newItem) {
				Button("Open Torrent…") { store.chooseTorrent() }.keyboardShortcut("o")
				Button("Add Magnet Link…") { store.showMagnet = true }.keyboardShortcut("l")
				Button("Create Torrent…") { store.showCreator = true }.keyboardShortcut("n")
			}
			CommandMenu("Transfers") {
				Button("Start Selected") { Task { await store.setRunning(store.selection, running: true) } }.disabled(store.selection.isEmpty)
				Button("Pause Selected") { Task { await store.setRunning(store.selection, running: false) } }.disabled(store.selection.isEmpty)
				Button("Force Start Selected") { Task { await store.setRunning(store.selection, running: true, force: true) } }.disabled(store.selection.isEmpty)
				Divider(); Button("Remove Selected") { Task { await store.remove(store.selection, trash: false) } }.disabled(store.selection.isEmpty)
				Button("Remove and Delete Data…", role: .destructive) { store.confirmRemoval(store.selection) }.disabled(store.selection.isEmpty)
			}
		}
		Settings { PreferencesView().environmentObject(store).preferredColorScheme(colourScheme) }
	}
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
	weak var store: TransferStore?
	private var quitting = false
	func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
		if quitting { return .terminateLater }
		guard let store else { return .terminateNow }
		let confirm = QuitPolicy.shouldConfirm(mode: store.preferences.quitMode, transfers: store.transfers, wanted: Set(store.records.filter(\.wanted).map(\.id)))
		if confirm {
			let alert = NSAlert(); alert.messageText = "Quit Butter?"; alert.informativeText = "Transfers will stop. Their resume state will be saved before quitting."; alert.addButton(withTitle: "Quit"); alert.addButton(withTitle: "Cancel")
			if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
		}
		quitting = true
		Task { let saved = await store.shutdown(); quitting = false; sender.reply(toApplicationShouldTerminate: saved) }
		return .terminateLater
	}
}
