import Foundation

public struct PeerAddressRange: Sendable {
	public let first: IPAddress
	public let last: IPAddress
	public init(first: IPAddress, last: IPAddress) throws {
		guard first.isIPv6 == last.isIPv6, !last.bytes.lexicographicallyPrecedes(first.bytes) else { throw NetworkFailure.invalid("blocklist range") }
		self.first = first; self.last = last
	}
}

/// PeerAddressFilter merges inclusive ranges for bounded logarithmic peer admission checks.
public struct PeerAddressFilter: Sendable {
	private let ranges: [PeerAddressRange]
	public init() { ranges = [] }
	public init(ranges: [PeerAddressRange]) throws {
		guard ranges.count <= 1_000_000 else { throw NetworkFailure.limit("blocklist ranges") }
		let ordered = ranges.sorted {
			$0.first.bytes.count == $1.first.bytes.count ? $0.first.bytes.lexicographicallyPrecedes($1.first.bytes) : $0.first.bytes.count < $1.first.bytes.count
		}
		var merged: [PeerAddressRange] = []
		for range in ordered {
			if let previous = merged.last, previous.first.isIPv6 == range.first.isIPv6, !previous.last.bytes.lexicographicallyPrecedes(range.first.bytes) {
				let end = previous.last.bytes.lexicographicallyPrecedes(range.last.bytes) ? range.last : previous.last
				merged[merged.count - 1] = try PeerAddressRange(first: previous.first, last: end)
			} else { merged.append(range) }
		}
		self.ranges = merged
	}
	public func allows(_ address: IPAddress) -> Bool {
		var lower = 0, upper = ranges.count
		while lower < upper {
			let middle = lower + (upper - lower) / 2, first = ranges[middle].first.bytes
			if first.count < address.bytes.count || (first.count == address.bytes.count && !address.bytes.lexicographicallyPrecedes(first)) { lower = middle + 1 } else { upper = middle }
		}
		guard lower > 0 else { return true }; let range = ranges[lower - 1]
		return range.first.isIPv6 != address.isIPv6 || range.last.bytes.lexicographicallyPrecedes(address.bytes)
	}
}
