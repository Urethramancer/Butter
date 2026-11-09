import SwiftUI
import Combine
import AppKit
import OSLog
import UserNotifications
import UniformTypeIdentifiers

struct AddRequest: Identifiable {
	var id = UUID()
	var source: String
	var preview: MetadataPreview?
	var destination: String
	var start: Bool
	var tracker = ""
	var selected: Set<Int> = []
}
@MainActor final class TransferStore: ObservableObject {
	@Published var preferences = Preferences()
	@Published var records: [TransferRecord] = []
	@Published var transfers: [TransferSnapshot] = []
	@Published var selection: Set<String> = []
	@Published var addRequest: AddRequest?
	@Published var error: String?
	@Published var networkError = ""
	@Published var portStatus = "Not checked"
	@Published var boundPort = 0
	@Published var udpBound = false
	@Published var ready = false
	@Published var creating = false
	@Published var creationProgress = 0.0
	@Published var showCreator = false
	@Published var showMagnet = false
	@Published var showInspector = true
	private let root: URL
	let engine: EngineClient
	private let storage: StateStorage
	private let watcher = FolderWatcher()
	private var scheduler = TransferScheduler()
	private var decisions: [String: ScheduleDecision] = [:]
	private var watchedImports = Set<String>()
	private var failedWatch = Set<String>()
	private var pendingAdds: [String] = []
	private var preparingAdd = false
	private var polling: Task<Void, Never>?
	private var lastSave = Date.distantPast
	private var moving = Set<String>()
	private var refreshing = false
	private var notified = Set<String>()
	private var observedErrors: [String: String] = [:]
	private let logger = Logger(subsystem: "net.grimdork.Butter", category: "errors")
	init(root: URL? = nil) {
		self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("Butter", isDirectory: true)
		storage = StateStorage(root: self.root)
		engine = EngineClient(storage: self.root.appendingPathComponent("Engine", isDirectory: true))
	}
	func start() async {
		guard !ready else { return }
		do {
			let saved = try await storage.load(); preferences = saved.preferences; records = saved.transfers; watchedImports = saved.watchedImports
			await applyNetwork()
			for record in records {
				do { _ = try await engine.perform("add", ["id": record.id, "source": record.source, "destination": record.destination, "restore": true]) }
				catch { report(error) }
			}
			ready = true
			startPolling()
			await nextAdd()
		} catch { report(error) }
	}
	func report(_ error: Error) { self.error = error.localizedDescription; logger.error("Operation failed; an actionable error was presented to the user.") }
	private func startPolling() {
		polling = Task { [weak self] in
			while !Task.isCancelled {
				await self?.refresh()
				try? await Task.sleep(for: .seconds(1))
			}
		}
	}
	@discardableResult func persist() async -> Bool {
		do { try await storage.save(SavedState(preferences: preferences, transfers: records, watchedImports: watchedImports)); return true }
		catch { report(error); return false }
	}
	func group(for torrent: TransferSnapshot) -> TorrentGroup? { TransferGrouping.group(for: torrent, groups: preferences.groups) }
	func priority(for torrent: TransferSnapshot) -> TransferPriority { TransferGrouping.priority(record(torrent.id)?.priority, torrent: torrent, groups: preferences.groups) }
	func record(_ id: String) -> TransferRecord? { records.first { $0.id == id } }
	func title(_ torrent: TransferSnapshot) -> String { record(torrent.id)?.name ?? torrent.name }
	func state(_ torrent: TransferSnapshot) -> String {
		if !torrent.error.isEmpty { return "Error — \(torrent.error)" }
		if torrent.state == "Paused", record(torrent.id)?.wanted == true { return "Queued" }
		return torrent.state
	}
	func refresh() async {
		guard !refreshing else { return }; refreshing = true; defer { refreshing = false }
		do {
			let snapshot = try await engine.snapshot()
			for transfer in snapshot.transfers where !transfer.error.isEmpty && observedErrors[transfer.id] != transfer.error { logger.error("An engine operation failed; details are visible on the transfer."); observedErrors[transfer.id] = transfer.error }
			transfers = snapshot.transfers.filter { record($0.id) != nil }; networkError = snapshot.networkError; boundPort = snapshot.port; udpBound = snapshot.udp
			for torrent in transfers where !moving.contains(torrent.id) {
				if let index = records.firstIndex(where: { $0.id == torrent.id }) { records[index].destination = torrent.path }
			}
			for event in snapshot.events {
				if event.kind == "duplicate", let existing = event.existingID {
					records.removeAll { $0.id == event.id }; selection = [existing]; decisions[existing] = nil; decisions[event.id] = nil; await persist(); continue
				}
				guard let index = records.firstIndex(where: { $0.id == event.id }) else { continue }
				if event.kind == "moved" { records[index].destination = event.path ?? records[index].destination; records[index].moved = true; records[index].moveFailed = false; moving.remove(event.id); await persist() }
				if event.kind == "moveFailed" { records[index].moveFailed = true; moving.remove(event.id); await persist() }
			}
			for torrent in transfers { await processCompletion(torrent) }
			var observations = transfers.enumerated().map { _, torrent in
				let r = record(torrent.id)
				return TransferObservation(id: torrent.id, order: records.firstIndex { $0.id == torrent.id } ?? 0, priority: priority(for: torrent), wanted: r?.wanted ?? false, force: r?.force ?? false, complete: torrent.complete, blocked: !torrent.error.isEmpty || moving.contains(torrent.id) || torrent.state == "Moving" || torrent.state == "Renaming", downloadRate: torrent.down, uploadRate: torrent.up, downloadDemand: !torrent.complete && !torrent.peers.isEmpty, uploadDemand: torrent.demand)
			}
			// Idle clocks count only admitted, running seeds, never queue time.
			let idleObservations = observations.map { observation in var o = observation; o.blocked = o.blocked || decisions[o.id]?.running != true; return o }
			let stopped = scheduler.stoppedSeeds(idleObservations, idleMinutes: preferences.idleMinutes)
			for id in stopped { if let index = records.firstIndex(where: { $0.id == id }) { records[index].wanted = false; records[index].force = false } }
			for i in observations.indices where stopped.contains(observations[i].id) { observations[i].wanted = false }
			let next = scheduler.schedule(observations, downloads: preferences.activeDownloads, seeds: preferences.activeSeeds)
			for (id, decision) in next where decisions[id] != decision {
				_ = try await engine.perform("run", ["id": id, "running": decision.running, "downloadLimit": decision.downloadLimit, "uploadLimit": decision.uploadLimit])
			}
			decisions = next
			if Date().timeIntervalSince(lastSave) > 15 {
				await persist(); lastSave = Date()
				for torrent in transfers { _ = try await engine.perform("save", ["id": torrent.id]) }
			}
			await scanWatchFolder()
		} catch { report(error) }
	}
	private func processCompletion(_ torrent: TransferSnapshot) async {
		guard let record = record(torrent.id), torrent.complete && torrent.metadata && torrent.error.isEmpty else { return }
		if !notified.contains(torrent.id) && !record.completionHandled { notified.insert(torrent.id); notify(torrent) }
		let requiresMove = !record.creation && !preferences.finalFolder.isEmpty && URL(fileURLWithPath: torrent.path).standardizedFileURL.path != URL(fileURLWithPath: preferences.finalFolder).standardizedFileURL.path
		if requiresMove && !record.moved && !record.moveFailed && !moving.contains(torrent.id) {
			moving.insert(torrent.id)
			do { _ = try await engine.perform("move", ["id": torrent.id, "destination": preferences.finalFolder]) }
			catch { moving.remove(torrent.id); if let i = records.firstIndex(where: { $0.id == torrent.id }) { records[i].moveFailed = true }; report(error) }
		}
		guard let index = records.firstIndex(where: { $0.id == torrent.id }) else { return }
		if !requiresMove || records[index].moved {
			if preferences.autoRemove && !records[index].creation { await remove([torrent.id], trash: false); return }
			records[index].completionHandled = true
		}
		if TransferStoppingPolicy.reachedRatio(torrent, limit: preferences.ratioLimit) { records[index].wanted = false; records[index].force = false }
	}
	func applyNetwork() async {
		do {
			_ = try await engine.perform("settings", ["utp": preferences.utp, "port": preferences.port, "peers": max(1, preferences.peers), "torrentPeers": max(1, preferences.torrentPeers), "dht": preferences.dht, "pex": preferences.pex, "lsd": preferences.lsd])
			let ranges = Blocklist.merge(preferences.blocklists.flatMap(\.ranges))
			_ = try await engine.perform("blocklist", ["ranges": ranges.map { ["first": $0.first, "last": $0.last] }])
		} catch { report(error) }
	}
	func settingsChanged(from old: Preferences) async {
		await persist()
		if old.utp != preferences.utp || old.port != preferences.port || old.peers != preferences.peers || old.torrentPeers != preferences.torrentPeers || old.dht != preferences.dht || old.pex != preferences.pex || old.lsd != preferences.lsd || old.blocklists != preferences.blocklists { await applyNetwork() }
		if preferences.notifications && !old.notifications {
			do { _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) } catch { report(error) }
		}
		decisions = [:]
	}
	func chooseTorrent() {
		let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "torrent") ?? .data]; panel.allowsMultipleSelection = true
		panel.begin { result in if result == .OK { Task { @MainActor in for url in panel.urls { await self.open(url.absoluteString) } } } }
	}
	func open(_ value: String) async {
		let source = value.hasPrefix("magnet:") ? value : (URL(string: value)?.isFileURL == true ? URL(string: value)!.path : value)
		pendingAdds.append(source); await nextAdd()
	}
	private func nextAdd() async {
		guard ready && !preparingAdd && addRequest == nil && !showMagnet && !showCreator && !pendingAdds.isEmpty else { return }
		preparingAdd = true; defer { preparingAdd = false }
		while !pendingAdds.isEmpty {
			let source = pendingAdds.removeFirst()
			do {
				var preview: MetadataPreview?
				if !source.hasPrefix("magnet:") { preview = try JSONDecoder().decode(MetadataPreview.self, from: await engine.perform("inspect", ["source": source])) }
				addRequest = AddRequest(source: source, preview: preview, destination: preferences.incompleteFolder, start: preferences.startOnAdd, selected: Set(preview?.files.filter { !$0.pad }.map(\.index) ?? [])); return
			} catch { report(error) }
		}
	}
	func dismissAdd() { addRequest = nil; Task { await nextAdd() } }
	func presentPendingAdd() async { await nextAdd() }
	func add(_ request: AddRequest, creation: Bool = false, id: String = UUID().uuidString) async -> Bool {
		do {
			var payload: [String: Any] = ["id": id, "source": request.source, "destination": request.destination, "tracker": request.tracker]
			if let preview = request.preview { payload["selected"] = preview.files.map { request.selected.contains($0.index) ? 1 : 0 } }
			let result = try JSONSerialization.jsonObject(with: await engine.perform("add", payload)) as? [String: Any]
			let addedID = result?["id"] as? String ?? id
			selection = [addedID]
			if result?["duplicate"] as? Bool == true { return false }
			let storedSource = request.source.hasPrefix("magnet:") ? request.source : root.appendingPathComponent("Engine/\(id).torrent").path
			records.append(TransferRecord(id: id, source: storedSource, destination: request.destination, wanted: request.start, creation: creation))
			guard await persist() else { return false }; decisions[id] = nil; return true
		} catch { report(error); return false }
	}
	func setRunning(_ ids: Set<String>, running: Bool, force: Bool = false) async {
		for i in records.indices where ids.contains(records[i].id) { records[i].wanted = running; records[i].force = force; decisions[records[i].id] = nil }
		if !running { for id in ids { await command("pause", id: id) } }
		else { for id in ids { await command("retry", id: id) } }
		await persist()
	}
	func setPriority(_ value: TransferPriority?, ids: Set<String>) async {
		for i in records.indices where ids.contains(records[i].id) { records[i].priority = value }
		decisions = [:]; await persist()
	}
	func command(_ command: String, id: String, extra: [String: Any] = [:]) async {
		do { var p = extra; p["id"] = id; _ = try await engine.perform(command, p); decisions[id] = nil } catch { report(error) }
	}
	func remove(_ ids: Set<String>, trash: Bool) async {
		for id in ids {
			do { _ = try await engine.perform("remove", ["id": id, "trash": trash]); records.removeAll { $0.id == id }; transfers.removeAll { $0.id == id }; selection.remove(id); decisions[id] = nil; await persist() }
			catch { report(error) }
		}
	}
	func confirmRemoval(_ ids: Set<String>) {
		let alert = NSAlert(); alert.messageText = "Move downloaded files to Trash?"; alert.informativeText = "Only the selected torrents’ managed files will be moved to Trash. Other files in their destination folders will be kept."; alert.alertStyle = .warning
		alert.addButton(withTitle: "Move to Trash"); alert.addButton(withTitle: "Cancel")
		if alert.runModal() == .alertFirstButtonReturn { Task { await remove(ids, trash: true) } }
	}
	func reveal(_ torrent: TransferSnapshot) { let files = torrent.files.filter { !$0.pad }.map { URL(fileURLWithPath: torrent.path).appendingPathComponent($0.path) }; NSWorkspace.shared.activateFileViewerSelecting(files.isEmpty ? [URL(fileURLWithPath: torrent.path)] : files) }
	func copyMagnet(_ id: String) async {
		do { let value = try JSONSerialization.jsonObject(with: await engine.perform("magnet", ["id": id])) as? [String: String]; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value?["magnet"] ?? "", forType: .string) } catch { report(error) }
	}
	func export(_ torrent: TransferSnapshot) {
		let panel = NSSavePanel(); panel.nameFieldStringValue = title(torrent) + ".torrent"
		panel.begin { response in guard response == .OK, let url = panel.url else { return }; Task { @MainActor in
			do { let data = try await self.engine.perform("export", ["id": torrent.id]); try await Task.detached { try data.write(to: url, options: .atomic) }.value } catch { self.report(error) }
		} }
	}
	func renameTorrent(_ torrent: TransferSnapshot) {
		let field = NSTextField(string: title(torrent)); field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
		let alert = NSAlert(); alert.messageText = "Rename transfer"; alert.informativeText = "This changes the display name."; alert.accessoryView = field; alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel")
		if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty, let i = records.firstIndex(where: { $0.id == torrent.id }) { records[i].name = field.stringValue; Task { await persist() } }
	}
	func renamePath(_ path: String, torrent: TransferSnapshot) {
		let field = NSTextField(string: (path as NSString).lastPathComponent); field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
		let alert = NSAlert(); alert.messageText = "Rename local contents"; alert.informativeText = "Original torrent names and swarm identity are preserved. Transfers pause while the engine renames files."; alert.accessoryView = field; alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel")
		guard alert.runModal() == .alertFirstButtonReturn else { return }
		let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains(":") else { error = "Choose a single safe file or folder name."; return }
		let parent = (path as NSString).deletingLastPathComponent
		let replacement = parent.isEmpty ? name : parent + "/" + name
		let changes = torrent.files.filter { $0.path == path || $0.path.hasPrefix(path + "/") }.map { ["index": $0.index, "path": replacement + String($0.path.dropFirst(path.count))] as [String: Any] }
		Task { await command("rename", id: torrent.id, extra: ["changes": changes]) }
	}
	func retryMove(_ torrent: TransferSnapshot) async {
		guard !preferences.finalFolder.isEmpty else { error = "Choose a completed-download destination in Transfers settings."; return }
		moving.insert(torrent.id)
		do { _ = try await engine.perform("move", ["id": torrent.id, "destination": preferences.finalFolder]) } catch { moving.remove(torrent.id); report(error) }
	}
	func create(source: String, trackers: [String], isPrivate: Bool, start: Bool) async -> Bool {
		creating = true; creationProgress = 0
		let progressTask = Task { while !Task.isCancelled { creationProgress = engine.bridge.creationProgress; try? await Task.sleep(for: .milliseconds(200)) } }
		defer { progressTask.cancel(); creating = false }
		do {
			let id = UUID().uuidString
			let result = try JSONSerialization.jsonObject(with: await engine.perform("create", ["id": id, "source": source, "trackers": trackers, "private": isPrivate])) as? [String: String]
			guard let file = result?["source"], let destination = result?["destination"] else { return false }
			return await add(AddRequest(source: file, destination: destination, start: start), creation: true, id: id)
		} catch { report(error); return false }
	}
	private func scanWatchFolder() async {
		do {
			let files = try await watcher.scan(preferences.watchFolder, imported: watchedImports.union(failedWatch))
			for file in files {
				let imported = await add(AddRequest(source: file.url.path, destination: preferences.incompleteFolder, start: preferences.startOnAdd))
				if imported { watchedImports.insert(file.signature); await persist(); if preferences.deleteOriginal { do { try await Task.detached { try FileManager.default.removeItem(at: file.url) }.value } catch { report(error) } } }
				else { failedWatch.insert(file.signature) }
			}
		} catch { if networkError != error.localizedDescription { networkError = "Watched folder unavailable: \(error.localizedDescription)" } }
	}
	private func notify(_ torrent: TransferSnapshot) {
		guard preferences.notifications else { return }
		let content = UNMutableNotificationContent(); content.title = "Download completed"; content.body = title(torrent)
		Task { do { try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: torrent.id, content: content, trigger: nil)) } catch { report(error) } }
	}
	func shutdown() async -> Bool {
		if creating { engine.bridge.cancelCreation() }
		let finishing = polling; finishing?.cancel(); polling = nil
		await finishing?.value
		guard await persist() else { startPolling(); return false }
		do { _ = try await engine.perform("shutdown"); return true } catch { report(error); decisions = [:]; startPolling(); return false }
	}
}
