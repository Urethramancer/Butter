import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum TransferFilter: String, CaseIterable, Identifiable {
	case all = "All", downloading = "Downloading", seeding = "Seeding", completed = "Completed", paused = "Paused"
	var id: String { rawValue }
	var symbol: String { switch self { case .all: "tray.full"; case .downloading: "arrow.down.circle"; case .seeding: "arrow.up.circle"; case .completed: "checkmark.circle"; case .paused: "pause.circle" } }
	@MainActor func matches(_ t: TransferSnapshot, store: TransferStore) -> Bool {
		switch self {
		case .all: true
		case .downloading: !t.complete && store.record(t.id)?.wanted == true
		case .seeding: t.complete && store.record(t.id)?.wanted == true
		case .completed: t.complete
		case .paused: store.record(t.id)?.wanted == false
		}
	}
}
struct ContentView: View {
	@EnvironmentObject private var store: TransferStore
	@State private var filter: TransferFilter = .all
	@State private var collapsed = Set<String>()
	@State private var search = ""
	private var visible: [TransferSnapshot] { store.transfers.filter { filter.matches($0, store: store) && (search.isEmpty || store.title($0).localizedCaseInsensitiveContains(search)) } }
	var body: some View {
		NavigationSplitView {
			List(TransferFilter.allCases, selection: $filter) { item in
				Label { HStack { Text(item.rawValue); Spacer(); Text("\(store.transfers.filter { item.matches($0, store: store) }.count)").foregroundStyle(.secondary).monospacedDigit() } } icon: { Image(systemName: item.symbol) }.tag(item)
			}.navigationTitle("Butter").navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 250)
		} detail: {
			VStack(spacing: 0) {
				if !store.ready { ProgressView("Restoring transfers…").frame(maxWidth: .infinity, maxHeight: .infinity) }
				else if visible.isEmpty { ContentUnavailableView(search.isEmpty ? "No transfers" : "No matching transfers", systemImage: "arrow.down.doc", description: Text(search.isEmpty ? "Open a torrent file or add a magnet link to begin." : "Try another search or filter.")).frame(maxWidth: .infinity, maxHeight: .infinity) }
				else {
					List(selection: Binding(get: { store.selection }, set: { store.selectFromList($0) })) {
						ForEach(store.preferences.groups) { group in groupSection(group.id.uuidString, title: group.name, colour: group.colour, members: visible.filter { store.group(for: $0)?.id == group.id }) }
						groupSection("ungrouped", title: "Ungrouped", colour: "grey", members: visible.filter { store.group(for: $0) == nil })
					}.listStyle(.inset)
				}
				Divider(); StatusBar().padding(.horizontal, 12).padding(.vertical, 7)
			}
			.navigationTitle(filter.rawValue)
			.toolbar {
				ToolbarItem(placement: .principal) {
					TransferSearchField(text: $search).frame(minWidth: 180, idealWidth: 260, maxWidth: 340).help("Find transfers by name.")
				}
				ToolbarItemGroup(placement: .primaryAction) {
					Button { store.chooseTorrent() } label: { Label("Open Torrent", systemImage: "plus") }.help("Open torrent file (⌘O)")
					Button { store.showMagnet = true } label: { Label("Add Magnet", systemImage: "link") }.help("Add a magnet link (⌘L)").accessibilityIdentifier("add-magnet")
					Button { store.showCreator = true } label: { Label("Create Torrent", systemImage: "doc.badge.plus") }.help("Create a torrent from local files (⌘N)")
					Button { store.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }.keyboardShortcut("i", modifiers: [.command, .option]).help(store.showInspector ? "Hide inspector (⌥⌘I)" : "Show inspector (⌥⌘I)").accessibilityValue(store.showInspector ? "Shown" : "Hidden").accessibilityIdentifier("toggle-inspector")
				}
			}
			.inspector(isPresented: $store.showInspector) {
				if let torrent = store.transfers.first(where: { store.selection.contains($0.id) }) { TorrentInspector(torrent: torrent).id(torrent.id) }
				else { ContentUnavailableView("Select a transfer", systemImage: "info.circle") }
			}
		}
		.frame(minWidth: 980, minHeight: 590)
		.onDrop(of: [.fileURL, .url, .plainText], isTargeted: nil, perform: handleDrop)
		.sheet(item: $store.addRequest, onDismiss: { store.dismissAdd() }) { AddTorrentSheet(request: $0) }
		.sheet(isPresented: $store.showCreator, onDismiss: { Task { await store.presentPendingAdd() } }) { CreateTorrentSheet() }
		.sheet(isPresented: $store.showMagnet, onDismiss: { Task { await store.presentPendingAdd() } }) { MagnetSheet() }
		.alert("Butter couldn’t complete the operation", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
	}
	@ViewBuilder private func groupSection(_ key: String, title: String, colour: String, members: [TransferSnapshot]) -> some View {
		if !members.isEmpty {
			Section {
				if !collapsed.contains(key) { ForEach(members) { torrent in TorrentRow(torrent: torrent).tag(torrent.id).accessibilityElement(children: .contain).accessibilityIdentifier("transfer-row-\(torrent.id)").contextMenu { TransferMenu(torrent: torrent) } } }
			} header: {
				HStack {
					Button { if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) } } label: { HStack { Image(systemName: collapsed.contains(key) ? "chevron.right" : "chevron.down"); Circle().fill(groupColour(colour)).frame(width: 8, height: 8); Text(title); Text("\(members.count)").foregroundStyle(.secondary) } }.buttonStyle(.plain).controlHelp("\(collapsed.contains(key) ? "Expand" : "Collapse") group \(title)").accessibilityValue("\(members.count) transfers")
					Spacer()
					Button { store.selection = Set(members.map(\.id)) } label: { Image(systemName: "checkmark.circle") }.buttonStyle(.plain).help("Select all members of \(title)").accessibilityLabel("Select all members of \(title)")
				}
			}
		}
	}
	private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
		for provider in providers {
			if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
				provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
					let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
					if let url { Task { @MainActor in await store.open(url.absoluteString) } }
				}
			} else if provider.canLoadObject(ofClass: NSString.self) {
				_ = provider.loadObject(ofClass: NSString.self) { item, _ in if let text = item as? String { Task { @MainActor in await store.open(text) } } }
			}
		}
		return !providers.isEmpty
	}
}
func groupColour(_ name: String) -> Color { switch name { case "red": .red; case "orange": .orange; case "green": .green; case "purple": .purple; case "pink": .pink; case "grey": .gray; default: .blue } }
struct TorrentRow: View {
	@EnvironmentObject private var store: TransferStore
	let torrent: TransferSnapshot
	var body: some View {
		HStack(spacing: 12) {
			Menu { PriorityMenu(ids: store.selection.contains(torrent.id) ? store.selection : [torrent.id]) } label: { Image(systemName: "line.3.horizontal.decrease.circle").font(.title3) }.menuStyle(.borderlessButton).frame(width: 23).controlHelp("Change priority for \(store.title(torrent))").accessibilityValue(store.priority(for: torrent).label)
			VStack(alignment: .leading, spacing: 5) {
				HStack {
					Text(store.title(torrent)).font(.headline).lineLimit(1)
					if let format = torrent.formatLabel {
						Text(format).font(.caption2.weight(.semibold)).foregroundStyle(.primary)
							.padding(.horizontal, 5).padding(.vertical, 2).background(.quaternary, in: .rect(cornerRadius: 4)).fixedSize()
							.accessibilityLabel("Torrent format: \(format)").help(format == "Hybrid" ? "Hybrid torrent supporting both v1 and v2." : "BitTorrent \(format) torrent.")
					}
					Spacer(); Text("\(Int(torrent.verifiedProgress * 100))%").monospacedDigit().foregroundStyle(.secondary)
				}
				PieceProgress(pieces: torrent.pieces).frame(height: 7)
				HStack { Text("\(bytes(torrent.done)) of \(bytes(torrent.wanted)) · \(store.state(torrent))").lineLimit(1); Spacer(); if torrent.down > 0 { Text("↓ \(speed(torrent.down))") }; if torrent.up > 0 { Text("↑ \(speed(torrent.up))") } }.font(.caption).foregroundStyle(torrent.error.isEmpty ? Color.secondary : Color.red).accessibilityElement(children: .ignore).accessibilityLabel("\(bytes(torrent.done)) of \(bytes(torrent.wanted)), \(store.state(torrent)). Download \(speed(torrent.down)), upload \(speed(torrent.up)).")
			}
			Button { Task { await store.setRunning([torrent.id], running: !(store.record(torrent.id)?.wanted ?? false)) } } label: { Image(systemName: store.record(torrent.id)?.wanted == true ? "pause.circle.fill" : "play.circle.fill").font(.title2) }.buttonStyle(.plain).controlHelp("\(store.record(torrent.id)?.wanted == true ? "Pause" : "Start") \(store.title(torrent))")
			Button { store.reveal(torrent) } label: { Image(systemName: "folder").font(.title3) }.buttonStyle(.plain).controlHelp("Reveal \(store.title(torrent)) in Finder")
		}.padding(.vertical, 8)
	}
}
struct PieceProgress: View {
	let pieces: [UInt8]
	private let colours: [Color] = [.gray.opacity(0.25), .green, .yellow, .blue, .red]
	private var accessibilitySummary: String {
		guard !pieces.isEmpty else { return "Availability unknown" }
		var counts = [Int](repeating: 0, count: 5)
		for piece in pieces where piece < 5 { counts[Int(piece)] += 1 }
		return "\(counts[1]) verified, \(counts[2]) downloading, \(counts[3]) available, \(counts[4]) unavailable, \(counts[0]) unknown"
	}
	var body: some View {
		Canvas { context, size in
			guard !pieces.isEmpty else { context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(colours[0])); return }
			let width = size.width / Double(pieces.count)
			var start = 0
			while start < pieces.count {
				let value = Int(min(4, pieces[start])); var end = start + 1
				while end < pieces.count && pieces[end] == pieces[start] { end += 1 }
				context.fill(Path(CGRect(x: Double(start) * width, y: 0, width: Double(end - start) * width, height: size.height)), with: .color(colours[value])); start = end
			}
		}.clipShape(.rect(cornerRadius: 3)).accessibilityLabel("Pieces in original order").accessibilityValue(accessibilitySummary)
	}
}
struct PriorityMenu: View {
	@EnvironmentObject private var store: TransferStore
	var ids: Set<String>
	var body: some View {
		ForEach(TransferPriority.allCases) { priority in Button(priority.label) { Task { await store.setPriority(priority, ids: ids) } }.help("Set selected transfers to \(priority.label.lowercased()) priority.") }
		Divider(); Button("Reset to Group Priority") { Task { await store.setPriority(nil, ids: ids) } }.help("Inherit priority from the matching group.")
	}
}
struct TransferMenu: View {
	@EnvironmentObject private var store: TransferStore
	let torrent: TransferSnapshot
	private var ids: Set<String> { store.selection.contains(torrent.id) ? store.selection : [torrent.id] }
	var body: some View {
		Button("Start") { Task { await store.setRunning(ids, running: true) } }.help("Start selected transfers using the queue limits.")
		Button("Pause") { Task { await store.setRunning(ids, running: false) } }.help("Pause selected transfers and retain their data.")
		Button("Force Start") { Task { await store.setRunning(ids, running: true, force: true) } }.help("Start selected transfers beyond the active-transfer limits.")
		Menu("Priority") { PriorityMenu(ids: ids) }
		Divider(); Button("Rename…") { store.renameTorrent(torrent) }.help("Change this transfer’s display name.")
		Button("Verify Local Data") { Task { for id in ids { await store.command("recheck", id: id) } } }.disabled(!torrent.metadata).help("Hash local data again and retry damaged or missing pieces.")
		Button("Repair from Folder…") { store.repairFolder(torrent) }.disabled(!torrent.metadata).help("Repair this torrent from matching local files, preserving the source folder.")
		Button("Retry Completion Move") { Task { await store.retryMove(torrent) } }.disabled(!torrent.complete).help("Retry moving completed data to the final destination.")
		Button("Copy Magnet Link") { Task { await store.copyMagnet(torrent.id) } }.disabled(!torrent.metadata).help("Copy this torrent’s magnet link to the clipboard.")
		Button("Export Torrent…") { store.export(torrent) }.disabled(!torrent.metadata).help("Save a torrent file with its original swarm identity.")
		Divider(); Button("Remove") { Task { await store.remove(ids, trash: false) } }.help("Remove selected transfers while keeping downloaded data.")
		Button("Remove and Delete Data…", role: .destructive) { store.confirmRemoval(ids) }.disabled(!torrent.metadata).help("Confirm removal and move only managed files to Trash.")
	}
}
struct StatusBar: View {
	@EnvironmentObject private var store: TransferStore
	var body: some View {
		HStack(spacing: 16) {
			if store.preferences.statusItems.contains("Torrents") { Text("\(store.transfers.count) torrents") }
			if store.preferences.statusItems.contains("Peers") { Text("\(store.transfers.reduce(0) { $0 + $1.peers.count }) peers") }
			if store.preferences.statusItems.contains("Downloads") { Text("\(store.transfers.filter { $0.state == "Downloading" }.count) downloading") }
			if store.preferences.statusItems.contains("Uploads") { Text("\(store.transfers.filter { $0.up > 0 }.count) uploading") }
			Spacer(minLength: 0)
			if store.preferences.statusItems.contains("Download speed") { Text("↓ \(speed(store.transfers.reduce(0) { $0 + $1.down }))") }
			if store.preferences.statusItems.contains("Upload speed") { Text("↑ \(speed(store.transfers.reduce(0) { $0 + $1.up }))") }
			if !store.networkError.isEmpty { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help(store.networkError).accessibilityLabel("Network warning").accessibilityValue(store.networkError) }
		}.font(.caption).foregroundStyle(.secondary).monospacedDigit()
	}
}
