import Foundation
import Darwin
import ButterTorrentMetadata

fileprivate final class RepositoryReservation: @unchecked Sendable {
	private let lock = NSLock()
	private var lease: StorageLease?
	init(_ lease: StorageLease) { self.lease = lease }
	func take() -> StorageLease? { lock.withLock { defer { lease = nil }; return lease } }
}

public struct PreparedTransferState: Sendable {
	public let directory: URL
	fileprivate let id: String
	fileprivate let name: String
	fileprivate let created: Bool
	fileprivate let reservation: RepositoryReservation
	let anchor: StorageDirectory
	fileprivate let parentIdentity: FileStamp
}

/// TransferRepository retains standard torrent files beside isolated native checkpoints.
public actor TransferRepository {
	private struct Record: Codable { let version: Int; let directory: String }
	private let root: URL
	private let worker = StorageWorker()
	public init(root: URL) { self.root = root }
	/// Publishes a creator's completed bytes under the repository's publication lease.
	public static func publishCreatedTorrent(_ data: Data, id: String, root: URL) throws {
		try validateID(id)
		let directory = try StorageDirectory(root), lease = try StorageLease(directory: directory, path: ".native.lock"); defer { lease.release() }
		guard data.count <= 33_554_432 else { throw StorageFailure.limit("torrent bytes") }
		guard try directory.inspect(id + ".torrent") == nil else { throw StorageFailure.collision("torrent output") }
		try directory.atomic(data, path: id + ".torrent", exclusive: true)
	}
	public static func validateID(_ id: String) throws {
		guard (1...128).contains(id.utf8.count), id.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { throw StorageFailure.invalid("transfer identifier") }
	}
	public func metadata(id: String, source: URL, restore: Bool) async throws -> TorrentMetadata {
		try Self.validateID(id); let root = root
		return try await worker.run { _ in
			let directory = try StorageDirectory(root)
			let lease = try StorageLease(directory: directory, path: ".native.lock"); defer { lease.release() }
			if restore, try Self.record(id, in: directory) != nil { return try TorrentMetadata(directory.read(id + ".torrent", maximum: 33_554_432)) }
			return try TorrentMetadata(contentsOf: source)
		}
	}
	public func prepare(id: String, restore: Bool) async throws -> PreparedTransferState {
		try Self.validateID(id); let root = root
		return try await worker.run { _ in
			let directory = try StorageDirectory(root)
			let reservation = RepositoryReservation(try StorageLease(directory: directory, path: ".native.lock"))
			if let record = try Self.record(id, in: directory) {
				guard restore else { throw StorageFailure.collision("retained native state; restore or forget it first") }
				let child = try directory.child(record.directory)
				return PreparedTransferState(directory: child.url, id: id, name: record.directory, created: false, reservation: reservation, anchor: child, parentIdentity: try directory.identity())
			}
			let name = ".native-" + UUID().uuidString, child = try directory.child(name, create: true)
			return PreparedTransferState(directory: child.url, id: id, name: name, created: true, reservation: reservation, anchor: child, parentIdentity: try directory.identity())
		}
	}
	public func publish(id: String, metadata: TorrentMetadata, state: PreparedTransferState) async throws {
		try Self.validateID(id); let root = root
		try await worker.run { _ in
			let directory = try StorageDirectory(root, create: false)
			guard try state.parentIdentity.sameFile(directory.identity()) else { throw StorageFailure.recoveryRequired("session repository was replaced") }
			let lease = try state.reservation.take() ?? StorageLease(directory: directory, path: ".native.lock"); defer { lease.release() }
			guard id == state.id, state.directory == directory.url.appendingPathComponent(state.name) else { throw StorageFailure.invalid("prepared state root") }
			guard try directory.child(state.name).identity().sameFile(state.anchor.identity()) else { throw StorageFailure.recoveryRequired("prepared state directory was replaced") }
			if let previous = try Self.record(id, in: directory), previous.directory != state.name { throw StorageFailure.collision("published transfer state") }
			let path = id + ".torrent"
			let existing = try directory.inspect(path)
			if existing != nil {
				let previous = try TorrentMetadata(directory.read(path, maximum: 33_554_432))
				guard previous.originalInfo == metadata.originalInfo else { throw StorageFailure.collision("stored torrent identity") }
			}
			try directory.atomic(metadata.document.original, path: path, exclusive: existing == nil)
			let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
			try directory.atomic(encoder.encode(Record(version: 1, directory: state.name)), path: id + ".native.plist")
		}
	}
	public func abandon(_ state: PreparedTransferState) async throws {
		let root = root
		try await worker.run { _ in
			let directory = try StorageDirectory(root, create: false)
			guard try state.parentIdentity.sameFile(directory.identity()) else { throw StorageFailure.recoveryRequired("session repository was replaced") }
			let lease = try state.reservation.take() ?? StorageLease(directory: directory, path: ".native.lock"); defer { lease.release() }
			guard state.created else { return }
			guard state.directory == directory.url.appendingPathComponent(state.name) else { throw StorageFailure.invalid("prepared state root") }
			// A failed directory flush may follow a successful publication. Retain that state.
			if try Self.record(state.id, in: directory)?.directory == state.name { return }
			guard try directory.child(state.name).identity().sameFile(state.anchor.identity()) else { throw StorageFailure.recoveryRequired("prepared state directory was replaced") }
			try Self.discardChild(state.name, in: directory)
		}
	}
	/// Discards only recognised native state and the standard torrent; legacy resume files remain intact.
	public func discard(id: String) async throws {
		try Self.validateID(id); let root = root
		try await worker.run { _ in
			let directory = try StorageDirectory(root)
			let lease = try StorageLease(directory: directory, path: ".native.lock"); defer { lease.release() }
			if let record = try Self.record(id, in: directory) {
				do { try Self.discardChild(record.directory, in: directory) }
				catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { } // An interrupted discard may have removed the directory.
			}
			for name in [id + ".native.plist", id + ".torrent"] {
				if let stamp = try directory.inspect(name) { try directory.remove(name, expected: stamp) }
			}
		}
	}
	private static func record(_ id: String, in directory: StorageDirectory) throws -> Record? {
		let name = id + ".native.plist"
		guard try directory.inspect(name) != nil else { return nil }
		let record = try PropertyListDecoder().decode(Record.self, from: directory.read(name, maximum: 4096))
		guard record.version == 1, record.directory.hasPrefix(".native-"), UUID(uuidString: String(record.directory.dropFirst(8))) != nil else { throw StorageFailure.invalid("native state record") }
		return record
	}
	private static func discardChild(_ name: String, in directory: StorageDirectory) throws {
		let child = try directory.child(name), lease = try StorageLease(directory: child); defer { lease.release() }
		let names = try child.names()
		guard !names.contains("operation.plist") else { throw StorageFailure.recoveryRequired("recover the filesystem journal before forgetting state") }
		let allowed: Set<String> = ["metadata.torrent", "checkpoint.plist", "hashes.plist", "storage.lock", "unwanted"]
		guard names.allSatisfy(allowed.contains) else { throw StorageFailure.recoveryRequired("unrecognised files in native state were retained") }
		let unwanted = names.contains("unwanted") ? try child.child("unwanted") : nil
		let unwantedNames = try unwanted?.names() ?? []
		guard unwantedNames.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) }) }) else { throw StorageFailure.recoveryRequired("unrecognised unwanted files were retained") }
		// Preflight every file before removing anything; inspect refuses links and nonregular files.
		let files = try names.filter { $0 != "unwanted" }.map { ($0, try child.inspect($0)) }
		let spill = try unwantedNames.map { ($0, try unwanted!.inspect($0)) }
		for (path, stamp) in spill { if let stamp { try unwanted!.remove(path, expected: stamp) } }
		if let unwanted { try child.removeChild("unwanted", expected: unwanted) }
		for (path, stamp) in files { if let stamp { try child.remove(path, expected: stamp) } }
		try directory.removeChild(name, expected: child)
	}
}
