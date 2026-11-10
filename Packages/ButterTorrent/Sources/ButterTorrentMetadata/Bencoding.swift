import Foundation

public enum MetadataError: Error, LocalizedError, Equatable, Sendable {
	case invalid(String)
	case limit(String)
	public var errorDescription: String? {
		switch self {
		case .invalid(let reason): "Invalid torrent metadata: \(reason)"
		case .limit(let reason): "Torrent metadata exceeds the \(reason) limit."
		}
	}
}

/// BencodeLimits bounds both parsing and encoding, including container overhead.
public struct BencodeLimits: Sendable {
	public var bytes: Int
	public var depth: Int
	public var values: Int
	public init(bytes: Int = 32 * 1024 * 1024, depth: Int = 100, values: Int = 1_000_000) {
		self.bytes = bytes; self.depth = depth; self.values = values
	}
}

/// BencodeValue stores byte strings and binary dictionary keys without text conversion.
public indirect enum BencodeValue: Equatable, Sendable {
	case integer(Int64)
	case bytes(Data)
	case list([BencodeValue])
	case dictionary([Data: BencodeValue])
	public subscript(_ key: String) -> BencodeValue? {
		guard case .dictionary(let fields) = self else { return nil }
		return fields[Data(key.utf8)]
	}
	public var integer: Int64? { if case .integer(let value) = self { return value }; return nil }
	public var bytes: Data? { if case .bytes(let value) = self { return value }; return nil }
	public var text: String? { bytes.flatMap { String(data: $0, encoding: .utf8) } }
	public var list: [Self]? { if case .list(let value) = self { return value }; return nil }
	public var dictionary: [Data: Self]? { if case .dictionary(let value) = self { return value }; return nil }

	/// Encodes dictionaries in byte order, rejecting values beyond the given limits.
	public func encoded(limits: BencodeLimits = .init()) throws -> Data {
		var writer = BencodeWriter(limits: limits)
		try writer.write(self, depth: 0)
		return writer.data
	}
}

/// BencodeDocument retains the exact original top-level info section for hashing.
public struct BencodeDocument: Sendable {
	public let root: BencodeValue
	public let original: Data
	public let infoRange: Range<Int>?
	public var infoBytes: Data? { infoRange.map { original.subdata(in: $0) } }
	public init(_ data: Data, limits: BencodeLimits = .init()) throws {
		guard limits.bytes >= 0, data.count <= limits.bytes else { throw MetadataError.limit("byte") }
		// Normalise indices: callers may supply a Data slice with a non-zero startIndex.
		let original = Data(data)
		var parser = BencodeParser(data: original, limits: limits)
		root = try parser.read(depth: 0)
		guard parser.offset == original.count else { throw MetadataError.invalid("trailing bytes") }
		self.original = original; infoRange = parser.infoRange
	}
	/// Decodes one bounded value and reports its end, retaining a binary message suffix.
	public static func prefix(_ data: Data, limits: BencodeLimits = .init()) throws -> (value: BencodeValue, length: Int) {
		guard data.count <= limits.bytes else { throw MetadataError.limit("byte") }
		var parser = BencodeParser(data: Data(data), limits: limits)
		let value = try parser.read(depth: 0); return (value, parser.offset)
	}
}

private struct BencodeParser {
	let data: Data
	let limits: BencodeLimits
	var offset = 0
	var count = 0
	var infoRange: Range<Int>?

	mutating func read(depth: Int) throws -> BencodeValue {
		guard depth <= limits.depth else { throw MetadataError.limit("nesting") }
		try consumeValue()
		guard offset < data.count else { throw MetadataError.invalid("truncated value") }
		let marker = data[offset]; offset += 1
		switch marker {
		case 105: // i
			let start = offset
			while offset < data.count && data[offset] != 101 { offset += 1 }
			guard offset < data.count else { throw MetadataError.invalid("unterminated integer") }
			let digits = data[start..<offset]; offset += 1
			guard !digits.isEmpty, digits.count <= 20,
				let text = String(data: digits, encoding: .ascii), let number = Int64(text),
				text == String(number) else { throw MetadataError.invalid("non-canonical or overflowing integer") }
			return .integer(number)
		case 108, 100: // l, d
			var list: [BencodeValue] = [], fields: [Data: BencodeValue] = [:]
			while offset < data.count && data[offset] != 101 {
				if marker == 108 { list.append(try read(depth: depth + 1)) }
				else {
					try consumeValue()
					let key = try readBytes()
					guard fields[key] == nil else { throw MetadataError.invalid("duplicate dictionary key") }
					let start = offset
					fields[key] = try read(depth: depth + 1)
					if depth == 0 && key == Data("info".utf8) { infoRange = start..<offset }
				}
			}
			guard offset < data.count else { throw MetadataError.invalid("unterminated container") }
			offset += 1
			return marker == 108 ? .list(list) : .dictionary(fields)
		case 48...57:
			offset -= 1
			return .bytes(try readBytes())
		default: throw MetadataError.invalid("unexpected bencode marker")
		}
	}
	mutating func consumeValue() throws {
		guard count < limits.values else { throw MetadataError.limit("value count") }
		count += 1
	}
	mutating func readBytes() throws -> Data {
		let start = offset
		var length = 0
		while offset < data.count && (48...57).contains(data[offset]) {
			let digit = Int(data[offset] - 48)
			guard length <= (Int.max - digit) / 10 else { throw MetadataError.invalid("overflowing byte length") }
			length = length * 10 + digit; offset += 1
		}
		guard offset > start, offset < data.count, data[offset] == 58,
			offset - start == 1 || data[start] != 48 else { throw MetadataError.invalid("invalid byte length") }
		offset += 1
		guard length <= data.count - offset else { throw MetadataError.invalid("truncated byte string") }
		let result = data.subdata(in: offset..<(offset + length)); offset += length
		return result
	}
}

private struct BencodeWriter {
	let limits: BencodeLimits
	var data = Data()
	var count = 0
	mutating func append(_ bytes: Data) throws {
		guard bytes.count <= limits.bytes - data.count else { throw MetadataError.limit("byte") }
		data.append(bytes)
	}
	mutating func write(_ value: BencodeValue, depth: Int) throws {
		guard depth <= limits.depth else { throw MetadataError.limit("nesting") }
		guard count < limits.values else { throw MetadataError.limit("value count") }
		count += 1
		switch value {
		case .integer(let number): try append(Data("i\(number)e".utf8))
		case .bytes(let bytes):
			try append(Data("\(bytes.count):".utf8)); try append(bytes)
		case .list(let values):
			try append(Data([108]))
			for value in values { try write(value, depth: depth + 1) }
			try append(Data([101]))
		case .dictionary(let fields):
			try append(Data([100]))
			for key in fields.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
				try write(.bytes(key), depth: depth + 1)
				try write(fields[key]!, depth: depth + 1)
			}
			try append(Data([101]))
		}
	}
}
