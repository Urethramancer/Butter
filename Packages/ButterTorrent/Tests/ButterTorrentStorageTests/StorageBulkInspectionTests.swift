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
	@Test func exactNamesKeepIndependentStampsAndCanOnlyBeConsumedOnce() throws {
		let composed = "é", decomposed = "e\u{301}"
		let bytes = inspectionRecord(Data(composed.utf8)) + inspectionRecord(Data(decomposed.utf8), inode: 8)
		let batch = try #require(StorageBulkInspection.decode(bytes, count: 2))
		let first = try #require(batch.take(composed))
		#expect(first.device == 42 && first.inode == 7 && first.size == 1234)
		#expect(first.modifiedSeconds == 100 && first.modifiedNanos == 17 && first.changedSeconds == 200 && first.changedNanos == 29)
		#expect(batch.take(composed) == nil)
		#expect(batch.take(decomposed)?.inode == 8)
		let onlyComposed = try #require(StorageBulkInspection.decode(inspectionRecord(Data(composed.utf8)), count: 1))
		#expect(onlyComposed.take(decomposed) == nil)
		#expect(onlyComposed.take(composed)?.inode == 7)
	}
	@Test func malformedOffsetsAndTruncatedBuffersCannotSupplyStamps() {
		let bytes = inspectionRecord(Data("a".utf8))
		for length in [0, 3, 28, 95, bytes.count - 1] {
			#expect(StorageBulkInspection.decode(Data(bytes.prefix(length)), count: 1) == nil)
		}
		for offset in [Int32.min, -1, 0, Int32.max] {
			#expect(StorageBulkInspection.decode(inspectionRecord(Data("a".utf8), referenceOffset: offset), count: 1) == nil)
		}
		#expect(StorageBulkInspection.decode(bytes + bytes, count: 2) == nil)
		#expect(StorageBulkInspection.decode(Data(count: StorageBulkInspection.bufferBytes + 1), count: 1) == nil)
	}
	@Test func unsafeAttributesFallBackAndEntryCountIsBounded() throws {
		for bytes in [inspectionRecord(Data("a".utf8), error: UInt32(EIO)),
			inspectionRecord(Data("a".utf8), common: StorageBulkInspection.common & ~UInt32(ATTR_CMN_CHGTIME)),
			inspectionRecord(Data("a".utf8), files: 0), inspectionRecord(Data([255])),
			inspectionRecord(Data("a/b".utf8)), inspectionRecord(Data("a".utf8), kind: fsobj_type_t(VLNK.rawValue)),
			inspectionRecord(Data("a".utf8), links: 2)] {
			let batch = try #require(StorageBulkInspection.decode(bytes, count: 1))
			#expect(batch.take("a") == nil)
		}
		let bytes = (0...StorageBulkInspection.maximumEntries).reduce(into: Data()) { $0.append(inspectionRecord(Data("file-\($1)".utf8))) }
		let batch = try #require(StorageBulkInspection.decode(bytes, count: StorageBulkInspection.maximumEntries + 1))
		#expect(batch.take("file-255") != nil)
		#expect(batch.take("file-256") == nil)
	}
	@Test func nativeBatchesMatchScalarInspectionsWithoutChangingEnumerationPosition() async throws {
		try await storageFixture { root in
			let names = (0..<300).map { "file-\($0)" }
			for name in names { try Data([1]).write(to: root.appendingPathComponent(name)) }
			let directory = try StorageDirectory(root), position = lseek(directory.fd, 0, SEEK_CUR)
			let batch = try #require(StorageBulkInspection.read(directory.fd))
			#expect(lseek(directory.fd, 0, SEEK_CUR) == position)
			var matches = 0
			for name in names {
				if let stamp = batch.take(name) { #expect(stamp == (try directory.inspect(name))); matches += 1 }
			}
			#expect(matches > 0 && matches <= StorageBulkInspection.maximumEntries)
			let scan = StorageStampScan()
			for name in names { #expect(try scan.inspect(name, in: directory) == directory.inspect(name)) }
			try Data([2, 3]).write(to: root.appendingPathComponent(names[0]))
			#expect(try scan.inspect(names[0], in: directory) == directory.inspect(names[0]))
			#expect(try StorageStampScan().inspect(names[0], in: directory) == directory.inspect(names[0]))
		}
	}
	@Test func scanFallbackRetainsManagedLinkAndTypeChecks() async throws {
		try await storageFixture { root in
			let directory = try StorageDirectory(root), scan = StorageStampScan()
			try Data([1]).write(to: root.appendingPathComponent("shared"))
			try FileManager.default.linkItem(at: root.appendingPathComponent("shared"), to: root.appendingPathComponent("hard"))
			try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("shared"))
			try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
			#expect(mkfifo(root.appendingPathComponent("fifo").path, 0o600) == 0)
			for index in 0..<8 {
				let name = "regular-\(index)"
				try Data([1]).write(to: root.appendingPathComponent(name))
				#expect(try scan.inspect(name, in: directory) == directory.inspect(name))
			}
			for name in ["shared", "hard"] { #expect(throws: StorageFailure.shared("hard-linked file")) { try scan.inspect(name, in: directory) } }
			for name in ["link", "folder", "fifo"] { #expect(throws: StorageFailure.invalid("managed path is not a regular file")) { try scan.inspect(name, in: directory) } }
		}
	}
}

