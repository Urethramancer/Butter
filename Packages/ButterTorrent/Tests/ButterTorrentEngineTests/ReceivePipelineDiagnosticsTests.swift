import Foundation
import Testing
@testable import ButterTorrentEngine

private final class PipelineTestState: @unchecked Sendable {
	let lock = NSLock()
	var time: UInt64 = 0
	var calls = 0
	var values: [String: Int64] = [:]
	func tick() -> UInt64 { lock.withLock { time += 10; return time } }
	func merge(_ values: [String: Int64]) { lock.withLock { calls += 1; for (key, amount) in values { self.values[key, default: 0] += amount } } }
}

@Suite struct ReceivePipelineDiagnosticsTests {
	@Test func elapsedBudgetsAndFinalisationAreDeterministic() {
		let state = PipelineTestState()
		let sample = ReceivePipelineSample(kind: .dispatch, timed: true, clock: state.tick, sink: state.merge)
		sample.enteredEngine(); sample.enteredEngine()
		let started = sample.tick(); sample.end(.storageWrite, since: started)
		sample.finish("succeeded"); sample.finish("failed")
		#expect(state.calls == 1)
		#expect(state.values["dispatch.stage.actorEntry.elapsedNs"] == 10)
		#expect(state.values["dispatch.stage.actorEntry.calls"] == 1)
		#expect(state.values["dispatch.stage.storageWrite.elapsedNs"] == 10)
		#expect(state.values["dispatch.total.elapsedNs"] == 40)
		#expect(state.values["dispatch.other.elapsedNs"] == 20)
		#expect(state.values["dispatch.overlapErrors"] == nil)
	}
	@Test(arguments: ["failed", "cancelled"]) func errorsAndCountsOnlyNeverReadClocks(_ outcome: String) {
		let state = PipelineTestState()
		let sample = ReceivePipelineSample(kind: .dispatch, timed: false, clock: { Issue.record("Counts-only read a clock"); return 0 }, sink: state.merge)
		sample.enteredEngine(); sample.end(.diskAdmission, since: sample.tick()); sample.histogram("blocks", 7)
		sample.finish(outcome)
		#expect(state.values["dispatch.outcome." + outcome] == 1)
		#expect(state.values["dispatch.blocks.power2.3"] == 1)
		#expect(state.values["dispatch.total.elapsedNs"] == nil)
		if !ReceivePipelineDiagnostics.enabled { #expect(ReceivePipelineDiagnostics.sample(.reader) == nil); #expect(ReceivePipelineDiagnostics.tick() == nil) }
	}
	@Test func concurrentOwnersMergeWithoutKeepingSamples() async {
		let state = PipelineTestState()
		await withTaskGroup(of: Void.self) { group in
			for _ in 0..<32 {
				group.addTask {
					let sample = ReceivePipelineSample(kind: .reader, timed: false, sink: state.merge)
					sample.count("payloadBytes", 16384); sample.finish("succeeded"); sample.finish("failed")
				}
			}
		}
		#expect(state.calls == 32)
		#expect(state.values["reader.samples"] == 32)
		#expect(state.values["reader.payloadBytes"] == 524288)
	}
	@Test func suppliedReadBoundariesDoNotReadAnotherClock() {
		let state = PipelineTestState()
		let sample = ReceivePipelineSample(kind: .reader, timed: true, clock: state.tick, sink: state.merge)
		sample.end(.streamRead, since: 10, until: 20)
		#expect(state.time == 10)
		sample.finish("succeeded")
		#expect(state.values["reader.total.elapsedNs"] == 10)
		#expect(state.values["reader.other.elapsedNs"] == 0)
	}
	@Test func invalidDispatchStillFinalisesBeforeStaging() async throws {
		try await transferFixture { fixture in
			let down = try await fixture.transfer("download", configuration: plainTransferConfiguration())
			let state = PipelineTestState()
			let sample = ReceivePipelineSample(kind: .dispatch, timed: true, clock: state.tick, sink: state.merge)
			do { try await down.receivedBlocks(UUID(), blocks: [], profile: sample); Issue.record("Invalid batch succeeded") }
			catch { sample.finish("failed") }
			#expect(state.values["dispatch.stage.actorEntry.calls"] == 1)
			#expect(state.values["dispatch.outcome.failed"] == 1)
			#expect(state.values["dispatch.stage.storageWrite.calls"] == nil)
		}
	}
	@Test(arguments: [1, 2]) func payloadDispatchAccountsForAdmissionWriteAndVerification(_ count: Int) async throws {
		try await transferFixture { fixture in
			var config = plainTransferConfiguration(); config.pipeline = 2
			let down = try await fixture.transfer("download", configuration: config)
			let peer = try await fixture.scripted(down); defer { peer.stream.close() }
			try await peer.seed(pieceCount: 3)
			let requests = try await peer.requests(2), id = await down.snapshot().peers[0].id
			let blocks = requests.prefix(count).map { IncomingPieceBlock(piece: $0.piece, offset: $0.offset, bytes: fixture.bytes.subdata(in: $0.offset..<($0.offset + $0.length))) }
			let state = PipelineTestState()
			let sample = ReceivePipelineSample(kind: .dispatch, timed: true, clock: state.tick, sink: state.merge)
			try await down.receivedBlocks(id, blocks: blocks, profile: sample); sample.finish("succeeded")
			#expect(state.values["dispatch.stage.actorEntry.calls"] == 1)
			#expect(state.values["dispatch.stage.diskAdmission.calls"] == 1)
			#expect(state.values["dispatch.stage.storageWrite.calls"] == 1)
			#expect(state.values["dispatch.stage.diskRelease.calls"] == 1)
			#expect(state.values["dispatch.stage.verification.calls", default: 0] == (count == 2 ? 1 : 0))
			#expect(state.values["dispatch.overlapErrors"] == nil)
		}
	}
}
