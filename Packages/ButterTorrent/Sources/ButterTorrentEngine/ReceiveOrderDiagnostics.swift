import Foundation
import ButterTorrentStorage

// Diagnostic-only metadata trace. Never retain payload or enable during timing.
enum ReceiveOrderDiagnostics {
	private static let output = Output()
	static func accepted(transfer: ObjectIdentifier, piece: Int, offset: Int, count: Int, length: Int) {
		guard StorageDiagnostics.enabled else { return }
		output.append("\(ProcessInfo.processInfo.systemUptime) \(transfer) \(piece) \(offset) \(count) \(length)\n")
	}
	private final class Output: @unchecked Sendable {
		private let lock = NSLock()
		private let file: FileHandle?
		init() {
			guard StorageDiagnostics.enabled, let path = ProcessInfo.processInfo.environment["BUTTER_RECEIVE_ORDER_TRACE"] else { file = nil; return }
			do {
				guard FileManager.default.createFile(atPath: path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
				file = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
			} catch { fatalError("Cannot open receive-order diagnostic: \(error)") }
		}
		func append(_ line: String) {
			guard let file else { return }
			lock.withLock {
				do { try file.write(contentsOf: Data(line.utf8)) }
				catch { fatalError("Cannot write receive-order diagnostic: \(error)") }
			}
		}
	}
}
