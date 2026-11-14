import Foundation
import Darwin

// Idle descriptors have a process-wide cap in addition to the eight active
// handles per disk job. Exhaustion falls back to the existing open/close path.
final class StorageWriteDescriptorBudget: @unchecked Sendable {
	static let shared = StorageWriteDescriptorBudget(maximum: 32)
	private let lock = NSLock()
	private let maximum: Int
	private var used = 0
	init(maximum: Int) { self.maximum = maximum }
	func reserve() -> Bool { lock.withLock { guard used < maximum else { return false }; used += 1; return true } }
	func release() { lock.withLock { used -= 1 } }
}

// Confined to one owner's disk worker. Taking a handle transfers ownership to
// the existing job-local cache; returning it transfers ownership back here.
final class StorageWriteDescriptors {
	private struct Entry { let directory: StorageDirectory; let path: String; let file: Int32; let stamp: FileStamp }
	private let budget: StorageWriteDescriptorBudget
	private var entries: [Int: Entry] = [:]
	private var order: [Int] = []
	var count: Int { entries.count }
	init(budget: StorageWriteDescriptorBudget = .shared) { self.budget = budget }
	deinit { removeAll() }
	func take(_ index: Int, directory: StorageDirectory, path: String, expected: FileStamp?, profile: StorageWriteProfile?) throws -> Int32? {
		guard let entry = entries.removeValue(forKey: index) else { return nil }
		order.removeAll { $0 == index }; budget.release()
		do {
			// Compare exact path bytes: canonical Unicode equivalence does not make
			// two POSIX names interchangeable on every supported filesystem.
			guard entry.directory === directory, entry.path.utf8.elementsEqual(path.utf8), let expected, entry.stamp.sameFile(expected) else {
				close(entry.file, profile: profile); return nil
			}
			// This hint only selects a candidate. The caller must still inspect
			// the descriptor and current pathname before writing any payload.
			try directory.requireWriteAccess(path)
			profile?.count("persistentDescriptorHits")
			StorageDiagnostics.count(.writePersistentDescriptorHits)
			return entry.file
		} catch { close(entry.file, profile: profile); throw error }
	}
	func put(_ index: Int, file: Int32, directory: StorageDirectory, path: String, stamp: FileStamp, profile: StorageWriteProfile?) {
		if entries[index] != nil { evict(index, profile: profile) }
		if entries.count == 8 { evict(order[0], profile: profile) }
		guard budget.reserve() else { close(file, profile: profile); return }
		entries[index] = Entry(directory: directory, path: path, file: file, stamp: stamp); order.append(index)
	}
	func removeAll(profile: StorageWriteProfile? = nil) {
		for index in order { if let entry = entries.removeValue(forKey: index) { budget.release(); close(entry.file, profile: profile) } }
		order.removeAll()
	}
	private func evict(_ index: Int, profile: StorageWriteProfile?) {
		guard let entry = entries.removeValue(forKey: index) else { return }
		order.removeAll { $0 == index }; budget.release(); close(entry.file, profile: profile)
	}
	private func close(_ file: Int32, profile: StorageWriteProfile?) {
		let previous = profile?.enter(.cleanup)
		Darwin.close(file); profile?.count("descriptorCloses")
		StorageDiagnostics.count(.writeDescriptorCloses)
		profile?.enter(previous)
	}
}

extension StorageState {
	func finishWriteDescriptors(_ files: [Int: Int32], retaining: Bool, profile: StorageWriteProfile?) {
		profile?.enter(.cleanup)
		for (index, file) in files {
			if retaining, let stamp = record.stamps[index] {
				let (directory, path) = location(index)
				writeDescriptors.put(index, file: file, directory: directory, path: path, stamp: stamp, profile: profile)
			} else { close(file); profile?.count("descriptorCloses"); StorageDiagnostics.count(.writeDescriptorCloses) }
		}
	}
}
