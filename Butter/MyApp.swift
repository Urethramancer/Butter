import SwiftUI
import AppKit

@main struct ButterApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
	@StateObject private var store = TransferStore()
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
		let active = store.transfers.filter { store.record($0.id)?.wanted == true && $0.state != "Paused" }
		let mode = store.preferences.quitMode
		let confirm = mode == "Always" || (mode == "Active Transfers" && !active.isEmpty) || (mode == "Active Downloads" && active.contains { !$0.complete })
		if confirm {
			let alert = NSAlert(); alert.messageText = "Quit Butter?"; alert.informativeText = "Transfers will stop. Their resume state will be saved before quitting."; alert.addButton(withTitle: "Quit"); alert.addButton(withTitle: "Cancel")
			if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
		}
		quitting = true
		Task { let saved = await store.shutdown(); quitting = false; sender.reply(toApplicationShouldTerminate: saved) }
		return .terminateLater
	}
}
