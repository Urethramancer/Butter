import SwiftUI
import AppKit

struct TorrentInspector: View {
	@EnvironmentObject private var store: TransferStore
	var torrent: TransferSnapshot
	@State private var tab = "Info"
	@State private var search = ""
	@State private var favourite = ""
	var body: some View {
		VStack(spacing: 14) {
			HStack(alignment: .top) {
				ZStack { Circle().stroke(.quaternary, lineWidth: 5); Circle().trim(from: 0, to: torrent.verifiedProgress).stroke(torrent.complete ? .green : .accentColor, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90)); Image(systemName: torrent.complete ? "checkmark" : "arrow.down").font(.title2) }.frame(width: 48, height: 48).accessibilityElement(children: .ignore).accessibilityLabel("\(Int(torrent.verifiedProgress * 100)) per cent verified")
				VStack(alignment: .leading, spacing: 4) { Text(store.title(torrent)).font(.headline).textSelection(.enabled); Text("\(bytes(torrent.done)) / \(bytes(torrent.wanted)) selected").font(.caption).foregroundStyle(.secondary); Text(store.state(torrent)).font(.caption).foregroundStyle(torrent.error.isEmpty ? Color.secondary : .red) }
				Spacer(minLength: 0)
			}.padding(.horizontal)
			HStack {
				Button { Task { await store.setRunning([torrent.id], running: !(store.record(torrent.id)?.wanted ?? false)) } } label: { Label(store.record(torrent.id)?.wanted == true ? "Pause" : "Start", systemImage: store.record(torrent.id)?.wanted == true ? "pause.fill" : "play.fill") }.help(store.record(torrent.id)?.wanted == true ? "Pause this transfer." : "Start this transfer using the queue limits.")
				Button("Force Start") { Task { await store.setRunning([torrent.id], running: true, force: true) } }.help("Start this transfer beyond the active-transfer limits.")
				Button { store.reveal(torrent) } label: { Image(systemName: "folder") }.controlHelp("Reveal in Finder")
			}
			Picker("Inspector section", selection: $tab) { ForEach(["Info", "Trackers", "Peers", "Files"], id: \.self) { Text($0) } }.pickerStyle(.segmented).labelsHidden().padding(.horizontal)
			Divider()
			if tab == "Info" { info }
			if tab == "Trackers" { trackers }
			if tab == "Peers" { peers }
			if tab == "Files" { files }
		}.padding(.top, 16).inspectorColumnWidth(min: 310, ideal: 360, max: 520)
	}
	private var info: some View {
		Form {
			Section("Transfer") {
				LabeledContent("Total size", value: bytes(torrent.total))
				LabeledContent("Download", value: speed(torrent.down))
				LabeledContent("Upload", value: speed(torrent.up))
				LabeledContent("Remaining", value: torrent.eta)
				LabeledContent("Ratio", value: String(format: "%.2f", torrent.ratio))
				LabeledContent("Priority", value: store.priority(for: torrent).label + (store.record(torrent.id)?.priority == nil ? " (group)" : ""))
				if let added = store.record(torrent.id)?.added { LabeledContent("Added", value: added.formatted(date: .abbreviated, time: .shortened)) }
			}
			Section("Location") { Text(torrent.path).font(.caption).textSelection(.enabled); Button("Reveal in Finder") { store.reveal(torrent) }.help("Show this transfer’s files in Finder."); if store.record(torrent.id)?.moveFailed == true { Button("Retry Completion Move") { Task { await store.retryMove(torrent) } }.help("Retry moving data to the completed-download destination.") } }
			Section("Identity") { ForEach(torrent.hashes, id: \.self) { Text($0).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }; LabeledContent("Private", value: torrent.private ? "Yes" : "No"); Button("Copy Magnet Link") { Task { await store.copyMagnet(torrent.id) } }.disabled(!torrent.metadata).help("Copy this torrent’s magnet link to the clipboard."); Button("Export Torrent…") { store.export(torrent) }.disabled(!torrent.metadata).help("Save a torrent file with its original swarm identity.") }
		}.formStyle(.grouped)
	}
	private var trackers: some View {
		VStack {
			List(torrent.trackers, id: \.url) { tracker in VStack(alignment: .leading, spacing: 5) { Text(tracker.url).font(.caption).textSelection(.enabled); if !tracker.message.isEmpty { Text(tracker.message).font(.caption).foregroundStyle(.orange) } } }
			if torrent.private { Text("Private torrents keep their original trackers.").font(.caption).foregroundStyle(.secondary).padding() }
			else {
				HStack { Picker("Favourite", selection: $favourite) { Text("Choose tracker").tag(""); ForEach(store.preferences.trackers) { Text($0.name).tag($0.url) } }; Button("Append") { Task { await store.command("tracker", id: torrent.id, extra: ["tracker": favourite]); favourite = "" } }.disabled(favourite.isEmpty || !torrent.metadata).help("Append the chosen favourite without replacing existing trackers.") }.padding()
			}
		}
	}
	private var peers: some View {
		List(torrent.peers, id: \.self) { peer in VStack(alignment: .leading, spacing: 4) { HStack { Text(peer.address).monospaced(); Spacer(); Text(peer.utp ? "µTP" : "TCP").foregroundStyle(.secondary) }; Text(peer.client).foregroundStyle(.secondary); Text("↓ \(speed(peer.down))    ↑ \(speed(peer.up))").monospacedDigit() }.font(.caption)
			.accessibilityElement(children: .ignore)
			.accessibilityLabel("\(peer.client.isEmpty ? "Peer" : peer.client), \(peer.address)")
			.accessibilityValue("\(peer.utp ? "µTP" : "TCP"). Download \(speed(peer.down)), upload \(speed(peer.up)).")
		}.overlay { if torrent.peers.isEmpty { ContentUnavailableView("No connected peers", systemImage: "person.2") } }
	}
	private var files: some View {
		VStack {
			TextField("Search current or original names", text: $search).textFieldStyle(.roundedBorder).padding(.horizontal).accessibilityLabel("Search files").help("Filter files by their current or original names.")
			if torrent.metadata {
				ScrollView { FileTree(torrent: torrent, search: search).padding(.horizontal) }
			} else { ContentUnavailableView("Resolving metadata", systemImage: "hourglass", description: Text("File selection becomes available when metadata arrives.")) }
		}.padding(.bottom)
	}
}
struct FileNode: Identifiable {
	var path: String
	var original: String
	var files: [TransferFile]
	var children: [FileNode]
	var id: String { path }
	var isFolder: Bool { !children.isEmpty }
	var title: String { (path as NSString).lastPathComponent }
	var selection: NSControl.StateValue { let selected = files.filter(\.selected).count; return selected == files.count ? .on : selected == 0 ? .off : .mixed }
	func matches(_ search: String) -> Bool { search.isEmpty || files.contains { $0.path.localizedCaseInsensitiveContains(search) || $0.original.localizedCaseInsensitiveContains(search) } }
	static func tree(_ files: [TransferFile], prefix: String = "", depth: Int = 0) -> [FileNode] {
		let grouped = Dictionary(grouping: files) { $0.path.split(separator: "/").dropFirst(depth).first.map(String.init) ?? "" }
		return grouped.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.filter { !$0.isEmpty }.map { name in
			let members = grouped[name]!, path = prefix.isEmpty ? name : prefix + "/" + name
			let nested = members.filter { $0.path.split(separator: "/").count > depth + 1 }
			let original = members.first!.original.split(separator: "/").prefix(depth + 1).joined(separator: "/")
			return FileNode(path: path, original: original, files: members, children: tree(nested, prefix: path, depth: depth + 1))
		}
	}
}
private struct FileTree: View {
	var torrent: TransferSnapshot
	var search: String
	@State private var collapsed = Set<String>()
	var body: some View {
		LazyVStack(alignment: .leading, spacing: 4) {
			ForEach(FileTreeEntry.visible(FileNode.tree(torrent.files.filter { !$0.pad }), search: search, collapsed: collapsed)) { entry in
				FileNodeRow(node: entry.node, torrent: torrent, search: search, expanded: Binding(
					get: { !collapsed.contains(entry.id) },
					set: { if $0 { collapsed.remove(entry.id) } else { collapsed.insert(entry.id) } }))
					.padding(.leading, CGFloat(entry.depth) * 16)
					.padding(.top, 3).padding(.bottom, CGFloat(entry.bottom))
			}
		}
	}
}
struct FileTreeEntry: Identifiable {
	var node: FileNode
	var depth: Int
	var bottom = 3
	var id: String { node.id }
	static func visible(_ nodes: [FileNode], search: String, collapsed: Set<String>, depth: Int = 0) -> [Self] {
		var rows: [Self] = []
		for node in nodes where node.matches(search) {
			rows.append(Self(node: node, depth: depth))
			if node.isFolder, !collapsed.contains(node.id) {
				let children = visible(node.children, search: search, collapsed: collapsed, depth: depth + 1)
				if !children.isEmpty {
					// Preserve the original nested stacks' outer padding at subtree ends.
					rows[rows.count - 1].bottom = 0; rows.append(contentsOf: children)
					rows[rows.count - 1].bottom += 3
				}
			}
		}
		return rows
	}
}
struct FileNodeRow: View {
	@EnvironmentObject private var store: TransferStore
	var node: FileNode
	var torrent: TransferSnapshot
	var search: String
	@Binding var expanded: Bool
	var body: some View {
		if node.matches(search) {
			VStack(alignment: .leading, spacing: 4) {
				HStack(spacing: 5) {
					if node.isFolder { Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2) }.buttonStyle(.plain).frame(width: 12).controlHelp("\(expanded ? "Collapse" : "Expand") folder \(node.path)").accessibilityValue(expanded ? "Expanded" : "Collapsed") } else { Spacer().frame(width: 12) }
					MixedCheckbox(state: node.selection, label: "Download \(node.path)", identifier: "Download \(node.title)") { value in
						let indices = Set(node.files.map(\.index)); let selected = torrent.files.map { indices.contains($0.index) ? (value ? 1 : 0) : ($0.selected ? 1 : 0) }
						Task { await store.command("select", id: torrent.id, extra: ["selected": selected]) }
					}.frame(width: 18, height: 18)
					Image(systemName: node.isFolder ? "folder" : "doc").foregroundStyle(.secondary).accessibilityHidden(true)
					VStack(alignment: .leading, spacing: 2) {
						let target = RenamePathTarget(torrentID: torrent.id, path: node.path)
						if store.renamingPath == target {
							InlineRenameField(
								initialText: node.title,
								identifier: "local-name",
								label: "Local \(node.isFolder ? "folder" : "file") name",
								font: .systemFont(ofSize: NSFont.systemFontSize),
								onCommit: { store.commitRenamePath(target, to: $0) },
								onCancel: { store.cancelRenamePath() }
							)
						} else {
							Text(node.title).lineLimit(1)
						}
						if node.original != node.path { Text("Original: \((node.original as NSString).lastPathComponent)").font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
					}
					Spacer(); Text(bytes(node.files.reduce(0) { $0 + $1.size })).font(.caption2).foregroundStyle(.secondary)
				}.contextMenu {
					Button("Verify Local Data") { Task { await store.command("recheck", id: torrent.id, extra: ["files": node.files.map(\.index)]) } }.help("Hash complete pieces overlapping these files, including shared boundary bytes.")
					Button("Rename Local \(node.isFolder ? "Folder" : "File")") { store.renamePath(node.path, torrent: torrent) }.help("Rename local contents while preserving the original torrent metadata.")
					if !node.isFolder, let file = node.files.first, !file.pad {
						Button("Repair from local file…") { store.repairFile(file.index, torrent: torrent) }.help("Repair this file from a local copy, preserving the source.")
					}
				}
			}
		}
	}
}
struct MixedCheckbox: NSViewRepresentable {
	var state: NSControl.StateValue
	var label: String
	var identifier: String
	var action: (Bool) -> Void
	func makeCoordinator() -> Coordinator { Coordinator(action) }
	func makeNSView(context: Context) -> NSButton { let button = MixedCheckboxButton(checkboxWithTitle: "", target: context.coordinator, action: #selector(Coordinator.changed(_:))); button.allowsMixedState = true; return button }
	func updateNSView(_ button: NSButton, context: Context) { button.state = state; button.toolTip = label; button.setAccessibilityLabel(label); button.setAccessibilityIdentifier(identifier); button.setAccessibilityHelp("Include or exclude these contents from downloading. Mixed means only some files are selected."); context.coordinator.action = action; context.coordinator.state = state }
	final class Coordinator: NSObject {
		var action: (Bool) -> Void
		var state: NSControl.StateValue = .off
		init(_ action: @escaping (Bool) -> Void) { self.action = action }
		@objc func changed(_ sender: NSButton) { let enabled = state != .on; state = enabled ? .on : .off; sender.state = state; action(enabled) }
	}
}

private final class MixedCheckboxButton: NSButton {
	override func accessibilityPerformPress() -> Bool {
		guard isEnabled else { return false }
		performClick(nil); return true
	}
}
