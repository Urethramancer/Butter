import Foundation
import Testing
import ButterTorrentMetadata
import ButterTorrentNetworking
@testable import ButterTorrentStorage
@testable import ButterTorrentEngine

private extension TCPTransfer {
	var pendingUploadWork: Int { uploadJobs.count }
	func uploadAdmissionState() -> (queued: Int, controls: Int) {
		guard let peer = peers.values.first else { return (0, 0) }
		return (peer.uploads.count, peer.controls)
	}
	func exhaustControlBudget() {
		guard let peer = peers.values.first else { return }
		peer.controls = 8192; peer.window = clock.now()
	}
}

private func blockedUploadFixture(_ body: (TCPTransfer, WirePeer) async throws -> Void) async throws {
	try await transferFixture { fixture in
		let seed = try await fixture.transfer("seed", seed: true, clock: EngineClock())
		var reserved = Data(repeating: 0, count: 8); reserved[7] = 4
		let peer = try await fixture.scripted(seed, reserved: reserved)
		try await peer.send(.haveNone); try await peer.send(.interested)
		try await eventually { await seed.snapshot().peers.first?.choking == false }
		let worker = await fixture.stores[0].worker, entered = AsyncStream<Void>.makeStream(), release = DispatchSemaphore(value: 0)
		let blocker = Task { try await worker.run { _ in entered.continuation.yield(()); _ = release.wait(timeout: .now() + 6) } }
		defer { release.signal(); peer.stream.close() }
		try await engineDeadline { for await _ in entered.stream { return }; throw PeerFailure.closed }
		do { try await body(seed, peer) }
		catch { release.signal(); try await blocker.value; throw error }
		release.signal(); try await blocker.value
	}
}

@Suite struct UploadAdmissionTests {
	@Test(arguments: [false, true]) func cancellingAndReplacingPendingUploadsKeepsIndependentRequests(_ choke: Bool) async throws {
		try await transferFixture { fixture in
			let resources = try TransferResources(maximumDiskOperations: 1)
			let seed = try await fixture.transfer("seed", seed: true, clock: EngineClock(), resources: resources)
			let peer = try await fixture.scripted(seed); defer { peer.stream.close() }
			try await peer.send(.interested)
			while try await peer.next() != .unchoke {}
			let id = await seed.snapshot().peers[0].id
			let blocker = TransferDiskScope(resources: resources); try await blocker.acquire()
			var held = true
			do {
				let first = PeerBlock(piece: 0, offset: 0, length: 16384), second = PeerBlock(piece: 0, offset: 16384, length: 16384)
				try await seed.received(id, message: .request(first))
				try await seed.received(id, message: .request(second))
				try await eventually { await resources.snapshot().waitingDiskOperations == 1 }
				try await seed.received(id, message: .cancel(first))
				if choke {
					try await seed.received(id, message: .notInterested)
					try await seed.received(id, message: .interested)
					try await seed.received(id, message: .request(second))
				}
				try await seed.received(id, message: .request(first))
				await blocker.release(); held = false
				try await eventually { await seed.pendingUploadWork == 0 }
				// The marker follows all queued payloads, exposing stale or duplicate replies.
				try await seed.send(id, .keepAlive)
				var delivered: [PeerBlock] = []
				while true {
					let message = try await peer.next()
					if message == .keepAlive { break }
					if case .piece(let piece, let offset, let bytes) = message {
						delivered.append(PeerBlock(piece: piece, offset: offset, length: bytes.count))
						#expect(bytes == fixture.bytes[offset..<(offset + bytes.count)])
					}
				}
				#expect(delivered.count == 2 && Set(delivered) == [first, second])
				try await eventually { await seed.uploadAdmissionState().queued == 0 }
				#expect(await seed.snapshot().storageError == nil)
			} catch { if held { await blocker.release() }; throw error }
		}
	}
	@Test func advertisedWindowFitsMaximumSizedPayloadsWithoutBusyRejections() async throws {
		try await transferFixture { fixture in
			let resources = try TransferResources(maximumDiskOperations: 1)
			let seed = try await fixture.transfer("seed", seed: true, resources: resources)
			let blocker = TransferDiskScope(resources: resources); try await blocker.acquire()
			do {
				var reserved = Data(repeating: 0, count: 8); reserved[5] = 16; reserved[7] = 4
				let peer = try await fixture.scripted(seed, reserved: reserved); defer { peer.stream.close() }
				try await peer.send(.haveNone); try await peer.send(.interested)
				var advertised: Int?, unchoked = false
				while advertised == nil || !unchoked {
					let message = try await peer.next()
					if case .extended(0, let bytes) = message { advertised = Int(try #require(BencodeDocument(bytes).root["reqq"]?.integer)) }
					if case .unchoke = message { unchoked = true }
				}
				let count = try #require(advertised), id = await seed.snapshot().peers[0].id
				let before = await seed.uploadAdmissionState()
				for offset in 0..<count { try await seed.received(id, message: .request(PeerBlock(piece: 0, offset: offset, length: 16384))) }
				let after = await seed.uploadAdmissionState()
				#expect(after.queued == count, "The advertised queue must fit full-sized framed payloads")
				#expect(after.controls == before.controls, "Advertised payload requests must not be rejected as excess controls")
				await blocker.release()
			} catch { await blocker.release(); throw error }
		}
	}
	@Test func fullSizedUploadsReserveFramingBeforeDiskWorkWithoutGrowingTheQueue() async throws {
		try await blockedUploadFixture { seed, peer in
			for offset in 0..<32 { try await peer.send(.request(PeerBlock(piece: 0, offset: offset, length: 16384))) }
			var rejected: PeerBlock?
			while rejected == nil { if case .reject(let block) = try await peer.next() { rejected = block } }
			#expect(rejected == PeerBlock(piece: 0, offset: 31, length: 16384))
			#expect(await seed.uploadAdmissionState().queued == 31)
			#expect(await seed.snapshot().peers.count == 1)
			#expect(await seed.lastPeerError == nil)
		}
	}
	@Test func fullUploadQueueRejectsExcessWithoutDroppingThePeer() async throws {
		try await blockedUploadFixture { seed, peer in
			let before = await seed.uploadAdmissionState()
			for offset in 0..<33 { try await peer.send(.request(PeerBlock(piece: 0, offset: offset, length: 1))) }
			var rejected: PeerBlock?
			while rejected == nil { if case .reject(let block) = try await peer.next() { rejected = block } }
			#expect(rejected == PeerBlock(piece: 0, offset: 32, length: 1))
			let after = await seed.uploadAdmissionState()
			#expect(after.queued == 32 && after.controls == before.controls + 1)
			#expect(await seed.snapshot().peers.count == 1)
		}
	}
	@Test func admittedPayloadRequestsDoNotExhaustTheControlBudget() async throws {
		try await blockedUploadFixture { seed, _ in
			let id = await seed.snapshot().peers[0].id
			await seed.exhaustControlBudget()
			try await seed.received(id, message: .request(PeerBlock(piece: 0, offset: 0, length: 16384)))
			let state = await seed.uploadAdmissionState()
			#expect(state.queued == 1 && state.controls == 8192)
			await #expect(throws: PeerFailure.limit("control messages per second")) { try await seed.received(id, message: .interested) }
		}
	}
}
