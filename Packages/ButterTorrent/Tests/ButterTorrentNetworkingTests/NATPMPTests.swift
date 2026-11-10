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
	@Test(arguments: [false, true]) func pcpUsesNonceForRenewalAndDeletion(_ ipv6: Bool) async throws {
		let source = try IPAddress(ipv6 ? "2001:db8::7" : "192.168.1.7"), gateway = try NetworkEndpoint(ipv6 ? "fe80::1%1" : "192.168.1.1", port: 5351)
		let clock = ManualTransportClock(), packets = try InjectedDatagrams(endpoint: NetworkEndpoint(address: source, port: 6881))
		let dispatcher = UDPDispatcher(transport: packets, clock: clock), client = try NATPMPClient(dispatcher: dispatcher, gateway: gateway, clock: clock, pcpSource: source)
		let create = Task { try await client.map(.tcp, internalPort: 6881, externalPort: 6881, lifetime: 60) }
		defer { create.cancel() }
		let request = try await packets.nextSent().0
		#expect(request.count == 60 && request.prefix(4) == Data([2, 1, 0, 0]) && request[36] == 6)
		#expect(try IPAddress(bytes: request.subdata(in: 8..<24)) == source)
		let publicAddress = try IPAddress("2001:db8::42")
		var response = pcpReply(to: request, address: publicAddress, lifetime: 60)
		var wrongNonce = response; wrongNonce[24] ^= 1
		await packets.inject(wrongNonce, source: gateway)
		await packets.inject(response, source: gateway)
		#expect(try await create.value.externalPort == 6882)
		#expect(try await client.externalAddress() == publicAddress)
		clock.advance(30)
		let renew = Task { try await client.renewIfDue() }; defer { renew.cancel() }
		let renewed = try await packets.nextSent().0
		#expect(renewed[24..<36] == request[24..<36])
		#expect(try PacketBytes.uint16(renewed, at: 42) == 6882)
		#expect(renewed.subdata(in: 44..<60) == publicAddress.bytes)
		await packets.inject(response, source: gateway); try await renew.value
		let remove = Task { try await client.remove(.tcp) }; defer { remove.cancel() }
		let deleted = try await packets.nextSent().0
		#expect(deleted[24..<36] == request[24..<36])
		#expect(try PacketBytes.uint32(deleted, at: 4) == 0)
		response.replaceSubrange(4..<8, with: Data(repeating: 0, count: 4))
		await packets.inject(response, source: gateway); try await remove.value
		#expect(await dispatcher.pendingCount == 0)
		try await dispatcher.shutdown()
	}

	@Test func ipv4UnsupportedVersionFallsBackToNATPMP() async throws {
		let packets = try InjectedDatagrams(), clock = ManualTransportClock(), gateway = try NetworkEndpoint("192.168.1.1", port: 5351)
		let dispatcher = UDPDispatcher(transport: packets, clock: clock)
		let client = try NATPMPClient(dispatcher: dispatcher, gateway: gateway, clock: clock, pcpSource: dispatcher.localEndpoint.address)
		let mapping = Task { try await client.map(.udp, internalPort: 6881, externalPort: 6881) }; defer { mapping.cancel() }
		let pcp = try await packets.nextSent().0
		#expect(pcp.prefix(2) == Data([2, 1]) && pcp[36] == 17)
		await packets.inject(Data([0, 129, 0, 1, 0, 0, 0, 0]), source: gateway)
		#expect(try await packets.nextSent().0.prefix(2) == Data([0, 1]))
		await packets.inject(natReply(1, epoch: 100, lifetime: 60), source: gateway)
		#expect(try await mapping.value.lifetime == 60)
		let removal = Task { try await client.remove(.udp) }; defer { removal.cancel() }
		#expect(try await packets.nextSent().0.prefix(2) == Data([0, 1]))
		await packets.inject(natReply(1, epoch: 100, lifetime: 0), source: gateway); try await removal.value
		try await dispatcher.shutdown()
	}

	private func pcpReply(to request: Data, address: IPAddress, lifetime: UInt32) -> Data {
		var bytes = Data([2, 129, 0, 0]); PacketBytes.append(lifetime, to: &bytes); PacketBytes.append(UInt32(100), to: &bytes)
		bytes.append(Data(repeating: 0, count: 12)); bytes.append(request[24..<42])
		PacketBytes.append(UInt16(6882), to: &bytes); bytes.append(address.bytes)
		return bytes
	}
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
