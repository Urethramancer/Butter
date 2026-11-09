import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PreferencesView: View {
	@EnvironmentObject private var store: TransferStore
	var body: some View {
		TabView {
			GeneralPreferences().tabItem { Label("General", systemImage: "gearshape") }
			TransferPreferences().tabItem { Label("Transfers", systemImage: "arrow.up.arrow.down") }
			NetworkPreferences().tabItem { Label("Network", systemImage: "network") }
			GroupPreferences().tabItem { Label("Groups", systemImage: "folder.badge.gearshape") }
			TrackerPreferences().tabItem { Label("Favourite Trackers", systemImage: "star") }
		}.frame(width: 730, height: 610)
		.onChange(of: store.preferences) { old, _ in Task { await store.settingsChanged(from: old) } }
		.alert("Settings error", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
	}
}
struct GeneralPreferences: View {
	@EnvironmentObject private var store: TransferStore
	@State private var registration = ""
	var body: some View {
		Form {
			Picker("Appearance", selection: $store.preferences.appearance) { ForEach(["System", "Light", "Dark"], id: \.self) { Text($0) } }
			Section("Notifications") {
				Toggle("Notify when a download completes", isOn: $store.preferences.notifications)
				Button("Open Notification Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?net.grimdork.Butter")!) }.help("Manage Butter’s notification permissions in System Settings.")
			}
			Picker("Confirm quitting", selection: $store.preferences.quitMode) { ForEach(["Always", "Active Transfers", "Active Downloads", "Never"], id: \.self) { Text($0) } }
			Section("Status bar") { ForEach(["Torrents", "Peers", "Downloads", "Uploads", "Download speed", "Upload speed"], id: \.self) { item in Toggle(item, isOn: Binding(get: { store.preferences.statusItems.contains(item) }, set: { if $0 { store.preferences.statusItems.insert(item) } else { store.preferences.statusItems.remove(item) } })) } }
			Section("Default application") {
				HStack { Button("Register for Magnet Links") { NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "magnet") { error in Task { @MainActor in if let error { store.report(error) } else { registration = "Magnet registration requested." } } } }.help("Make Butter the default application for magnet links."); Button("Register for Torrent Files") { NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: UTType(filenameExtension: "torrent") ?? .data) { error in Task { @MainActor in if let error { store.report(error) } else { registration = "Torrent registration requested." } } } }.help("Make Butter the default application for torrent files.") }
				if !registration.isEmpty { Text(registration).font(.caption).foregroundStyle(.secondary) }
			}
		}.formStyle(.grouped)
	}
}
struct TransferPreferences: View {
	@EnvironmentObject private var store: TransferStore
	var body: some View {
		Form {
			Section("Adding transfers") {
				Toggle("Start transfers after adding", isOn: $store.preferences.startOnAdd)
				FolderField(title: "Watch folder", path: $store.preferences.watchFolder, optional: true)
				Toggle("Delete watched originals after successful import", isOn: $store.preferences.deleteOriginal).disabled(store.preferences.watchFolder.isEmpty)
			}
			Section("Destinations") {
				FolderField(title: "Incomplete downloads", path: $store.preferences.incompleteFolder)
				FolderField(title: "Completed downloads", path: $store.preferences.finalFolder, optional: true)
				Toggle("Remove completed transfers, keeping downloaded data", isOn: $store.preferences.autoRemove)
				Text("Completion moves must succeed before automatic removal. Created torrents seed their source in place.").font(.caption).foregroundStyle(.secondary)
			}
			Section("Queue") {
				Stepper("Active downloads: \(store.preferences.activeDownloads)", value: $store.preferences.activeDownloads, in: 0...100)
				Stepper("Active seeds: \(store.preferences.activeSeeds)", value: $store.preferences.activeSeeds, in: 0...100)
				LabeledContent("Stop at seed ratio (0 disables)") { TextField("Ratio", value: $store.preferences.ratioLimit, format: .number.precision(.fractionLength(0...2))).frame(width: 80) }
				Stepper("Stop idle seeds after \(store.preferences.idleMinutes) minutes (0 disables)", value: $store.preferences.idleMinutes, in: 0...1440)
				Text("Idle time counts only running seeds without upload demand. Force Start bypasses the active-transfer limits.").font(.caption).foregroundStyle(.secondary)
			}
		}.formStyle(.grouped)
	}
}
struct NetworkPreferences: View {
	@EnvironmentObject private var store: TransferStore
	@State private var checking = false
	@State private var randomising = false
	var body: some View {
		Form {
			Section("Connections") {
				Toggle("Enable incoming and outgoing µTP", isOn: $store.preferences.utp)
				HStack { TextField("Listening port", value: $store.preferences.port, format: .number.grouping(.never)).frame(maxWidth: 230); Button("Randomise") { Task { await randomise() } }.disabled(randomising).help("Bind a free listening port before saving it."); Button("Check Port") { checking = true; Task { store.portStatus = await PortChecker().check(store.boundPort); checking = false } }.disabled(checking || store.boundPort == 0).help("Ask Transmission’s HTTPS service to check external TCP reachability.") }
				Text("TCP: \(store.portStatus)").font(.caption)
				Text("Local UDP/µTP: \(store.udpBound ? "bound on port \(store.boundPort)" : "not confirmed")").font(.caption).foregroundStyle(.secondary)
				if !store.networkError.isEmpty { Text(store.networkError).font(.caption).foregroundStyle(.orange) }
				PeerLimitField(title: "Global peer limit", value: $store.preferences.peers, range: 1...5000)
				PeerLimitField(title: "Per-torrent peer limit", value: $store.preferences.torrentPeers, range: 1...1000)
				Text("The global peer limit remains authoritative. Router mapping is automatic.").font(.caption).foregroundStyle(.secondary)
			}
			Section("Discovery") { Toggle("Peer exchange (PEX)", isOn: $store.preferences.pex); Toggle("Distributed hash table (DHT)", isOn: $store.preferences.dht); Toggle("Local peer discovery", isOn: $store.preferences.lsd); Text("Private torrents always disable these discovery mechanisms.").font(.caption).foregroundStyle(.secondary) }
			Section("Blocklists") {
				ForEach(store.preferences.blocklists) { source in HStack { Text(source.name); Spacer(); Text("\(source.ranges.count) ranges").foregroundStyle(.secondary); Button { store.preferences.blocklists.removeAll { $0.id == source.id } } label: { Image(systemName: "minus.circle") }.controlHelp("Remove blocklist \(source.name)") } }
				HStack { Button("Import…") { importBlocklists() }.help("Import one or more IP blocklist files."); Button("Export Optimised List…") { exportBlocklist() }.disabled(store.preferences.blocklists.isEmpty).help("Save the merged, optimised IP blocklist.") }
				Text("Supports IP addresses, CIDR and PeerGuardian/eMule ranges. All imported sources are combined.").font(.caption).foregroundStyle(.secondary)
			}
		}.formStyle(.grouped)
	}
	private func randomise() async {
		randomising = true; defer { randomising = false }
		do {
			for _ in 0..<5 {
				var p = store.preferences; p.port = 0
				let data = try await store.engine.perform("settings", ["port": 0, "utp": p.utp, "peers": p.peers, "torrentPeers": p.torrentPeers, "dht": p.dht, "pex": p.pex, "lsd": p.lsd])
				let result = try JSONSerialization.jsonObject(with: data) as? [String: Int]
				guard let port = result?["port"] else { continue }
				try await Task.sleep(for: .milliseconds(600))
				let snapshot = try await store.engine.snapshot()
				if snapshot.port == port && snapshot.udp && snapshot.networkError.isEmpty { store.preferences.port = port; store.boundPort = port; store.udpBound = true; store.portStatus = "Not checked"; return }
			}
			store.error = "Could not bind a free listening port. Check firewall and interface settings, then retry."
			await store.applyNetwork()
		} catch { store.report(error); await store.applyNetwork() }
	}
	private func importBlocklists() {
		let panel = NSOpenPanel(); panel.allowsMultipleSelection = true
		panel.begin { response in guard response == .OK else { return }; Task { @MainActor in
			do {
				let urls = panel.urls
				let sources = try await Task.detached { try urls.map { url in BlocklistSource(name: url.lastPathComponent, ranges: try Blocklist.parse(String(contentsOf: url, encoding: .utf8))) } }.value
				store.preferences.blocklists.append(contentsOf: sources)
			} catch { store.report(error) }
		} }
	}
	private func exportBlocklist() {
		let panel = NSSavePanel(); panel.nameFieldStringValue = "Butter-blocklist.txt"
		panel.begin { response in guard response == .OK, let url = panel.url else { return }; let ranges = store.preferences.blocklists.flatMap(\.ranges); Task { @MainActor in do { try await Task.detached { try Blocklist.export(ranges).write(to: url, atomically: true, encoding: .utf8) }.value } catch { store.report(error) } } }
	}
}
struct GroupPreferences: View {
	@EnvironmentObject private var store: TransferStore
	@State private var selection: UUID?
	var body: some View {
		HSplitView {
			VStack {
				List(store.preferences.groups, selection: $selection) { group in Label { Text(group.name) } icon: { Circle().fill(groupColour(group.colour)).frame(width: 9, height: 9) }.tag(group.id) }
				HStack { Button { let group = TorrentGroup(); store.preferences.groups.append(group); selection = group.id } label: { Image(systemName: "plus") }.controlHelp("Add group"); Button { store.preferences.groups.removeAll { $0.id == selection }; selection = nil } label: { Image(systemName: "minus") }.disabled(selection == nil).controlHelp("Delete selected group"); Spacer(); Button { move(-1) } label: { Image(systemName: "arrow.up") }.disabled(!canMove(-1)).controlHelp("Move selected group earlier"); Button { move(1) } label: { Image(systemName: "arrow.down") }.disabled(!canMove(1)).controlHelp("Move selected group later") }.padding(10)
			}.frame(minWidth: 180, idealWidth: 210)
			if let index = store.preferences.groups.firstIndex(where: { $0.id == selection }) { GroupEditor(group: $store.preferences.groups[index]) }
			else { ContentUnavailableView("Select a group", systemImage: "folder") }
		}.padding(16)
	}
	private func canMove(_ offset: Int) -> Bool { guard let index = store.preferences.groups.firstIndex(where: { $0.id == selection }) else { return false }; return store.preferences.groups.indices.contains(index + offset) }
	private func move(_ offset: Int) { guard let index = store.preferences.groups.firstIndex(where: { $0.id == selection }), store.preferences.groups.indices.contains(index + offset) else { return }; store.preferences.groups.swapAt(index, index + offset) }
}
struct GroupEditor: View {
	@Binding var group: TorrentGroup
	var body: some View {
		Form {
			TextField("Name", text: $group.name)
			Picker("Colour", selection: $group.colour) { ForEach(["blue", "green", "orange", "red", "purple", "pink", "grey"], id: \.self) { Text($0.capitalized) } }
			Picker("Priority", selection: $group.priority) { ForEach(TransferPriority.allCases) { Text($0.label).tag($0) } }
			Section("Rules") {
				TextField("Tracker hosts (comma separated)", text: $group.trackerHosts)
				TextField("Minimum size (MiB)", value: $group.minimumMiB, format: .number)
				TextField("Maximum size (MiB, 0 unlimited)", value: $group.maximumMiB, format: .number)
				TextField("Name/path keywords (comma separated)", text: $group.keywords)
				Text("All configured criteria must match. Keywords match any listed term. The first matching group owns the torrent.").font(.caption).foregroundStyle(.secondary)
			}
		}.formStyle(.grouped)
	}
}
struct TrackerPreferences: View {
	@EnvironmentObject private var store: TransferStore
	@State private var draft = FavouriteTracker()
	@State private var editing: UUID?
	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			List(store.preferences.trackers) { tracker in HStack { VStack(alignment: .leading) { Text(tracker.name).font(.headline); Text(tracker.url).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Edit") { draft = tracker; editing = tracker.id }.help("Edit favourite tracker \(tracker.name)."); Button { store.preferences.trackers.removeAll { $0.id == tracker.id } } label: { Image(systemName: "minus.circle") }.controlHelp("Delete favourite tracker \(tracker.name)") } }
			Form { TextField("Name", text: $draft.name); TextField("Tracker URL", text: $draft.url); HStack { Button(editing == nil ? "Add Favourite" : "Save Changes") { if let i = store.preferences.trackers.firstIndex(where: { $0.id == editing }) { store.preferences.trackers[i] = draft } else { store.preferences.trackers.append(draft) }; draft = FavouriteTracker(); editing = nil }.disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !FavouriteTracker.valid(draft.url)).help(editing == nil ? "Add this validated tracker to favourites." : "Save changes to this favourite tracker."); if editing != nil { Button("Cancel") { editing = nil; draft = FavouriteTracker() }.help("Discard changes to this favourite tracker.") } } }
			Text("Choosing a favourite appends it explicitly; watched imports add none. Existing private torrents keep their original trackers.").font(.caption).foregroundStyle(.secondary)
		}.padding(20)
	}
}
