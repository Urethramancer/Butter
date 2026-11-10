import Foundation
import Testing
@testable import ButterTorrentNetworking

private func natReply(_ opcode: UInt8, epoch: UInt32, lifetime: UInt32? = nil, result: UInt16 = 0) -> Data {
	var bytes = Data([0, opcode | 128]); PacketBytes.append(result, to: &bytes); PacketBytes.append(epoch, to: &bytes)
	if let lifetime { PacketBytes.append(UInt16(6881), to: &bytes); PacketBytes.append(UInt16(lifetime == 0 ? 0 : 6881), to: &bytes); PacketBytes.append(lifetime, to: &bytes) }
	else { bytes.append(contentsOf: [1, 2, 3, 4]) }
	return bytes
}

@Suite struct NATPMPTests {
	@Test func mappingRenewalRebootAndRemoval() async throws {
		let packets = try InjectedDatagrams(), clock = ManualTransportClock(), gateway = try NetworkEndpoint("192.168.1.1", port: 5351)
		let dispatcher = UDPDispatcher(transport: packets, clock: clock), client = try NATPMPClient(dispatcher: dispatcher, gateway: gateway, clock: clock)
		let create = Task { try await client.map(.tcp, internalPort: 6881, externalPort: 6881, lifetime: 60) }
		let request = try await packets.nextSent()
		let requestedLifetime = try PacketBytes.uint32(request.0, at: 8)
		#expect(request.0.prefix(4) == Data([0, 2, 0, 0]) && requestedLifetime == 60)
		await packets.inject(natReply(2, epoch: 100, lifetime: 60), source: gateway)
		#expect(try await create.value.renewAt == 130)
		try await client.renewIfDue()
		#expect(await packets.sentCount == 1)
		clock.advance(30)
		let renew = Task { try await client.renewIfDue() }
		_ = try await packets.nextSent(); await packets.inject(natReply(2, epoch: 130, lifetime: 60), source: gateway); try await renew.value
		let address = Task { try await client.externalAddress() }
		_ = try await packets.nextSent(); await packets.inject(natReply(0, epoch: 1), source: gateway)
		#expect(try await address.value.description == "1.2.3.4")
		#expect(await client.requiresRemapping)
		let recreate = Task { try await client.renewIfDue() }
		_ = try await packets.nextSent(); await packets.inject(natReply(2, epoch: 1, lifetime: 60), source: gateway); try await recreate.value
		#expect(await client.requiresRemapping == false)
		let remove = Task { try await client.remove(.tcp) }
		let deletion = try await packets.nextSent()
		#expect(try PacketBytes.uint32(deletion.0, at: 8) == 0)
		await packets.inject(natReply(2, epoch: 1, lifetime: 0), source: gateway); try await remove.value
		try await dispatcher.shutdown()
	}
	@Test func retriesCancelAndSurfaceRouterErrors() async throws {
		let packets = try InjectedDatagrams(), clock = ManualTransportClock(), gateway = try NetworkEndpoint("192.168.1.1", port: 5351)
		let dispatcher = UDPDispatcher(transport: packets, clock: clock), client = try NATPMPClient(dispatcher: dispatcher, gateway: gateway, clock: clock)
		let address = Task { try await client.externalAddress() }
		defer { address.cancel() }
		let first = try await packets.nextSent()
		try await clock.waitForSleep(0.25); clock.advance(0.25)
		let repeated = try await packets.nextSent()
		#expect(first.0 == repeated.0)
		try await clock.waitForSleep(0.5); address.cancel()
		do { _ = try await address.value; Issue.record("Router cancellation ignored") } catch { #expect(error is CancellationError) }
		let failure = Task { try await client.externalAddress() }
		_ = try await packets.nextSent(); await packets.inject(natReply(0, epoch: 0, result: 2), source: gateway)
		do { _ = try await failure.value; Issue.record("Router error ignored") } catch { #expect(error as? NetworkFailure == .invalid("NAT-PMP result 2")) }
		try await dispatcher.shutdown()
	}
}
