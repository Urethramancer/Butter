import Foundation
import Darwin

struct IPAddress: Comparable, Hashable {
	let octets: [UInt8]
	init?(_ text: String) {
		let text = text.trimmingCharacters(in: .whitespaces)
		if text.contains(":") {
			var address = in6_addr()
			guard text.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
			octets = withUnsafeBytes(of: address) { Array($0) }
		} else {
			let fields = text.split(separator: ".", omittingEmptySubsequences: false)
			guard fields.count == 4 else { return nil }
			let values = fields.compactMap { UInt8($0) }
			guard values.count == 4 else { return nil }; octets = values
		}
	}
	init(octets: [UInt8]) { self.octets = octets }
	static func < (lhs: Self, rhs: Self) -> Bool { lhs.octets.count != rhs.octets.count ? lhs.octets.count < rhs.octets.count : lhs.octets.lexicographicallyPrecedes(rhs.octets) }
	var text: String {
		if octets.count == 4 { return octets.map(String.init).joined(separator: ".") }
		var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
		_ = octets.withUnsafeBytes { inet_ntop(AF_INET6, $0.baseAddress, &buffer, socklen_t(buffer.count)) }
		return String(cString: buffer)
	}
	var successor: Self? {
		var next = octets
		for i in next.indices.reversed() { if next[i] < 255 { next[i] += 1; return Self(octets: next) }; next[i] = 0 }
		return nil
	}
}
struct IPRange: Codable, Equatable {
	var first: String; var last: String
}
struct BlocklistSource: Codable, Identifiable, Equatable {
	var id = UUID()
	var name: String
	var ranges: [IPRange]
}
enum Blocklist {
	static func parse(_ text: String) throws -> [IPRange] {
		var ranges: [IPRange] = []; var malformed: [Int] = []
		for (index, line) in text.components(separatedBy: .newlines).enumerated() {
			let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
			if value.isEmpty || value.hasPrefix("#") || value.hasPrefix(";") { continue }
			var first: IPAddress?, last: IPAddress?
			if value.contains("/") {
				let parts = value.split(separator: "/")
				if parts.count == 2, let ip = IPAddress(String(parts[0])), let prefix = Int(parts[1]), prefix >= 0, prefix <= ip.octets.count * 8 {
					var low = ip.octets, high = ip.octets
					for i in low.indices { let bits = max(0, min(8, prefix - i * 8)); let mask = UInt8(truncatingIfNeeded: 255 << (8 - bits)); low[i] &= mask; high[i] |= ~mask }
					first = IPAddress(octets: low); last = IPAddress(octets: high)
				}
			} else if value.contains("-") {
				// eMule: start - end , access , description; PeerGuardian: label:start-end.
				let pair = value.components(separatedBy: ",")[0].components(separatedBy: "-")
				if pair.count == 2 {
					first = IPAddress(pair[0]); last = IPAddress(pair[1])
					if first == nil, let suffix = pair[0].split(separator: ":").last { first = IPAddress(String(suffix)) }
				}
			} else { first = IPAddress(value); last = first }
			if let first, let last, first.octets.count == last.octets.count, first <= last { ranges.append(IPRange(first: first.text, last: last.text)) }
			else { malformed.append(index + 1) }
		}
		if !malformed.isEmpty { throw NSError(domain: "Butter.Blocklist", code: 1, userInfo: [NSLocalizedDescriptionKey: "Malformed blocklist input on lines \(malformed.prefix(12).map(String.init).joined(separator: ", ")). No changes were applied."]) }
		return merge(ranges)
	}
	static func merge(_ ranges: [IPRange]) -> [IPRange] {
		let sorted = ranges.compactMap { range -> (IPAddress, IPAddress)? in
			guard let first = IPAddress(range.first), let last = IPAddress(range.last), first.octets.count == last.octets.count, first <= last else { return nil }; return (first, last)
		}.sorted { $0.0 < $1.0 }
		var merged: [(IPAddress, IPAddress)] = []
		for range in sorted {
			if let last = merged.last, last.0.octets.count == range.0.octets.count, range.0 <= (last.1.successor ?? last.1) {
				merged[merged.count - 1].1 = max(last.1, range.1)
			} else { merged.append(range) }
		}
		return merged.map { IPRange(first: $0.0.text, last: $0.1.text) }
	}
	static func export(_ ranges: [IPRange]) -> String { merge(ranges).map { "\($0.first)-\($0.last)" }.joined(separator: "\n") + "\n" }
}
