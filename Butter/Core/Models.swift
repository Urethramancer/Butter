import Foundation

enum TransferPriority: Int, Codable, CaseIterable, Identifiable {
	case low, normal, high
	var id: Int { rawValue }
	var label: String { ["Low", "Normal", "High"][rawValue] }
}
struct FavouriteTracker: Codable, Identifiable, Equatable {
	var id = UUID()
	var name = ""
	var url = ""
	static func valid(_ text: String) -> Bool {
		guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https", "udp", "ws", "wss"].contains(scheme), url.host != nil else { return false }
		return !text.contains(where: \.isWhitespace)
	}
}
struct TorrentGroup: Codable, Identifiable, Equatable {
	var id = UUID()
	var name = "New Group"
	var colour = "blue"
	var priority: TransferPriority = .normal
	var trackerHosts = ""
	var minimumMiB: Double = 0
	var maximumMiB: Double = 0
	var keywords = ""
	func matches(_ transfer: TransferSnapshot) -> Bool {
		guard transfer.metadata else { return false }
		let hosts = Self.words(trackerHosts)
		if !hosts.isEmpty && !transfer.trackers.contains(where: { tracker in
			guard let host = URL(string: tracker.url)?.host?.lowercased() else { return false }
			return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
		}) { return false }
		let size = Double(transfer.total) / 1_048_576
		if size < minimumMiB || (maximumMiB > 0 && size > maximumMiB) { return false }
		let terms = Self.words(keywords)
		let names = ([transfer.name] + transfer.files.map(\.original)).joined(separator: "\n").lowercased()
		return terms.isEmpty || terms.contains { names.contains($0) }
	}
	static func words(_ text: String) -> [String] { text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty } }
}
struct Preferences: Codable, Equatable {
	var appearance = "System"
	var notifications = false
	var quitMode = "Active Transfers"
	var statusItems: Set<String> = ["Torrents", "Peers", "Download speed", "Upload speed"]
	var watchFolder = ""
	var deleteOriginal = false
	var incompleteFolder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!.path
	var finalFolder = ""
	var ratioLimit: Double = 0
	var autoRemove = false
	var startOnAdd = true
	var activeDownloads = 3
	var activeSeeds = 5
	var idleMinutes = 0
	var utp = true
	var port = 6881
	var peers = 200
	var torrentPeers = 80
	var pex = true
	var dht = true
	var lsd = true
	var groups: [TorrentGroup] = []
	var trackers: [FavouriteTracker] = []
	var blocklists: [BlocklistSource] = []
}
struct TransferRecord: Codable, Identifiable {
	var id: String = UUID().uuidString
	var source: String
	var destination: String
	var added = Date()
	var name: String? = nil
	var wanted = true
	var force = false
	var priority: TransferPriority? = nil
	var creation = false
	var moved = false
	var moveFailed = false
	var completionHandled = false
}
struct TransferFile: Codable, Identifiable {
	var index: Int
	var path: String
	var original: String
	var size: Int64
	var done: Int64
	var selected: Bool
	var pad: Bool
	var id: Int { index }
}
struct TrackerSnapshot: Codable, Hashable { var url: String; var message: String }
struct PeerSnapshot: Codable, Hashable { var address: String; var client: String; var down: Int; var up: Int; var utp: Bool }
struct TransferSnapshot: Codable, Identifiable {
	var id: String
	var name: String
	var path: String
	var state: String
	var error: String
	var metadata: Bool
	var `private`: Bool
	var complete: Bool
	var progress: Double
	var wanted: Int64
	var done: Int64
	var total: Int64
	var down: Int
	var up: Int
	var downloaded: Int64
	var uploaded: Int64
	var demand: Bool
	var hashes: [String]
	var pieces: [Int]
	var files: [TransferFile]
	var trackers: [TrackerSnapshot]
	var peers: [PeerSnapshot]
	var ratio: Double { Double(uploaded) / Double(max(1, downloaded > 0 ? downloaded : wanted)) }
	var eta: String { down > 0 && !complete ? Duration.seconds(Double(max(0, wanted - done)) / Double(down)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)) : "—" }
	var verifiedProgress: Double { wanted > 0 ? Double(done) / Double(wanted) : 0 }
}
struct EngineEvent: Codable { var kind: String; var id: String; var path: String?; var existingID: String? }
struct EngineSnapshot: Codable {
	var transfers: [TransferSnapshot]
	var events: [EngineEvent]
	var port: Int
	var udp: Bool
	var networkError: String
	var creationProgress: Double
}
struct SavedState: Codable {
	var preferences = Preferences()
	var transfers: [TransferRecord] = []
	var watchedImports: Set<String> = []
}
struct MetadataPreview: Codable {
	struct File: Codable, Identifiable {
		var index: Int; var path: String; var size: Int64; var pad: Bool
		var id: Int { index }
	}
	var name: String; var `private`: Bool; var files: [File]; var hashes: [String]
}
func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
func speed(_ value: Int) -> String { "\(bytes(Int64(value)))/s" }

enum TransferGrouping {
	static func group(for torrent: TransferSnapshot, groups: [TorrentGroup]) -> TorrentGroup? { groups.first { $0.matches(torrent) } }
	static func priority(_ explicit: TransferPriority?, torrent: TransferSnapshot, groups: [TorrentGroup]) -> TransferPriority { explicit ?? group(for: torrent, groups: groups)?.priority ?? .normal }
}
