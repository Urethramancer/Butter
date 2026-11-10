import Foundation
import ButterTorrentMetadata

protocol EngineOperations: Sendable {
	func perform(_ command: String, _ payload: [String: Any]) async throws -> Data
	func snapshot() async throws -> EngineSnapshot
	var creationProgress: Double { get }
	func cancelCreation()
}
extension EngineOperations {
	func perform(_ command: String) async throws -> Data { try await perform(command, [:]) }
}
// Serialise bounded metadata reads/hashing away from the app's main actor.
actor MetadataInspectionWorker {
	func inspect(_ url: URL) throws -> Data {
		try Task.checkCancellation()
		return try JSONEncoder().encode(TorrentMetadata(contentsOf: url).inspection)
	}
}

final class TorrentCreationWorker: @unchecked Sendable {
	private let storage: URL
	private let publish: @Sendable (Data, String) throws -> Void
	private let queue = DispatchQueue(label: "net.grimdork.Butter.creation", qos: .utility)
	private let lock = NSLock()
	private var active: UUID?
	private var cancelled = false
	private var fraction = 0.0
	private var waiters: [CheckedContinuation<Void, Never>] = []
	init(storage: URL, publish: @escaping @Sendable (Data, String) throws -> Void) { self.storage = storage; self.publish = publish }
	var progress: Double { lock.withLock { fraction } }
	func cancel() { lock.withLock { if active != nil { cancelled = true } } }
	private func cancel(_ id: UUID) { lock.withLock { if active == id { cancelled = true } } }
	func waitForCompletion() async {
		await withCheckedContinuation { continuation in
			let done = lock.withLock { if active == nil { return true }; waiters.append(continuation); return false }
			if done { continuation.resume() }
		}
	}

	func create(_ payload: [String: Any]) async throws -> Data {
		guard let id = payload["id"] as? String, (1...128).contains(id.utf8.count),
			id.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
			let source = payload["source"] as? String, !source.isEmpty, !source.utf8.contains(0) else {
			throw MetadataError.invalid("a valid transfer identifier and source are required")
		}
		let trackers: [String]
		if let value = payload["trackers"] {
			guard let values = value as? [String], values.allSatisfy({ !$0.utf8.contains(0) }) else { throw MetadataError.invalid("invalid trackers") }
			trackers = values
		} else { trackers = [] }
		var isPrivate = false
		if let value = payload["private"] {
			guard let number = value as? NSNumber, number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
				number.doubleValue >= Double(Int32.min), number.doubleValue <= Double(Int32.max) else { throw MetadataError.invalid("invalid private flag") }
			isPrivate = number.boolValue
		}
		let token = UUID(), privateFlag = isPrivate
		try lock.withLock {
			guard active == nil else { throw MetadataError.invalid("torrent creation is already in progress") }
			active = token; cancelled = false; fraction = 0
		}
		return try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { continuation in
				queue.async { [self] in
					let result = Result<Data, Error> {
						let sourceURL = URL(fileURLWithPath: source).standardizedFileURL
						let bytes = try TorrentCreator.create(source: sourceURL, trackers: trackers, isPrivate: privateFlag, progress: { value in
							self.lock.withLock { if self.active == token { self.fraction = value } }
						}, isCancelled: { self.lock.withLock { self.active != token || self.cancelled } })
						let output = storage.appendingPathComponent("\(id).torrent")
						let response = try JSONEncoder().encode(["source": output.path, "destination": sourceURL.deletingLastPathComponent().path])
						// Cancellation and publication have one ordering point. A committed file is success.
						try lock.withLock {
							guard active == token && !cancelled else { throw CancellationError() }
							try publish(bytes, id)
						fraction = 1
						}
						return response
					}
					let completed = lock.withLock {
						active = nil
						if case .failure = result { fraction = 0 }
						continuation.resume(with: result)
						let completed = waiters; waiters.removeAll(); return completed
					}
					for waiter in completed { waiter.resume() }
				}
			}
		} onCancel: { self.cancel(token) }
	}
}
