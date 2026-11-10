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

public struct PendingMagnetState: Sendable {
	public let magnet: Magnet
	public let destination: URL
	fileprivate let id: String
	fileprivate let parentIdentity: FileStamp
	fileprivate let lockIdentity: FileStamp
	fileprivate let lease: StorageLease
}

public enum RepositoryEvent: Sendable, Equatable {
	case stagingDurable, checkpointDirectoryDurable, torrentDurable, locatorDurable
}

/// TransferRepository retains standard torrent files beside isolated native checkpoints.
public actor TransferRepository {
	private struct Record: Codable { let version: Int; let directory: String }
	private struct StagingRecord: Codable { let version: Int; let directory: String; let identity: FileStamp? }
	private struct MagnetRecord: Codable { let version: Int; let uri: String; let destination: String }
	private static let magnetRecordLimit = 2 * 1024 * 1024
	private let root: URL
	private let event: @Sendable (RepositoryEvent) -> Void
	private let worker = StorageWorker()
	public init(root: URL, event: @escaping @Sendable (RepositoryEvent) -> Void = { _ in }) {
		self.root = root; self.event = event
	}
	/// Publishes a creator's completed bytes under the repository's publication lease.
	public static func publishCreatedTorrent(_ data: Data, id: String, root: URL) throws {
		try validateID(id)
		let directory = try StorageDirectory(root), lease = try StorageLease(directory: directory, path: ".native.lock"); defer { lease.release() }
		guard data.count <= 33_554_432 else { throw StorageFailure.limit("torrent bytes") }
		guard try directory.inspect(magnetRecord(id)) == nil else { throw StorageFailure.collision("retained pending magnet") }
		guard try directory.inspect(stagingPath(id)) == nil else { throw StorageFailure.recoveryRequired("finish the interrupted transfer publication") }
		guard try directory.inspect(id + ".torrent") == nil else { throw StorageFailure.collision("torrent output") }
		try directory.atomic(data, path: id + ".torrent", exclusive: true)
	}
	public static func validateID(_ id: String) throws {
		guard (1...128).contains(id.utf8.count), id.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { throw StorageFailure.invalid("transfer identifier") }
	}
	public func metadata(id: String, source: URL, restore: Bool) async throws -> TorrentMetadata {
		try Self.validateID(id); let root = root
		return try await worker.run(bulk: true) { _ in
			let directory = try StorageDirectory(root)
			let lease = try StorageLease(directory: directory, path: ".native.lock"); defer { lease.release() }
			if restore, try Self.record(id, in: directory) != nil { return try TorrentMetadata(directory.read(id + ".torrent", maximum: 33_554_432)) }
			return try TorrentMetadata(contentsOf: source)
		}
	}
	/// A resolved magnet can restore its retained torrent without a source file.
	public func retainedMetadata(id: String) async throws -> TorrentMetadata? {
		try Self.validateID(id); let root = root
		return try await worker.run(bulk: true) { _ in
			let directory = try StorageDirectory(root)
			let lease = try StorageLease(directory: directory, path: ".native.lock"); defer { lease.release() }
			guard try Self.record(id, in: directory) != nil else { return nil }
			return try TorrentMetadata(directory.read(id + ".torrent", maximum: 33_554_432))
		}
	}
	public func claimMagnet(id: String, magnet: Magnet, destination: URL, restore: Bool, tracker: String?) async throws -> PendingMagnetState {
		try Self.validateID(id); let root = root
		return try await worker.run(bulk: true) { _ in
			let directory = try StorageDirectory(root)
			let reservation = try StorageLease(directory: directory, path: ".native.lock"); defer { reservation.release() }
			guard try Self.record(id, in: directory) == nil else { throw StorageFailure.collision("published transfer state") }
			let path = Self.magnetRecord(id), existing = try directory.inspect(path) != nil
			guard !existing || restore else { throw StorageFailure.collision("retained native state; restore or forget it first") }
			if !existing, try directory.inspect(id + ".torrent") != nil { throw StorageFailure.collision("stored torrent identity") }
			let lock = Self.magnetLock(id), lease = try StorageLease(directory: directory, path: lock)
			guard let lockIdentity = try directory.inspect(lock) else { throw StorageFailure.recoveryRequired("missing pending magnet lock") }
			var magnetToSave = magnet, destinationToSave = destination
			if existing {
				let record = try PropertyListDecoder().decode(MagnetRecord.self, from: directory.read(path, maximum: Self.magnetRecordLimit))
				guard record.version == 1 else { throw StorageFailure.invalid("pending magnet record version") }
				magnetToSave = try Magnet(record.uri)
				guard magnetToSave.hashes == magnet.hashes else { throw MetadataError.invalid("retained magnet identity") }
				destinationToSave = URL(fileURLWithPath: try Self.validDestination(record.destination))
			}
			let append = tracker.flatMap { magnetToSave.trackers.contains($0) ? nil : $0 }
			if let append { magnetToSave.trackers.append(append) }
			if !existing || append != nil {
				try Self.writeMagnet(magnetToSave, destination: destinationToSave, path: path, in: directory, exclusive: !existing)
			}
			try Self.validateHints(magnetToSave)
			return PendingMagnetState(magnet: magnetToSave, destination: destinationToSave, id: id, parentIdentity: try directory.identity(), lockIdentity: lockIdentity, lease: lease)
		}
	}
	public func updateMagnet(_ state: PendingMagnetState, magnet: Magnet, destination: URL) async throws {
		let root = root
		try await worker.run(bulk: true) { _ in
			let directory = try StorageDirectory(root, create: false)
			let reservation = try StorageLease(directory: directory, path: ".native.lock"); defer { reservation.release() }
			try Self.validate(state, id: state.id, in: directory)
			guard state.magnet.hashes == magnet.hashes, try Self.record(state.id, in: directory) == nil else { throw StorageFailure.invalid("pending magnet identity") }
			try Self.writeMagnet(magnet, destination: destination, path: Self.magnetRecord(state.id), in: directory)
		}
	}
	public func retireMagnet(_ state: PendingMagnetState) async throws {
		let root = root
		try await worker.run(bulk: true) { _ in
			let directory = try StorageDirectory(root, create: false)
			let reservation = try StorageLease(directory: directory, path: ".native.lock"); defer { reservation.release() }
			try Self.validate(state, id: state.id, in: directory)
			try Self.removeMagnet(state.id, in: directory)
		}
	}
	public func prepare(id: String, restore: Bool, pending: PendingMagnetState? = nil) async throws -> PreparedTransferState {
		try Self.validateID(id); let root = root, event = event
		return try await worker.run(bulk: true) { _ in
			let directory = try StorageDirectory(root)
			let reservation = RepositoryReservation(try StorageLease(directory: directory, path: ".native.lock"))
			if let pending { try Self.validate(pending, id: id, in: directory) }
			else if try directory.inspect(Self.magnetRecord(id)) != nil, try Self.record(id, in: directory) == nil {
				throw StorageFailure.collision("retained pending magnet")
			}
			let published = try Self.record(id, in: directory)
			try Self.recoverStaging(id, published: published, in: directory)
			if let record = published {
				guard restore else { throw StorageFailure.collision("retained native state; restore or forget it first") }
				let child = try directory.child(record.directory)
				return PreparedTransferState(directory: child.url, id: id, name: record.directory, created: false, reservation: reservation, anchor: child, parentIdentity: try directory.identity())
			}
			let name = ".native-" + UUID().uuidString
			try Self.write(StagingRecord(version: 1, directory: name, identity: nil), to: Self.stagingPath(id), in: directory)
			event(.stagingDurable)
			let child = try directory.child(name, create: true)
			try Self.write(StagingRecord(version: 1, directory: name, identity: child.identity()), to: Self.stagingPath(id), in: directory)
			event(.checkpointDirectoryDurable)
			return PreparedTransferState(directory: child.url, id: id, name: name, created: true, reservation: reservation, anchor: child, parentIdentity: try directory.identity())
		}
	}
	public func publish(id: String, metadata: TorrentMetadata, state: PreparedTransferState) async throws {
		try Self.validateID(id); let root = root, event = event
		try await worker.run(bulk: true) { _ in
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
			event(.torrentDurable)
			let record = Record(version: 1, directory: state.name)
			try Self.write(record, to: id + ".native.plist", in: directory)
			event(.locatorDurable)
			try Self.recoverStaging(id, published: record, in: directory)
		}
	}
	public func abandon(_ state: PreparedTransferState) async throws {
		let root = root
		try await worker.run(bulk: true) { _ in
			let directory = try StorageDirectory(root, create: false)
			guard try state.parentIdentity.sameFile(directory.identity()) else { throw StorageFailure.recoveryRequired("session repository was replaced") }
			let lease = try state.reservation.take() ?? StorageLease(directory: directory, path: ".native.lock"); defer { lease.release() }
			guard state.created else { return }
			guard state.directory == directory.url.appendingPathComponent(state.name) else { throw StorageFailure.invalid("prepared state root") }
			// A failed directory flush may follow a successful publication. Retain that state.
			if try Self.record(state.id, in: directory)?.directory == state.name { return }
			guard try directory.child(state.name).identity().sameFile(state.anchor.identity()) else { throw StorageFailure.recoveryRequired("prepared state directory was replaced") }
			try Self.discardChild(state.name, in: directory)
			try Self.recoverStaging(state.id, published: nil, in: directory)
		}
	}
	/// Discards only recognised native state and the standard torrent; legacy resume files remain intact.
	public func discard(id: String, pending: PendingMagnetState? = nil) async throws {
		try Self.validateID(id); let root = root
		try await worker.run(bulk: true) { _ in
			let directory = try StorageDirectory(root)
			let lease = try StorageLease(directory: directory, path: ".native.lock"); defer { lease.release() }
			if let pending { try Self.validate(pending, id: id, in: directory) }
			let pendingLock = try pending?.lease ?? (directory.inspect(Self.magnetLock(id)) == nil ? nil : StorageLease(directory: directory, path: Self.magnetLock(id)))
			defer { withExtendedLifetime(pendingLock) {} }
			let published = try Self.record(id, in: directory)
			try Self.recoverStaging(id, published: published, in: directory)
			if let record = published {
				do { try Self.discardChild(record.directory, in: directory) }
				catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { } // An interrupted discard may have removed the directory.
			}
			for name in [id + ".native.plist", id + ".torrent"] {
				if let stamp = try directory.inspect(name) { try directory.remove(name, expected: stamp) }
			}
			try Self.removeMagnet(id, in: directory)
		}
	}
	private static func magnetRecord(_ id: String) -> String { id + ".native-magnet.plist" }
	private static func magnetLock(_ id: String) -> String { id + ".native-magnet.lock" }
	private static func stagingPath(_ id: String) -> String { id + ".native-stage.plist" }
	private static func write<T: Encodable>(_ record: T, to path: String, in directory: StorageDirectory) throws {
		let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
		try directory.atomic(encoder.encode(record), path: path)
	}
	private static func recoverStaging(_ id: String, published: Record?, in directory: StorageDirectory) throws {
		let path = stagingPath(id)
		guard let stamp = try directory.inspect(path) else { return }
		let stage = try PropertyListDecoder().decode(StagingRecord.self, from: directory.read(path, maximum: 4096))
		guard stage.version == 1, validCheckpointName(stage.directory), published == nil || published?.directory == stage.directory else {
			throw StorageFailure.invalid("native publication journal")
		}
		if published == nil, let child = try checkpointDirectory(stage.directory, in: directory) {
			if let expected = stage.identity {
				guard try expected.sameFile(child.identity()) else { throw StorageFailure.recoveryRequired("staged checkpoint directory was replaced") }
				try discardChild(stage.directory, in: directory, child: child)
			} else {
				guard try child.names().isEmpty else { throw StorageFailure.recoveryRequired("unrecorded checkpoint directory is not empty") }
				try directory.removeChild(stage.directory, expected: child)
			}
		}
		try directory.remove(path, expected: stamp)
	}
	private static func validate(_ state: PendingMagnetState, id: String, in directory: StorageDirectory) throws {
		guard state.id == id, try state.parentIdentity.sameFile(directory.identity()),
			let lock = try directory.inspect(magnetLock(id)), state.lockIdentity.sameFile(lock) else { throw StorageFailure.recoveryRequired("pending magnet repository was replaced") }
	}
	private static func removeMagnet(_ id: String, in directory: StorageDirectory) throws {
		for name in [magnetRecord(id), magnetLock(id)] {
			if let stamp = try directory.inspect(name) { try directory.remove(name, expected: stamp) }
		}
	}
	private static func validDestination(_ path: String) throws -> String {
		guard path.hasPrefix("/"), path.utf8.count <= 4096, !path.utf8.contains(0) else { throw StorageFailure.invalid("absolute destination") }
		return path
	}
	private static func writeMagnet(_ magnet: Magnet, destination: URL, path: String, in directory: StorageDirectory, exclusive: Bool = false) throws {
		guard destination.isFileURL else { throw StorageFailure.invalid("absolute destination") }
		try validateHints(magnet)
		let uri = magnet.uri
		guard try Magnet(uri) == magnet else { throw MetadataError.invalid("invalid pending magnet") }
		let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
		let bytes = try encoder.encode(MagnetRecord(version: 1, uri: uri, destination: validDestination(destination.path)))
		guard bytes.count <= magnetRecordLimit else { throw StorageFailure.limit("pending magnet record") }
		try directory.atomic(bytes, path: path, exclusive: exclusive)
	}
	private static func validateHints(_ magnet: Magnet) throws {
		guard magnet.trackers.count <= 128, magnet.webSeeds.count <= 128, magnet.peers.count <= 128 else { throw MetadataError.limit("magnet discovery hints") }
	}
	private static func record(_ id: String, in directory: StorageDirectory) throws -> Record? {
		let name = id + ".native.plist"
		guard try directory.inspect(name) != nil else { return nil }
		let record = try PropertyListDecoder().decode(Record.self, from: directory.read(name, maximum: 4096))
		guard record.version == 1, validCheckpointName(record.directory) else { throw StorageFailure.invalid("native state record") }
		return record
	}
	private static func validCheckpointName(_ name: String) -> Bool {
		name.hasPrefix(".native-") && UUID(uuidString: String(name.dropFirst(8))) != nil
	}
	private static func checkpointDirectory(_ name: String, in directory: StorageDirectory) throws -> StorageDirectory? {
		do { return try directory.child(name) }
		catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { return nil }
	}
	private static func discardChild(_ name: String, in directory: StorageDirectory, child: StorageDirectory? = nil) throws {
		let child = try child ?? directory.child(name), lease = try StorageLease(directory: child); defer { lease.release() }
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
