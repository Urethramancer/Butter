import Foundation

// A bounded, cancellable connector shared by tracker and discovery services.
actor PeerCandidateQueue<Item: Hashable & Sendable> {
	private let connect: @Sendable (Item) async -> Void
	private var pending: [Item] = []
	private var queued: Set<Item> = []
	private var worker: Task<Void, Never>?
	private var closed = false
	init(connect: @escaping @Sendable (Item) async -> Void) { self.connect = connect }
	func enqueue(_ items: [Item]) {
		guard !closed else { return }
		for item in items.shuffled() where !queued.contains(item) {
			if pending.count >= 2000 { queued.remove(pending.removeFirst()) }; pending.append(item); queued.insert(item)
		}
		start()
	}
	func halt() { closed = true; worker?.cancel() }
	func stop() async { halt(); await worker?.value; worker = nil; pending.removeAll(); queued.removeAll() }
	private func start() {
		guard worker == nil, !closed, !pending.isEmpty else { return }
		worker = Task { [weak self] in await self?.run() }
	}
	private func next() -> Item? {
		guard !closed, !Task.isCancelled, let item = pending.popLast() else { return nil }; queued.remove(item); return item
	}
	private func run() async {
		let connect = connect
		await withTaskGroup(of: Void.self) { group in
			for _ in 0..<2 { if let item = next() { group.addTask { await connect(item) } } }
			while await group.next() != nil {
				if Task.isCancelled { group.cancelAll(); break }
				if let item = next() { group.addTask { await connect(item) } }
			}
		}
		worker = nil; start()
	}
	deinit { worker?.cancel() }
}
