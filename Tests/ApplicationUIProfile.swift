import Foundation
import Darwin
import SwiftUI
import AppKit

// A disposable rendering fixture. It contains synthetic models, no user payload.
@MainActor private final class UIProfileEngine: EngineOperations, @unchecked Sendable {
	var rows: [TransferSnapshot] = []
	nonisolated var creationProgress: Double { 0 }
	nonisolated func cancelCreation() {}
	func perform(_ command: String, _ payload: [String: Any]) async throws -> Data {
		if command == "add" { return try JSONSerialization.data(withJSONObject: ["id": payload["id"]!, "duplicate": false]) }
		if command == "run", let id = payload["id"] as? String, let running = payload["running"] as? Bool, let index = rows.firstIndex(where: { $0.id == id }) {
			rows[index].state = running ? (rows[index].complete ? "Seeding" : "Downloading") : "Paused"
		}
		if command == "shutdown" { return Data("{\"cleanShutdownEligible\":true}".utf8) }
		return Data("{}".utf8)
	}
	func snapshot() async throws -> EngineSnapshot { EngineSnapshot(transfers: rows, events: [], port: 0, udp: false, networkError: "", creationProgress: 0) }
	func advance(_ tick: Int, seeding: Bool) {
		for index in rows.indices {
			if rows[index].state == "Paused" { continue }
			if seeding { rows[index].uploaded += 65536; rows[index].up = 65536 + tick }
			else {
				let file = tick % rows[index].files.count
				let delta = min(16384, rows[index].files[file].size - rows[index].files[file].done)
				rows[index].files[file].done += delta; rows[index].done += delta
				rows[index].downloaded += delta; rows[index].down = 65536 + tick
				rows[index].progress = Double(rows[index].done) / Double(rows[index].wanted)
			}
		}
	}
}

