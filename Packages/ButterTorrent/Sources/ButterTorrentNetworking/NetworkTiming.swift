import Foundation

/// TransportClock controls both monotonic time and cancellable protocol deadlines.
public protocol TransportClock: HTTPServiceClock {
	func sleep(for seconds: TimeInterval) async throws
}
public struct ContinuousTransportClock: TransportClock {
	public init() {}
	public func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
	public func sleep(for seconds: TimeInterval) async throws {
		guard seconds.isFinite, seconds >= 0, seconds <= 86400 else { throw NetworkFailure.invalid("deadline") }
		try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
	}
}

// All callbacks, cancellation and timeouts compete at one completion point.
final class NetworkWaiter<Value: Sendable>: @unchecked Sendable {
	private let lock = NSLock()
	private var result: Result<Value, Error>?
	private var continuations: [CheckedContinuation<Value, Error>] = []
	var isPending: Bool { lock.withLock { result == nil } }
	@discardableResult func resolve(_ result: Result<Value, Error>) -> Bool {
		let state = lock.withLock { () -> (Bool, [CheckedContinuation<Value, Error>]) in
			guard self.result == nil else { return (false, []) }
			self.result = result
			let continuations = self.continuations; self.continuations.removeAll()
			return (true, continuations)
		}
		for continuation in state.1 { continuation.resume(with: result) }
		return state.0
	}
	func value(timeout: TimeInterval, clock: any TransportClock) async throws -> Value {
		guard timeout.isFinite, timeout > 0, timeout <= 86400 else { throw NetworkFailure.invalid("deadline") }
		let timer = Task {
			do { try await clock.sleep(for: timeout); self.resolve(.failure(NetworkFailure.timedOut)) }
			catch is CancellationError { }
			catch { self.resolve(.failure(error)) }
		}
		defer { timer.cancel() }
		return try await withTaskCancellationHandler {
			return try await withCheckedThrowingContinuation { continuation in
				lock.withLock {
					if let result { continuation.resume(with: result) }
					else if continuations.count < 128 { continuations.append(continuation) }
					else { continuation.resume(throwing: NetworkFailure.limit("completion waiters")) }
				}
			}
		} onCancel: { self.resolve(.failure(CancellationError())) }
	}
}
