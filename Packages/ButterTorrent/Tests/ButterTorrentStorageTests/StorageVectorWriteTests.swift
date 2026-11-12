import Foundation
import Darwin
import Testing
@testable import ButterTorrentStorage

@Suite struct StorageVectorWriteTests {
	@Test(arguments: ["success", "cancel", "zero", "full"]) func slicedBuffersSurviveInterruptsAndPartialWrites(_ mode: String) async throws {
		try await storageFixture { root in
			let directory = try StorageDirectory(root), file = try directory.openFile("payload", write: true)
			defer { close(file) }
			let bytes = Data(0..<14)
			let buffers = [bytes.prefix(2), bytes[2..<7], bytes.suffix(7)]
			var calls = 0, checks = 0, completions = 0, shapes: [[Int]] = []
			do {
				try StorageDirectory.writeVector(buffers, to: file, offset: 7, check: {
					checks += 1
					if mode == "cancel", calls == 2 { throw CancellationError() }
				}, didWrite: { completions += 1 }, write: { descriptor, vectors, count, offset in
					calls += 1
					shapes.append((0..<Int(count)).map { vectors[$0].iov_len })
					if calls == 1 { errno = EINTR; return -1 }
					if calls == 3, mode == "zero" { errno = 0; return 0 }
					if calls == 3, mode == "full" { errno = ENOSPC; return -1 }
					var remaining = calls == 2 ? 3 : calls == 3 ? 5 : 14
					var limited: [iovec] = []
					for index in 0..<Int(count) where remaining > 0 {
						let size = min(remaining, vectors[index].iov_len)
						limited.append(iovec(iov_base: vectors[index].iov_base, iov_len: size)); remaining -= size
					}
					return limited.withUnsafeBufferPointer { pwritev(descriptor, $0.baseAddress!, Int32($0.count), offset) }
				})
				#expect(mode == "success")
			} catch {
				if mode == "cancel" { #expect(error is CancellationError) }
				else { #expect((error as NSError).domain == NSPOSIXErrorDomain && (error as NSError).code == Int(mode == "full" ? ENOSPC : EIO)) }
			}
			let expected = mode == "success" ? bytes : bytes.prefix(3)
			#expect(try Data(contentsOf: root.appendingPathComponent("payload")) == Data(repeating: 0, count: 7) + expected)
			#expect(shapes.prefix(2) == [[2, 5, 7], [2, 5, 7]])
			if mode == "success" { #expect(shapes == [[2, 5, 7], [2, 5, 7], [4, 7], [6]] && completions == 3 && checks == 4) }
			else { #expect(completions == 1) }
		}
	}
}
