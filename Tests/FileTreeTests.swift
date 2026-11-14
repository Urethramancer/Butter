#if BUTTER_FILE_TREE_AVAILABLE
import Foundation

enum FileTreeTests {
	static func run() throws {
		let paths = ["Bundle/a.txt", "Bundle/dir/b.txt", "Bundle/dir/c.txt"]
		let files = paths.enumerated().map { index, path in
			TransferFile(index: index, path: path, original: index == 2 ? "Bundle/dir/old-c.txt" : path, size: 10, done: 0, selected: index != 2, pad: false)
		}
		let cases: [(String, Set<String>, [String], [Int], [Int])] = [
			("", [], ["Bundle", "Bundle/a.txt", "Bundle/dir", "Bundle/dir/b.txt", "Bundle/dir/c.txt"], [0, 1, 1, 2, 2], [0, 3, 0, 3, 9]),
			("", ["Bundle/dir"], ["Bundle", "Bundle/a.txt", "Bundle/dir"], [0, 1, 1], [0, 3, 6]),
			("", ["Bundle"], ["Bundle"], [0], [3]),
			("OLD-C", [], ["Bundle", "Bundle/dir", "Bundle/dir/c.txt"], [0, 1, 2], [0, 0, 9]),
			("b.txt", ["Bundle/dir"], ["Bundle", "Bundle/dir"], [0, 1], [0, 6]),
			("missing", [], [], [], [])
		]
		for (search, collapsed, ids, depths, padding) in cases {
			let rows = FileTreeEntry.visible(FileNode.tree(files), search: search, collapsed: collapsed)
			guard rows.map(\.id) == ids, rows.map(\.depth) == depths, rows.map(\.bottom) == padding else {
				throw NSError(domain: "FileTreeTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "File tree changed order, search, collapse state or nested spacing"])
			}
			if let root = rows.first { guard root.node.selection == .mixed else { throw CocoaError(.fileReadCorruptFile) } }
		}
	}
}
#endif
