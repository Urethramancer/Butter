import Foundation
import Darwin
import Testing
@testable import ButterTorrentStorage

private func inspectionRecord(_ name: Data, inode: UInt64 = 7, error: UInt32 = 0,
	common: UInt32 = StorageBulkInspection.common, files: UInt32 = StorageBulkInspection.files,
	referenceOffset: Int32? = nil, kind: fsobj_type_t = fsobj_type_t(VREG.rawValue), links: UInt32 = 1) -> Data {
	var bytes = Data()
	func append<T>(_ value: T) { var value = value; withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) } }
	let header = 96, length = (header + name.count + 1 + 7) & ~7
	append(UInt32(length))
	var returned = attribute_set_t(); returned.commonattr = common; returned.fileattr = files
	append(returned); append(error)
	append(attrreference_t(attr_dataoffset: referenceOffset ?? 68, attr_length: UInt32(name.count + 1)))
	append(dev_t(42)); append(kind)
	append(timespec(tv_sec: 100, tv_nsec: 17)); append(timespec(tv_sec: 200, tv_nsec: 29))
	append(inode); append(links); append(off_t(1234))
	bytes.append(name); bytes.append(0); bytes.append(Data(count: length - bytes.count))
	return bytes
}

@Suite struct StorageBulkInspectionTests {
	@Test func packedAttributesKeepCompactStampsAndRejectCanonicalAliases() throws {
		let a = "é", b = "e\u{301}"
		let bytes = inspectionRecord(Data(a.utf8))
		let entries = try #require(bytes.withUnsafeBytes { StorageBulkInspection.decode($0, count: 1) })
		let entry = try #require(entries[a]); let value = entry.stamp
		#expect(entries.count == 1 && entry.name.utf8.elementsEqual(a.utf8))
		#expect(value.device == 42 && value.inode == 7 && value.size == 1234)
		#expect(value.modifiedSeconds == 100 && value.modifiedNanos == 17 && value.changedSeconds == 200 && value.changedNanos == 29)
		let alias = bytes + inspectionRecord(Data(b.utf8), inode: 8)
		#expect(alias.withUnsafeBytes { StorageBulkInspection.decode($0, count: 2) } == nil)
		let decomposed = inspectionRecord(Data(b.utf8))
		let other = try #require(decomposed.withUnsafeBytes { StorageBulkInspection.decode($0, count: 1) })
		#expect(other[a]?.name.utf8.elementsEqual(b.utf8) == true)
	}
	@Test func malformedAndUnsupportedRecordsCannotSupplyTrustedStamps() throws {
		let valid = inspectionRecord(Data("a".utf8))
		for count in [0, 3, 28, 95, valid.count - 1] {
			#expect(valid.prefix(count).withUnsafeBytes { StorageBulkInspection.decode($0, count: 1) } == nil)
		}
		for offset in [Int32.min, -1, 0, Int32.max] {
			let bytes = inspectionRecord(Data("a".utf8), referenceOffset: offset)
			#expect(bytes.withUnsafeBytes { StorageBulkInspection.decode($0, count: 1) } == nil)
		}
		for bytes in [inspectionRecord(Data("a".utf8), error: UInt32(EIO)),
			inspectionRecord(Data("a".utf8), common: StorageBulkInspection.common & ~UInt32(ATTR_CMN_CHGTIME)),
			inspectionRecord(Data("a".utf8), files: 0), inspectionRecord(Data([255])), inspectionRecord(Data("a/b".utf8)), inspectionRecord(Data("a".utf8), kind: fsobj_type_t(VLNK.rawValue)), inspectionRecord(Data("a".utf8), links: 2)] {
			let entries = try #require(bytes.withUnsafeBytes { StorageBulkInspection.decode($0, count: 1) })
			#expect(entries.isEmpty)
		}
		let bytes = (0...StorageBulkInspection.maximumEntries).reduce(into: Data()) { $0.append(inspectionRecord(Data("file-\($1)".utf8))) }
		let entries = try #require(bytes.withUnsafeBytes { StorageBulkInspection.decode($0, count: StorageBulkInspection.maximumEntries + 1) })
		#expect(entries.count == StorageBulkInspection.maximumEntries)
		let duplicate = valid + valid
		#expect(duplicate.withUnsafeBytes { StorageBulkInspection.decode($0, count: 2) } == nil)
	}
	@Test func nativeBatchesMatchIndividualInspectionsAndFallbackBeyondTheBound() async throws {
		try await storageFixture { root in
			let names = (0..<300).map { "file-\($0)" }
			for name in names { try Data([1]).write(to: root.appendingPathComponent(name)) }
			let directory = try StorageDirectory(root), position = lseek(directory.fd, 0, SEEK_CUR)
			let batch = try #require(StorageBulkInspection.read(directory.fd))
			#expect(!batch.isEmpty && batch.count <= StorageBulkInspection.maximumEntries)
			#expect(lseek(directory.fd, 0, SEEK_CUR) == position)
			for (name, value) in batch {
				#expect(value.name.utf8.elementsEqual(name.utf8))
				#expect(value.stamp == (try directory.inspect(name)))
			}
			let scan = StorageStampScan()
			for name in names { #expect(try scan.inspect(name, in: directory) == directory.inspect(name)) }
			#expect(try scan.inspect("missing", in: directory) == nil)
			try Data([2, 3]).write(to: root.appendingPathComponent(names[0]))
			#expect(try scan.inspect(names[0], in: directory) == directory.inspect(names[0]))
			#expect(try StorageStampScan().inspect(names[0], in: directory) == directory.inspect(names[0]))
		}
	}
	@Test func batchesRetainManagedLinkAndTypeChecksWithoutRejectingUnrelatedEntries() async throws {
		try await storageFixture { root in
			let directory = try StorageDirectory(root)
			try Data([1]).write(to: root.appendingPathComponent("regular"))
			try Data([2]).write(to: root.appendingPathComponent("shared"))
			try FileManager.default.linkItem(at: root.appendingPathComponent("shared"), to: root.appendingPathComponent("hard"))
			try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("regular"))
			try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
			#expect(mkfifo(root.appendingPathComponent("fifo").path, 0o600) == 0)
			let scan = StorageStampScan()
			for index in 0..<8 {
				let name = "regular-\(index)"
				try Data([1]).write(to: root.appendingPathComponent(name))
				#expect(try scan.inspect(name, in: directory) == directory.inspect(name))
			}
			#expect(try scan.inspect("regular", in: directory) == directory.inspect("regular"))
			for name in ["shared", "hard"] { #expect(throws: StorageFailure.shared("hard-linked file")) { try scan.inspect(name, in: directory) } }
			for name in ["link", "folder", "fifo"] { #expect(throws: StorageFailure.invalid("managed path is not a regular file")) { try scan.inspect(name, in: directory) } }
			try FileManager.default.moveItem(at: root.appendingPathComponent("regular"), to: root.appendingPathComponent("retained"))
			try Data([3]).write(to: root.appendingPathComponent("regular"))
			#expect(try StorageStampScan().inspect("regular", in: directory) == directory.inspect("regular"))
		}
	}
}
