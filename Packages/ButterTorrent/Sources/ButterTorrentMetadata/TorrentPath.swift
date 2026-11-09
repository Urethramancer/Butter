import Foundation

// Apple path sanitisation adapted from libtorrent's torrent_info.cpp and utf8.cpp
// at 6da363d2994f17c0b3c0450d124cf73a31a73847.
// See ../../THIRD_PARTY_NOTICES.txt. Keep this notice after dependency removal.
enum TorrentPath {
	static func component(_ data: Data, force: Bool) -> String {
		let bytes = Array(data)
		if bytes.isEmpty { return "_" }
		var offset = 0, added = 0, dots = 0, foundExtension = false
		var result = ""
		while offset < bytes.count {
			let start = offset
			let (point, length) = scalar(bytes, at: offset)
			offset += length
			if let point {
				if point == 0 || point == 47 || point == 92 || point == 0x061c || (0x200b...0x200f).contains(point)
					|| (0x202a...0x202e).contains(point) || (0x2060...0x2064).contains(point)
					|| (0x2066...0x2069).contains(point) || point == 0xfeff { continue }
			}
			guard let point, point >= 32, !(0x7f...0x9f).contains(point) else {
				result += "_"; added += 1; continue
			}
			result.unicodeScalars.append(UnicodeScalar(point)!)
			added += length
			if point == 46 { dots += 1 }
			if added >= 240 && !foundExtension {
				let lower = max(bytes.count - 9, start + 1)
				guard lower < bytes.count, let dot = (lower..<bytes.count).reversed().first(where: { bytes[$0] == 46 }) else { break }
				foundExtension = true; offset = dot
			}
		}
		if added == dots && added <= 2 { return force ? "_" : "" }
		return result.isEmpty ? "_" : result
	}

	private static func scalar(_ bytes: [UInt8], at offset: Int) -> (UInt32?, Int) {
		let first = bytes[offset]
		if first < 128 { return (UInt32(first), 1) }
		let length: Int
		switch first {
		case 0xc0...0xdf: length = 2
		case 0xe0...0xef: length = 3
		case 0xf0...0xf7: length = 4
		case 0xf8...0xfb: length = 5
		default: return (nil, 1)
		}
		guard length <= bytes.count - offset else { return (nil, bytes.count - offset) }
		guard length <= 4 else { return (nil, length) }
		var point = UInt32(first & (0x7f >> length))
		for index in 1..<length {
			let byte = bytes[offset + index]
			guard byte & 0xc0 == 0x80 else { return (nil, length) }
			point = point << 6 | UInt32(byte & 0x3f)
		}
		let minimum: UInt32 = length == 2 ? 0x80 : length == 3 ? 0x800 : 0x10000
		guard point >= minimum, point <= 0x10ffff, !(0xd800...0xdfff).contains(point) else { return (nil, length) }
		return (point, length)
	}
}
