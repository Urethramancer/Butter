import SwiftUI
import AppKit

struct AddTorrentSheet: View {
	@EnvironmentObject private var store: TransferStore
	@Environment(\.dismiss) private var dismiss
	@State var request: AddRequest
	@State private var adding = false
	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text("Add Torrent").font(.title2.bold())
			Text(request.preview?.name ?? "Magnet link").font(.headline).lineLimit(2)
			FolderField(title: "Destination", path: $request.destination)
			Toggle("Start after adding", isOn: $request.start)
			Picker("Append favourite tracker", selection: $request.tracker) { Text("None").tag(""); ForEach(store.preferences.trackers) { Text($0.name).tag($0.url) } }.disabled(request.preview?.private != false)
			if request.preview?.private == true { Text("Private torrents retain their original trackers.").font(.caption).foregroundStyle(.secondary) }
			if let preview = request.preview {
				List(preview.files.filter { !$0.pad }) { file in HStack { Toggle(file.path, isOn: Binding(get: { request.selected.contains(file.index) }, set: { if $0 { request.selected.insert(file.index) } else { request.selected.remove(file.index) } })); Spacer(); Text(bytes(file.size)).foregroundStyle(.secondary) } }.frame(height: 200)
			} else { Text("Contents and tracker options will be available after the magnet’s metadata resolves.").foregroundStyle(.secondary).frame(height: 90) }
			HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(adding); Button("Add") { adding = true; Task { _ = await store.add(request); adding = false; dismiss() } }.keyboardShortcut(.defaultAction).disabled(adding || request.destination.isEmpty || (request.preview != nil && request.selected.isEmpty)) }
		}.padding(24).frame(width: 570).interactiveDismissDisabled(adding)
	}
}
struct FolderField: View {
	var title: String
	@Binding var path: String
	var optional = false
	var body: some View {
		LabeledContent(title) {
			HStack { Text(path.isEmpty ? "Not configured" : path).lineLimit(1).truncationMode(.middle).foregroundStyle(path.isEmpty ? .secondary : .primary).help(path); Spacer(); if optional && !path.isEmpty { Button { path = "" } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain).help("Disable \(title)") }; Button("Choose…") { choose() } }
		}
	}
	private func choose() {
		let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
		panel.begin { result in if result == .OK, let url = panel.url { path = url.path } }
	}
}
struct MagnetSheet: View {
	@EnvironmentObject private var store: TransferStore
	@Environment(\.dismiss) private var dismiss
	@State private var text = ""
	var body: some View {
		VStack(alignment: .leading, spacing: 16) { Text("Add Magnet Link").font(.title2.bold()); TextField("magnet:?xt=urn:…", text: $text).textFieldStyle(.roundedBorder); HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("Continue") { Task { await store.open(text.trimmingCharacters(in: .whitespacesAndNewlines)); dismiss() } }.keyboardShortcut(.defaultAction).disabled(!text.hasPrefix("magnet:?")) } }.padding(24).frame(width: 520)
	}
}
struct CreateTorrentSheet: View {
	@EnvironmentObject private var store: TransferStore
	@Environment(\.dismiss) private var dismiss
	@State private var source = ""
	@State private var trackers: [String] = [""]
	@State private var favourite = ""
	@State private var isPrivate = false
	@State private var start = true
	private var urls: [String] { trackers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
	private var valid: Bool { !source.isEmpty && urls.allSatisfy(FavouriteTracker.valid) && (!isPrivate || !urls.isEmpty) }
	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text("Create Torrent").font(.title2.bold())
			Group {
			HStack { Text(source.isEmpty ? "Choose a file or folder to seed in place" : source).lineLimit(2); Spacer(); Button("Choose…") { let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.begin { if $0 == .OK { source = panel.url?.path ?? "" } } } }
			Text("Trackers").font(.headline)
			ForEach(trackers.indices, id: \.self) { index in HStack { TextField("https://tracker.example/announce", text: $trackers[index]).textFieldStyle(.roundedBorder); Button { trackers.remove(at: index) } label: { Image(systemName: "minus.circle") } } }
			HStack { Button("Add Tracker Row") { trackers.append("") }; Spacer(); Picker("Favourite", selection: $favourite) { Text("Choose tracker").tag(""); ForEach(store.preferences.trackers) { Text($0.name).tag($0.url) } }.onChange(of: favourite) { _, value in if !value.isEmpty { trackers.append(value); favourite = "" } } }
			Toggle("Private torrent (requires a tracker)", isOn: $isPrivate)
			Toggle("Start seeding after creation", isOn: $start)
			Text("Creates hybrid v1/v2 metadata. Source files remain in their current location.").font(.caption).foregroundStyle(.secondary)
			}.disabled(store.creating)
			if store.creating { ProgressView(value: store.creationProgress); Text("Hashing \(Int(store.creationProgress * 100))%…").font(.caption) }
			HStack { Spacer(); Button(store.creating ? "Cancel Hashing" : "Cancel") { if store.creating { store.engine.bridge.cancelCreation() } else { dismiss() } }.keyboardShortcut(.cancelAction); Button("Create") { Task { if await store.create(source: source, trackers: urls, isPrivate: isPrivate, start: start) { dismiss() } } }.keyboardShortcut(.defaultAction).disabled(!valid || store.creating) }
		}.padding(24).frame(width: 590).interactiveDismissDisabled(store.creating).onAppear { start = store.preferences.startOnAdd }
	}
}
