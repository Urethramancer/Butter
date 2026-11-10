import Foundation

/// TransportClock controls both monotonic time and cancellable protocol deadlines.
public protocol TransportClock: HTTPServiceClock {
	func sleep(for seconds: TimeInterval) async throws
}
public struct ContinuousTransportClock: TransportClock {
	public init() {}
	public func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
	public func sleep(for seconds: TimeInterval) async throws {
		guard seconds.isFinite, seconds >= 0, seconds <= 3600 else { throw NetworkFailure.invalid("deadline") }
		try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
	}
}

// All callbacks, cancellation and timeouts compete at one completion point.
final class NetworkWaiter<Value: Sendable>: @unchecked Sendable {
	private let lock = NSLock()
	private var result: Result<Value, Error>?
	private var continuation: CheckedContinuation<Value, Error>?
	@discardableResult func resolve(_ result: Result<Value, Error>) -> Bool {
		let state = lock.withLock { () -> (Bool, CheckedContinuation<Value, Error>?) in
			guard self.result == nil else { return (false, nil) }
			self.result = result
			let continuation = self.continuation; self.continuation = nil
			return (true, continuation)
		}
		state.1?.resume(with: result)
		return state.0
	}
	func value(timeout: TimeInterval, clock: any TransportClock) async throws -> Value {
		guard timeout.isFinite, timeout > 0, timeout <= 3600 else { throw NetworkFailure.invalid("deadline") }
		let timer = Task {
			do { try await clock.sleep(for: timeout); self.resolve(.failure(NetworkFailure.timedOut)) }
			catch is CancellationError { }
			catch { self.resolve(.failure(error)) }
		}
		defer { timer.cancel() }
		return try await withTaskCancellationHandler {
			try Task.checkCancellation()
			return try await withCheckedThrowingContinuation { continuation in
				lock.withLock {
					if let result { continuation.resume(with: result) }
					else { self.continuation = continuation }
				}
			}
		} onCancel: { self.resolve(.failure(CancellationError())) }
	}
}
