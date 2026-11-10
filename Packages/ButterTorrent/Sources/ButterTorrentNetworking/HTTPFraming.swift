import Foundation
import zlib

let httpHeaderToken = Set("!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)

// Streaming HTTP/1 framing. No response data is returned before framing and decoding finish.
struct HTTPResponseParser {
	private enum State { case head, fixed(Int), untilEOF, chunkSize, chunk(Int), chunkEnd, trailers, done }
	private var state: State = .head
	private var buffer = Data()
	private var offset = 0
	private var wireBytes = 0
	private var headerBytes = 0
	private var informational = 0
	private var body = Data()
	private var inflater: HTTPInflater?
	private var status = 0
	private var headers: [String: String] = [:]
	private let maximum: Int
	init(maximumBytes: Int) { maximum = maximumBytes }
	var complete: Bool { if case .done = state { return true }; return false }
	mutating func feed(_ data: Data, eof: Bool = false) throws -> HTTPResponse? {
		guard data.count <= maximum * 8 + 65_536 - wireBytes else { throw HTTPServiceError.limit("HTTP wire bytes") }
		wireBytes += data.count
		if offset > 0 { buffer = Data(buffer.dropFirst(offset)); offset = 0 }
		buffer.append(data)
		while !complete {
			let available = buffer.count - offset
			switch state {
			case .head:
				guard let end = buffer.range(of: Data("\r\n\r\n".utf8), in: offset..<buffer.count) else {
					guard available + headerBytes <= 32_768 else { throw HTTPServiceError.limit("response headers") }
					return try incomplete(eof)
				}
				headerBytes += end.upperBound - offset
				guard headerBytes <= 32_768 else { throw HTTPServiceError.limit("response headers") }
				let head = buffer.subdata(in: offset..<end.lowerBound); offset = end.upperBound
				try parseHead(head)
			case .fixed(let remaining):
				guard available > 0 else { return try incomplete(eof) }
				let count = min(available, remaining)
				try append(buffer.subdata(in: offset..<(offset + count))); offset += count
				state = remaining == count ? .done : .fixed(remaining - count)
			case .untilEOF:
				try append(buffer.subdata(in: offset..<buffer.count)); offset = buffer.count
				if eof { state = .done } else { return nil }
			case .chunkSize:
				guard let line = try line(maximum: 1024) else { return try incomplete(eof) }
				guard let text = String(data: line, encoding: .ascii) else { throw HTTPServiceError.invalid("chunk size") }
				guard let size = text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first,
					!size.isEmpty, size.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
					let count = Int(size, radix: 16), count <= maximum else { throw HTTPServiceError.invalid("chunk size") }
				state = count == 0 ? .trailers : .chunk(count)
			case .chunk(let remaining):
				guard available > 0 else { return try incomplete(eof) }
				let count = min(available, remaining)
				try append(buffer.subdata(in: offset..<(offset + count))); offset += count
				state = count == remaining ? .chunkEnd : .chunk(remaining - count)
			case .chunkEnd:
				guard available >= 2 else { return try incomplete(eof) }
				guard buffer[offset] == 13, buffer[offset + 1] == 10 else { throw HTTPServiceError.invalid("chunk terminator") }
				offset += 2; state = .chunkSize
			case .trailers:
				guard let trailer = try line(maximum: 8192) else { return try incomplete(eof) }
				headerBytes += trailer.count + 2
				guard headerBytes <= 32_768 else { throw HTTPServiceError.limit("response trailers") }
				if trailer.isEmpty { state = .done }
				else {
					let (name, _) = try Self.header(trailer)
					guard !["content-length", "transfer-encoding", "content-encoding", "content-range"].contains(name) else { throw HTTPServiceError.invalid("framing field in trailers") }
				}
			case .done: break
			}
		}
		guard offset == buffer.count else { throw HTTPServiceError.invalid("bytes after HTTP message") }
		try inflater?.finish()
		return HTTPResponse(status: status, headers: headers, body: body)
	}
	private func incomplete(_ eof: Bool) throws -> HTTPResponse? {
		if eof { throw HTTPServiceError.invalid("truncated HTTP response") }
		return nil
	}
	private mutating func line(maximum: Int) throws -> Data? {
		guard let end = buffer.range(of: Data([13, 10]), in: offset..<buffer.count) else {
			guard buffer.count - offset <= maximum else { throw HTTPServiceError.limit("HTTP line length") }
			return nil
		}
		guard end.lowerBound - offset <= maximum else { throw HTTPServiceError.limit("HTTP line length") }
		let result = buffer.subdata(in: offset..<end.lowerBound); offset = end.upperBound
		return result
	}
	private mutating func append(_ data: Data) throws {
		let decoded = try inflater?.decode(data, maximumBytes: maximum - body.count) ?? data
		guard decoded.count <= maximum - body.count else { throw HTTPServiceError.limit("decoded response body") }
		body.append(decoded)
	}
	private mutating func parseHead(_ data: Data) throws {
		guard let text = String(data: data, encoding: .isoLatin1) else { throw HTTPServiceError.invalid("HTTP headers") }
		let lines = text.components(separatedBy: "\r\n"), first = lines[0].split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
		guard first.count >= 2, ["HTTP/1.0", "HTTP/1.1"].contains(first[0]), first[1].count == 3,
			let status = Int(first[1]), (100...599).contains(status), !lines[0].utf8.contains(where: { $0 < 32 || $0 == 127 }) else { throw HTTPServiceError.invalid("HTTP status") }
		var headers: [String: String] = [:]
		for line in lines.dropFirst() {
			let (name, value) = try Self.header(Data(line.utf8))
			if let previous = headers[name] {
				guard name != "content-length" && name != "transfer-encoding" else { throw HTTPServiceError.invalid("duplicate HTTP framing header") }
				headers[name] = previous + ", " + value
			} else { headers[name] = value }
		}
		if (100..<200).contains(status) {
			guard status != 101, informational < 4 else { throw HTTPServiceError.invalid("HTTP upgrade or informational count") }
			informational += 1; state = .head; return
		}
		self.status = status; self.headers = headers
		if status == 204 || status == 304 { state = .done; return }
		if let encoding = headers["content-encoding"], encoding.lowercased() != "identity" {
			inflater = try HTTPInflater(encoding: encoding.lowercased())
		}
		if let transfer = headers["transfer-encoding"] {
			guard transfer.lowercased() == "chunked", headers["content-length"] == nil else { throw HTTPServiceError.invalid("ambiguous HTTP body framing") }
			state = .chunkSize
		} else if let length = headers["content-length"] {
			guard !length.isEmpty, length.utf8.allSatisfy({ (48...57).contains($0) }), let count = Int(length), count <= maximum else { throw HTTPServiceError.limit("declared response body") }
			state = count == 0 ? .done : .fixed(count)
		} else { state = .untilEOF }
	}
	private static func header(_ bytes: Data) throws -> (String, String) {
		guard let colon = bytes.firstIndex(of: 58), colon > bytes.startIndex,
			bytes[..<colon].allSatisfy({ httpHeaderToken.contains($0) }),
			!bytes[bytes.index(after: colon)...].contains(where: { $0 == 0 || $0 == 10 || $0 == 13 || ($0 < 32 && $0 != 9) }) else { throw HTTPServiceError.invalid("HTTP header") }
		let name = String(decoding: bytes[..<colon], as: UTF8.self).lowercased()
		let value = String(data: bytes[bytes.index(after: colon)...], encoding: .utf8)?.trimmingCharacters(in: .whitespaces) ?? ""
		return (name, value)
	}
}

private final class HTTPInflater {
	private var stream = z_stream()
	private var ended = false
	init(encoding: String) throws {
		guard encoding == "gzip" || encoding == "deflate" else { throw HTTPServiceError.invalid("HTTP content encoding") }
		guard inflateInit2_(&stream, encoding == "gzip" ? 31 : 15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw HTTPServiceError.invalid("HTTP decompression setup") }
	}
	func decode(_ data: Data, maximumBytes: Int) throws -> Data {
		guard !ended || data.isEmpty else { throw HTTPServiceError.invalid("bytes after compressed HTTP body") }
		var result = Data(), output = [UInt8](repeating: 0, count: 32768)
		try data.withUnsafeBytes { input in
			stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress); stream.avail_in = uInt(data.count)
			repeat {
				let code = output.withUnsafeMutableBytes { buffer -> Int32 in
					stream.next_out = buffer.bindMemory(to: UInt8.self).baseAddress; stream.avail_out = uInt(buffer.count)
					return inflate(&stream, Z_NO_FLUSH)
				}
				let count = output.count - Int(stream.avail_out)
				guard count <= maximumBytes - result.count else { throw HTTPServiceError.limit("decoded response body") }
				result.append(contentsOf: output.prefix(count))
				if code == Z_STREAM_END { ended = true; guard stream.avail_in == 0 else { throw HTTPServiceError.invalid("compressed trailing bytes") }; break }
				guard code == Z_OK || (code == Z_BUF_ERROR && stream.avail_in == 0) else { throw HTTPServiceError.invalid("compressed HTTP body") }
				if stream.avail_in == 0 && stream.avail_out > 0 { break }
			} while true
		}
		return result
	}
	func finish() throws { guard ended else { throw HTTPServiceError.invalid("truncated compressed body") } }
	deinit { inflateEnd(&stream) }
}
