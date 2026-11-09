import Foundation

/// TorrentMetadata inspects v1, v2 and hybrid metadata without changing its info bytes.
public struct TorrentMetadata: Sendable {
	public struct File: Codable, Equatable, Sendable {
		public let index: Int
		public let path: String
		public let size: Int64
		public let pad: Bool
	}
	public struct Inspection: Codable, Equatable, Sendable {
		public let name: String
		public let `private`: Bool
		public let files: [File]
		public let hashes: [String]
	}
	public let document: BencodeDocument
	public let hashes: InfoHashes
	public let inspection: Inspection
	public let pieceLength: Int64
	public let trackerTiers: [[String]]
	public let webSeeds: [String]
	public let httpSeeds: [String]
	public let pieceLayers: [Data: Data]
	public var originalInfo: Data { document.infoBytes! }

	public init(_ data: Data, limits: BencodeLimits = .init()) throws {
		let document = try BencodeDocument(data, limits: limits)
		guard let info = document.root["info"], info.dictionary != nil, let originalInfo = document.infoBytes else {
			throw MetadataError.invalid("missing info dictionary")
		}
		if let version = info["meta version"], version.integer != 2 { throw MetadataError.invalid("unsupported meta version") }
		let v2 = info["meta version"] != nil
		let name = try Self.component(info["name.utf-8"] ?? info["name"], force: false)
		guard !name.isEmpty else { throw MetadataError.invalid("missing name") }
		guard let pieceLength = info["piece length"]?.integer, pieceLength > 0, pieceLength <= 1 << 29,
			!v2 || (pieceLength >= 16384 && (pieceLength & (pieceLength - 1)) == 0) else {
			throw MetadataError.invalid("invalid piece length")
		}
		var v1Files: [File] = []
		let hasV1 = info["pieces"] != nil
		if hasV1 {
			if let entries = info["files"]?.list {
				guard info["length"] == nil else { throw MetadataError.invalid("conflicting file layouts") }
				for entry in entries {
					guard let path = (entry["path.utf-8"] ?? entry["path"])?.list, !path.isEmpty else {
						throw MetadataError.invalid("missing file path")
					}
					let components = try path.map { try Self.component($0) }
					v1Files.append(File(index: v1Files.count, path: ([name] + components).joined(separator: "/"),
						size: try Self.length(entry), pad: entry["attr"]?.text?.contains("p") == true))
				}
			} else {
				v1Files = [File(index: 0, path: name, size: try Self.length(info), pad: false)]
			}
			let total = try Self.total(v1Files)
			guard let pieces = info["pieces"]?.bytes, pieces.count % 20 == 0,
				Int64(pieces.count / 20) == total / pieceLength + (total % pieceLength == 0 ? 0 : 1) else {
				throw MetadataError.invalid("piece count does not match file layout")
			}
		}
		var files = v1Files
		if v2 {
			guard let tree = info["file tree"]?.dictionary, !tree.isEmpty else { throw MetadataError.invalid("missing file tree") }
			var v2Files: [File] = []
			let single = tree.count == 1 && tree.values.first?.dictionary?.count == 1 && tree.values.first?[""] != nil && info["files"] == nil
			func walk(_ tree: [Data: BencodeValue], prefix: [String]) throws {
				for key in tree.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
					let component = try Self.component(.bytes(key))
					guard let node = tree[key]?.dictionary else { throw MetadataError.invalid("invalid file tree node") }
					let path = prefix + [component]
					if let leaf = node[Data()] {
						guard node.count == 1 else { throw MetadataError.invalid("file/directory conflict") }
						let size = try Self.length(leaf)
						guard leaf["attr"]?.text?.contains("p") != true else { throw MetadataError.invalid("padding in v2 file tree") }
						if size > 0 {
							guard let root = leaf["pieces root"]?.bytes, root.count == 32, root.contains(where: { $0 != 0 }) else {
								throw MetadataError.invalid("missing v2 pieces root")
							}
						}
						v2Files.append(File(index: v2Files.count, path: path.joined(separator: "/"), size: size, pad: false))
						// Match the reference layout, including virtual tail padding in v2-only metadata.
						if size % pieceLength != 0 {
							let padding = pieceLength - size % pieceLength
							v2Files.append(File(index: v2Files.count, path: "\(name)/.pad/\(padding)", size: padding, pad: true))
						}
					} else { try walk(node, prefix: path) }
				}
			}
			try walk(tree, prefix: single ? [] : [name])
			if hasV1 {
				if v2Files.count == v1Files.count + 1 && v2Files.last?.pad == true { v2Files.removeLast() }
				guard v2Files == v1Files else { throw MetadataError.invalid("inconsistent hybrid file layouts") }
			}
			files = v2Files
		} else if info["file tree"] != nil { throw MetadataError.invalid("file tree requires meta version 2") }
		guard !files.isEmpty, hasV1 || v2 else { throw MetadataError.invalid("no files or hashes") }
		_ = try Self.total(files)
		let realPaths = files.filter { !$0.pad }.map(\.path)
		guard Set(realPaths).count == realPaths.count else { throw MetadataError.invalid("duplicate file paths") }
		let digest = TorrentHasher.hash(originalInfo)
		let hashes = try InfoHashes(v1: hasV1 ? digest.sha1 : nil, v2: v2 ? digest.sha256 : nil)
		self.document = document; self.hashes = hashes; self.pieceLength = pieceLength
		inspection = Inspection(name: name, private: (info["private"]?.integer ?? 0) != 0, files: files, hashes: hashes.hex)
		let tiers = document.root["announce-list"]?.list?.compactMap { tier -> [String]? in
			guard let entries = tier.list else { return nil }
			let urls = entries.compactMap(\.text).filter { !$0.isEmpty }
			return urls.isEmpty ? nil : urls
		} ?? []
		trackerTiers = tiers.isEmpty ? document.root["announce"]?.text.map { [[$0]] } ?? [] : tiers
		webSeeds = Self.urls(document.root["url-list"])
		httpSeeds = Self.urls(document.root["httpseeds"])
		var layers: [Data: Data] = [:]
		if let layerNode = document.root["piece layers"] {
			guard let fields = layerNode.dictionary else { throw MetadataError.invalid("invalid piece layers") }
			for (root, layer) in fields {
				guard root.count == 32, let bytes = layer.bytes, bytes.count % 32 == 0 else { throw MetadataError.invalid("invalid piece layer") }
				layers[root] = bytes
			}
		}
		pieceLayers = layers
	}

	/// Reads at most the configured metadata bound, even when the file changes during reading.
	public init(contentsOf url: URL, limits: BencodeLimits = .init()) throws {
		guard limits.bytes >= 0, limits.bytes < Int.max else { throw MetadataError.limit("byte") }
		let handle = try FileHandle(forReadingFrom: url)
		defer { try? handle.close() }
		var data = Data()
		while true {
			try Task.checkCancellation()
			let chunk = try handle.read(upToCount: min(65536, limits.bytes - data.count + 1)) ?? Data()
			if chunk.isEmpty { break }
			guard chunk.count <= limits.bytes - data.count else { throw MetadataError.limit("byte") }
			data.append(chunk)
		}
		try self.init(data, limits: limits)
	}
	private static func urls(_ node: BencodeValue?) -> [String] {
		if let text = node?.text { return [text] }
		return node?.list?.compactMap(\.text) ?? []
	}
	private static func component(_ value: BencodeValue?, force: Bool = true) throws -> String {
		guard let bytes = value?.bytes, force || !bytes.isEmpty else { throw MetadataError.invalid("missing path component") }
		return TorrentPath.component(bytes, force: force)
	}
	private static func length(_ value: BencodeValue) throws -> Int64 {
		guard value.dictionary != nil, let size = value["length"]?.integer, size >= 0 else { throw MetadataError.invalid("invalid file length") }
		return size
	}
	private static func total(_ files: [File]) throws -> Int64 {
		var total: Int64 = 0
		for file in files {
			let sum = total.addingReportingOverflow(file.size)
			guard !sum.overflow else { throw MetadataError.invalid("overflowing file layout") }
			total = sum.partialValue
		}
		return total
	}
}
