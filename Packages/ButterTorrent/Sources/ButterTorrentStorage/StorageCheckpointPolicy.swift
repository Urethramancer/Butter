import Foundation

/// StorageCheckpointPolicy bounds newly verified progress awaiting a durable checkpoint.
public enum StorageCheckpointPolicy: Sendable {
	case immediate
	case batched(interval: TimeInterval, bytes: Int64)
	public static let managed = StorageCheckpointPolicy.batched(interval: 1, bytes: 16 * 1_048_576)
	func validate() throws {
		if case .batched(let interval, let bytes) = self {
			guard interval.isFinite, interval > 0, interval <= 3600, (1...16_777_216).contains(bytes) else { throw StorageFailure.invalid("checkpoint policy") }
		}
	}
}

/// StorageCheckpointClock supplies monotonic, cancellable checkpoint deadlines.
public protocol StorageCheckpointClock: Sendable {
	func now() -> TimeInterval
	func sleep(for seconds: TimeInterval) async throws
}
public struct ContinuousStorageCheckpointClock: StorageCheckpointClock {
	public init() {}
	public func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
	public func sleep(for seconds: TimeInterval) async throws { try await Task.sleep(for: .seconds(max(0, seconds))) }
}

// Timer/worker admission failures must also reach callers when no disk job ran.
final class StorageCheckpointFailures: @unchecked Sendable {
	private let lock = NSLock()
	private var value: (any Error)?
	var error: (any Error)? { lock.withLock { value } }
	func set(_ error: (any Error)?) { lock.withLock { value = error } }
}

extension TorrentStorage {
	func armCheckpointTimer(_ deadline: TimeInterval?) {
		guard let deadline, checkpointTimer == nil, !closing else { return }
		let token = UUID(), clock = checkpointClock
		checkpointTimerID = token
		checkpointTimerDeadline = deadline
		checkpointTimer = Task { [weak self] in
			var next = deadline
			do {
				while !Task.isCancelled {
					let delay = next - clock.now()
					if delay > 0 { try await clock.sleep(for: delay) } else { try Task.checkCancellation() }
					guard let self, let deadline = await self.checkpointExpired(token) else { return }
					next = deadline
				}
			} catch { await self?.checkpointTimerFailed(token, error: error) }
		}
	}
	private func checkpointTimerFinished(_ token: UUID) {
		if checkpointTimerID == token { checkpointTimer = nil; checkpointTimerID = nil; checkpointTimerDeadline = nil }
	}
	private func checkpointTimerFailed(_ token: UUID, error: Error) {
		guard checkpointTimerID == token else { return }
		if !(error is CancellationError) { state.checkpointFailures.set(error) }
		checkpointTimerFinished(token)
	}
	private func checkpointExpired(_ token: UUID) async -> TimeInterval? {
		guard checkpointTimerID == token, !closing, !Task.isCancelled else { return nil }
		do {
			let deadline = try await worker.run { [state] cancellation in
				try state.ready(); try cancellation.check()
				if let deadline = state.checkpointDeadline, deadline <= state.checkpointClock.now() { try state.save() }
				return state.checkpointDeadline
			}
			if deadline == nil { checkpointTimerFinished(token) }
			else if checkpointTimerID == token { checkpointTimerDeadline = deadline }
			return deadline
		} catch {
			// save() retains pending progress and latches failures for the next caller.
			checkpointTimerFailed(token, error: error); return nil
		}
	}
	func drainCheckpointTimer() async {
		let task = checkpointTimer; checkpointTimer = nil; checkpointTimerID = nil; checkpointTimerDeadline = nil
		task?.cancel(); await task?.value
	}
	/// Flushes payload before publishing all verified progress. Failed saves can be retried.
	public func flush(retryFailed: Bool = true) async throws {
		let deadline = checkpointTimerDeadline
		await drainCheckpointTimer()
		do { try await worker.run { [state] _ in try state.ready(allowCheckpointRetry: retryFailed); try state.save() } }
		catch { armCheckpointTimer(deadline); throw error }
	}
}

extension StorageState {
	var checkpointDeadline: TimeInterval? {
		guard checkpointError == nil, let pendingSince, case .batched(let interval, _) = checkpointPolicy else { return nil }
		return pendingSince + interval
	}
	func committedContains(_ piece: Int) -> Bool { committedVerified[piece / 8] & (128 >> (piece % 8)) != 0 }
	func payloadBytes(_ piece: Int) throws -> Int64 {
		let length = try layout.length(of: piece)
		var count: Int64 = 0
		for offset in stride(from: 0, to: length, by: 1_048_576) {
			for segment in try layout.segments(piece: piece, offset: offset, count: min(1_048_576, length - offset)) where !segment.padding { count += Int64(segment.count) }
		}
		return count
	}
	func newlyVerified(_ piece: Int) throws {
		let mask = UInt8(128 >> (piece % 8))
		if pendingVerified[piece / 8] & mask == 0 {
			pendingVerified[piece / 8] |= mask; pendingVerifiedBytes += try payloadBytes(piece)
			if pendingSince == nil { pendingSince = checkpointClock.now() }
		}
		if case .batched(_, let bytes) = checkpointPolicy, pendingVerifiedBytes >= bytes { try save() }
	}
	func prepareVerification(of piece: Int) throws {
		if case .batched(_, let bytes) = checkpointPolicy, !record.contains(piece), pendingVerifiedBytes > 0,
			try payloadBytes(piece) > bytes - pendingVerifiedBytes { try save() }
	}
	func forgetPendingVerification(_ piece: Int) throws {
		let mask = UInt8(128 >> (piece % 8))
		if pendingVerified[piece / 8] & mask != 0 { pendingVerified[piece / 8] &= ~mask; pendingVerifiedBytes -= try payloadBytes(piece) }
	}
}
