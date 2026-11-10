import Foundation
import Testing
import ButterTorrentMetadata
@testable import ButterTorrentNetworking

private func discoveryMetadata(isPrivate: Bool) throws -> TorrentMetadata {
	let fields: [Data: BencodeValue] = [Data("name".utf8): .bytes(Data("a".utf8)), Data("length".utf8): .integer(1),
		Data("pieces".utf8): .bytes(Data(repeating: 42, count: 20)), Data("piece length".utf8): .integer(16384), Data("private".utf8): .integer(isPrivate ? 1 : 0)]
	return try TorrentMetadata(BencodeValue.dictionary([Data("info".utf8): .dictionary(fields)]).encoded())
}

@Suite struct DiscoveryTests {
	@Test func privateTorrentsNeverAdvertiseOrProduceDiscoveredPeers() async throws {
		let packets = try InjectedDatagrams(), dispatcher = UDPDispatcher(transport: packets), clock = TestClock()
		let discovery = try LocalDiscovery(dispatcher: dispatcher, peerPort: 6881, cookie: "own", clock: clock)
		let privateTorrent = try discoveryMetadata(isPrivate: true), publicTorrent = try discoveryMetadata(isPrivate: false)
		try await discovery.setTorrents([privateTorrent])
		#expect(try await discovery.announceIfDue() == false)
		#expect(await packets.sentCount == 0)
		try await discovery.setTorrents([privateTorrent, publicTorrent])
		#expect(try await discovery.announceIfDue())
		let announce = try await packets.nextSent()
		let text = String(decoding: announce.0, as: UTF8.self)
		#expect(announce.0.count <= 1400 && announce.1.description == "239.192.152.143:6771")
		#expect(text.contains(publicTorrent.hashes.hex[0]) && !text.contains(privateTorrent.hashes.hex[0]))
		#expect(try await discovery.announceIfDue() == false)
		let source = try NetworkEndpoint("192.168.1.2", port: 6771)
		let incoming = "BT-SEARCH * HTTP/1.1\r\nHost: 239.192.152.143:6771\r\nPort: 7000\r\nInfohash: \(privateTorrent.hashes.hex[0])\r\nInfohash: \(publicTorrent.hashes.hex[0])\r\ncookie: other\r\n\r\n\r\n"
		await packets.inject(Data(incoming.utf8), source: source)
		let peer = try await deadline { for await peer in discovery.peers { return peer }; throw NetworkFailure.closed }
		#expect(peer.infoHash == publicTorrent.hashes.v1 && peer.endpoint == NetworkEndpoint(address: source.address, port: 7000))
		clock.advance(300)
		#expect(try await discovery.announceIfDue())
		try await discovery.shutdown(); try await dispatcher.shutdown()
	}
	@Test func ssdpPinsLocationAndNoticesRouterReboots() async throws {
		let packets = try InjectedDatagrams(), dispatcher = UDPDispatcher(transport: packets)
		let discovery = UPnPDiscovery(dispatcher: dispatcher)
		#expect(try await discovery.searchIfDue())
		let search = try await packets.nextSent()
		#expect(search.1.description == "239.255.255.250:1900" && String(decoding: search.0, as: UTF8.self).contains("M-SEARCH"))
		let gateway = try NetworkEndpoint("192.168.1.1", port: 1900)
		func reply(_ location: String, boot: Int) -> Data {
			Data("HTTP/1.1 200 OK\r\nST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\nLOCATION: \(location)\r\nCACHE-CONTROL: max-age=300\r\nBOOTID.UPNP.ORG: \(boot)\r\n\r\n".utf8)
		}
		await packets.inject(reply("http://169.254.169.254/metadata", boot: 1), source: gateway)
		await packets.inject(reply("http://192.168.1.1/root.xml", boot: 1), source: gateway)
		let first = try await deadline { for await device in discovery.devices { return device }; throw NetworkFailure.closed }
		#expect(first.gateway == gateway.address && first.location.host == "192.168.1.1")
		await packets.inject(reply("http://192.168.1.1/root.xml", boot: 2), source: gateway)
		let second = try await deadline { for await device in discovery.devices { return device }; throw NetworkFailure.closed }
		#expect(second.bootID == 2)
		try await discovery.shutdown(); try await dispatcher.shutdown()
	}
}
