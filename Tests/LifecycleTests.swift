import Foundation
import AppKit

struct Failure: Error, CustomStringConvertible { var description: String }
func check(_ condition: @autoclosure () -> Bool, _ message: String) throws { if !condition() { throw Failure(description: message) } }
@main struct LifecycleTests {
	@MainActor static func main() async {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		do {
			let selected = ProcessInfo.processInfo.environment["BUTTER_TEST_CASE"]
			if let selected, !["store-regressions", "lifecycle-integration"].contains(selected) { throw Failure(description: "Unknown lifecycle test case") }
			if selected != "lifecycle-integration" { try await StoreRegressionTests.run() }
			if selected == "store-regressions" { return }
			let fm = FileManager.default
			try fm.createDirectory(at: root, withIntermediateDirectories: true)
			defer { try? fm.removeItem(at: root) }
			var saved = SavedState(); saved.preferences.port = 0; saved.preferences.dht = false; saved.preferences.pex = false; saved.preferences.lsd = false
			try await StateStorage(root: root).save(saved)
			let store = TransferStore(root: root, automaticPolling: false, allowsSystemIntegration: false); await store.start()
			// Disable router discovery for the isolated test sessions.
			_ = try await store.engine.perform("settings", ["port": 0, "mapping": false, "utp": true, "dht": false, "lsd": false, "pex": false, "peers": 20, "torrentPeers": 10])
			let seed = root.appendingPathComponent("seed"); try fm.createDirectory(at: seed, withIntermediateDirectories: true)
			let original = seed.appendingPathComponent("original.bin"), bytes = Data((0..<100_000).map { UInt8($0 % 251) }); try bytes.write(to: original)
			let created = try JSONSerialization.jsonObject(with: await store.engine.perform("create", ["id": "fixture", "source": original.path, "trackers": [], "private": false])) as! [String: String]
			store.preferences.autoRemove = true; store.preferences.finalFolder = root.appendingPathComponent("final").path
			let added = await store.add(AddRequest(source: created["source"]!, destination: seed.path, start: true))
			try check(added, "Add fixture")
			for _ in 0..<100 { await store.refresh(); if store.records.isEmpty { break }; try await Task.sleep(for: .milliseconds(30)) }
			try check(store.records.isEmpty, "Auto-remove after confirmed completion move")
			let finalFile = URL(fileURLWithPath: store.preferences.finalFolder).appendingPathComponent("original.bin")
			let finalData = try Data(contentsOf: finalFile); try check(finalData == bytes, "Auto-remove must retain downloaded data")
			let source = seed.appendingPathComponent("source.bin"); try Data([1, 2, 3, 4, 5]).write(to: source)
			let seeded = await store.create(source: source.path, trackers: [], isPrivate: false, start: true)
			try check(seeded, "Create torrent and seed source")
			for _ in 0..<20 { await store.refresh(); try await Task.sleep(for: .milliseconds(30)) }
			try check(store.records.count == 1 && store.records[0].creation && fm.fileExists(atPath: source.path), "Creation must seed in place without auto-removal")
			let originalID = store.records[0].id
			let duplicate = await store.add(AddRequest(source: store.records[0].source, destination: seed.path, start: true))
			try check(!duplicate && store.selection == [originalID] && store.records.count == 1, "Duplicates must select existing transfer")
			store.preferences.autoRemove = false; store.preferences.finalFolder = ""
			let watched = root.appendingPathComponent("watch"); try fm.createDirectory(at: watched, withIntermediateDirectories: true)
			let watchData = seed.appendingPathComponent("watched.bin"); try Data([9, 8, 7, 6]).write(to: watchData)
			let watchTorrent = try JSONSerialization.jsonObject(with: await store.engine.perform("create", ["id": "watched", "source": watchData.path, "trackers": [], "private": false])) as! [String: String]
			let watchedOriginal = watched.appendingPathComponent("watched.torrent"); try fm.copyItem(atPath: watchTorrent["source"]!, toPath: watchedOriginal.path)
			store.preferences.watchFolder = watched.path; store.preferences.deleteOriginal = true; store.preferences.startOnAdd = false
			store.preferences.trackers = [FavouriteTracker(name: "Favourite", url: "http://127.0.0.1:3/favourite")]
			await store.refresh(); try check(fm.fileExists(atPath: watchedOriginal.path), "Watcher must wait for arrival stability")
			try await Task.sleep(for: .seconds(4)); await store.refresh()
			try check(store.records.count == 2 && !fm.fileExists(atPath: watchedOriginal.path), "Successful watched import copies metadata before deleting original")
			await store.refresh(); try check(store.transfers.first { $0.name == "watched.bin" }?.trackers.isEmpty == true, "Watched imports do not append favourite trackers")
			try check(store.records.allSatisfy { fm.fileExists(atPath: $0.source) }, "Imported metadata lives in Application Support")
			let privateSource = seed.appendingPathComponent("private.bin"); try Data([22, 33, 44]).write(to: privateSource)
			let privateAdded = await store.create(source: privateSource.path, trackers: ["http://127.0.0.1:1/announce"], isPrivate: true, start: false)
			try check(privateAdded, "Private creation with explicit tracker")
			await store.refresh()
			let privateTorrent = store.transfers.first { $0.private }!
			await store.command("tracker", id: privateTorrent.id, extra: ["tracker": "http://127.0.0.1:2/announce"])
			try check(store.error != nil, "Existing private torrent must reject appended favourites")
			let publicSource = seed.appendingPathComponent("public.bin"); try Data([55, 66, 77]).write(to: publicSource)
			let publicAdded = await store.create(source: publicSource.path, trackers: ["http://127.0.0.1:1/original"], isPrivate: false, start: false)
			try check(publicAdded, "Public creation with original tracker"); await store.refresh()
			let publicTorrent = store.transfers.first { $0.name == "public.bin" }!
			await store.command("tracker", id: publicTorrent.id, extra: ["tracker": store.preferences.trackers[0].url]); await store.refresh()
			let updated = store.transfers.first { $0.id == publicTorrent.id }!
			try check(Set(updated.trackers.map(\.url)) == ["http://127.0.0.1:1/original", "http://127.0.0.1:3/favourite"] && updated.hashes == publicTorrent.hashes, "Explicit favourite appends without replacing original trackers or identity")
			let firstOpen = Task { await store.open(watchTorrent["source"]!) }; let secondOpen = Task { await store.open(created["source"]!) }
			await firstOpen.value; await secondOpen.value
			let firstPrepared = store.addRequest?.source
			try check(firstPrepared != nil, "Concurrent opens prepare an Add sheet")
			store.dismissAdd(); await store.presentPendingAdd()
			try check(Set([firstPrepared, store.addRequest?.source].compactMap { $0 }) == Set([watchTorrent["source"]!, created["source"]!]), "Concurrent opens queue both Add sheets without replacing one")
			store.dismissAdd()
			let shutdown = await store.shutdown(); try check(shutdown, "Orderly save before termination")
			let restored = try await StateStorage(root: root).load()
			try check(restored.transfers.count == 4 && restored.watchedImports.count == 1, "Persist transfer and watcher state")
			print("PASS: completion move/auto-remove retaining data, creation in place, duplicate selection, stable watched import/copy/deletion, private tracker restriction, orderly persistence")
		} catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
	}
}