@main struct ApplicationUIProfile {
	struct Scene: View {
		@EnvironmentObject var store: TransferStore
		let inspector: Bool
		var body: some View {
			HStack(spacing: 0) {
				ContentView()
				if inspector, let row = store.transfers.first(where: { store.selection.contains($0.id) }) {
					Divider(); TorrentInspector(profiledTorrent: row).frame(width: 360).id(row.id)
				}
			}
		}
	}
	struct Job: Decodable { let workload: String; let role: String; let inspector: Bool; let screenshot: String; let captureFinal: Bool? }
	static func cpu() throws -> Double {
		var usage = rusage(); guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw CocoaError(.fileReadUnknown) }
		return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
	}
	static func emit(_ phase: String, renderCPU: Double? = nil, updateCPU: Double? = nil, fileFrame: [Double]? = nil) throws {
		var usage = rusage(); guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw CocoaError(.fileReadUnknown) }
		var record: [String: Any] = ["phase": phase, "pid": getpid(), "time": ProcessInfo.processInfo.systemUptime,
			"user": Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6,
			"system": Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6, "peak_rss": usage.ru_maxrss]
		if let renderCPU { record["initial_render_cpu_seconds"] = renderCPU }
		if let updateCPU { record["update_cpu_seconds"] = updateCPU }
		if let fileFrame { record["first_file_frame"] = fileFrame }
		var bytes = try JSONSerialization.data(withJSONObject: record); bytes.append(10); try FileHandle.standardOutput.write(contentsOf: bytes)
	}
	static func command(_ expected: String) async throws {
		let line = await Task.detached { readLine() }.value
		guard let line, let bytes = line.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], object["command"] as? String == expected else { throw CocoaError(.fileReadCorruptFile) }
	}
	@MainActor static func visibleFileCheckbox(_ view: NSView) -> NSButton? {
		if let button = view as? NSButton, button.accessibilityLabel() == "Download file-00000.bin", !button.visibleRect.isEmpty { return button }
		for child in view.subviews { if let button = visibleFileCheckbox(child) { return button } }
		return nil
	}
	@MainActor static func capture(_ view: NSView, path: String) throws {
		guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileReadUnknown) }
		view.cacheDisplay(in: view.bounds, to: image)
		guard let data = image.representation(using: .png, properties: [:]) else { throw CocoaError(.fileReadUnknown) }
		try data.write(to: URL(fileURLWithPath: path))
	}
	@MainActor static func main() {
		#if BUTTER_FILE_TREE_AVAILABLE
		if CommandLine.arguments.dropFirst().first == "--test-file-tree" {
			do { try FileTreeTests.run(); print("PASS: file tree order, search, collapse, indentation and nested padding"); exit(0) }
			catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
		}
		#endif
		let app = NSApplication.shared; app.setActivationPolicy(.accessory)
		Task { @MainActor in
			do { try await run(); exit(0) }
			catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
		}
		app.run()
	}
	@MainActor static func run() async throws {
		guard CommandLine.arguments.count == 3 else { throw CocoaError(.fileReadCorruptFile) }
		let job = try JSONDecoder().decode(Job.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
		guard ["many-files", "many-torrents"].contains(job.workload), ["download", "seed"].contains(job.role) else { throw CocoaError(.fileReadCorruptFile) }
		try emit("prepare")
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("butter-ui-profile-" + UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: root) }
		let engine = UIProfileEngine(), count = job.workload == "many-files" ? 1 : 200, files = job.workload == "many-files" ? 2000 : 512
		let seeding = job.role == "seed"
		let records = (0..<count).map { TransferRecord(id: "model-\($0)", source: "ui-profile://model-\($0)", destination: root.path, wanted: true, completionHandled: true) }
		for record in records {
			var row = TransferSnapshot.unavailable(record, error: "")
			row.name = "Profiling " + record.id; row.metadata = true; row.state = seeding ? "Seeding" : "Downloading"
			row.complete = seeding; row.total = Int64(files) * 1_048_576; row.wanted = row.total
			row.done = seeding ? row.total : row.total / 2; row.downloaded = row.done; row.uploaded = 65536
			row.progress = Double(row.done) / Double(row.wanted); row.down = seeding ? 0 : 65536; row.up = seeding ? 65536 : 0
			row.hashes = [String(repeating: "a", count: 40)]; row.pieces = Array(repeating: seeding ? 1 : 3, count: 1024)
			row.files = (0..<files).map { index in
				let path = String(format: "Bundle/directory-%03d/file-%05d.bin", index / 100, index)
				return TransferFile(index: index, path: path, original: path, size: 1_048_576, done: seeding ? 1_048_576 : 524288, selected: true, pad: false)
			}
			row.peers = [PeerSnapshot(address: "192.0.2.1", client: "Rendering fixture", down: row.down, up: row.up, utp: false)]
			row.demand = seeding; engine.rows.append(row)
		}
		var saved = SavedState(); saved.transfers = records; saved.preferences.port = 0
		saved.preferences.dht = false; saved.preferences.lsd = false; saved.preferences.pex = false
		saved.preferences.activeDownloads = 100; saved.preferences.activeSeeds = 100
		try await StateStorage(root: root).save(saved)
		let store = TransferStore(root: root, engine: engine, automaticPolling: false, allowsSystemIntegration: false)
		await store.start(); guard store.ready else { throw CocoaError(.fileReadCorruptFile) }
		await store.refresh(); await store.refresh()
		guard store.transfers.count == count, store.transfers.allSatisfy({ $0.files.count == files }) else { throw NSError(domain: "UIProfile", code: 3, userInfo: [NSLocalizedDescriptionKey: "Rendering fixture was not populated before profiling"]) }
		store.selection = [records[0].id]; store.showInspector = false
		try emit("ready"); try await command("start"); try emit("start")
		let renderStart = try cpu()
		let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1540, height: 740), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
		window.title = "Butter profiling fixture"; window.contentViewController = NSHostingController(rootView: Scene(inspector: job.inspector).environmentObject(store)); window.makeKeyAndOrderFront(nil)
		try await Task.sleep(for: .milliseconds(700))
		guard store.selection == [records[0].id] else { throw NSError(domain: "UIProfile", code: 4, userInfo: [NSLocalizedDescriptionKey: "Rendering fixture selection changed before profiling"]) }
		guard let view = window.contentView else { throw CocoaError(.fileReadUnknown) }
		try capture(view, path: job.screenshot)
		guard !job.inspector || visibleFileCheckbox(view) != nil else {
			throw NSError(domain: "UIProfile", code: 5, userInfo: [NSLocalizedDescriptionKey: "The visible file inspector did not render its first file checkbox"])
		}
		let rendered = try cpu()
		for tick in 0..<12 {
			engine.advance(tick, seeding: seeding); await store.refresh()
			try await Task.sleep(for: .seconds(1))
		}
		var fileFrame: [Double]?
		if job.captureFinal == true {
			view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
			try await Task.sleep(for: .milliseconds(100))
			try capture(view, path: job.screenshot)
			if job.inspector {
				guard let button = visibleFileCheckbox(view) else { throw CocoaError(.fileReadCorruptFile) }
				let frame = button.convert(button.bounds, to: view)
				fileFrame = [frame.origin.x, frame.origin.y, frame.width, frame.height]
			}
		}
		try emit("verified", renderCPU: rendered - renderStart, updateCPU: try cpu() - rendered, fileFrame: fileFrame)
		try await command("persist"); try emit("persistence")
		guard store.error == nil, store.transfers.count == count,
			zip(store.transfers, engine.rows).allSatisfy({ shown, expected in
				shown.id == expected.id && shown.done == expected.done && shown.uploaded == expected.uploaded && shown.files.map(\.done) == expected.files.map(\.done)
			}) else { throw CocoaError(.fileReadCorruptFile) }
		guard await store.persist() else { throw CocoaError(.fileWriteUnknown) }
		try emit("durable"); try await command("stop"); try emit("shutdown")
		guard await store.shutdown() else { throw CocoaError(.fileWriteUnknown) }
		let reopened = try await StateStorage(root: root).load()
		guard reopened.cleanShutdown, reopened.transfers.map(\.id) == records.map(\.id) else { throw CocoaError(.fileReadCorruptFile) }
		window.orderOut(nil); try emit("stopped")
	}
}
