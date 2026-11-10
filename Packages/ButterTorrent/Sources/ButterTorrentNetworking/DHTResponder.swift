import Foundation
import ButterTorrentMetadata

extension DHTNode {
	func receiveQuery(_ packet: NetworkDatagram) async {
		guard !closed, !updating, !permitted.isEmpty, !Task.isCancelled, packet.payload.count <= 4096,
			addressFilter.allows(packet.source.address),
			let root = try? DHTWire.decode(packet.payload), root["y"]?.text == "q", let transaction = root["t"]?.bytes,
			!transaction.isEmpty, transaction.count <= 8, let method = root["q"]?.text,
			let args = root["a"], args.dictionary != nil, let id = args["id"]?.bytes,
			id.count == 20, packet.source.port > 0,
			!packet.source.address.isUnspecified, !packet.source.address.isMulticast else { return }
		let epoch = Int64(clock.now())
		if epoch != rateEpoch { rates.removeAll(keepingCapacity: true); rateCount = 0; rateEpoch = epoch }
		guard rateCount < 200, rates[packet.source.address, default: 0] < 30 else { return }
		rateCount += 1; rates[packet.source.address, default: 0] += 1
		var fields: [String: BencodeValue] = ["t": .bytes(transaction), "ip": .bytes(DHTWire.compact(packet.source))]
		do {
			var response: [String: BencodeValue] = ["id": .bytes(table.id)]
			switch method {
			case "ping": break
			case "find_node", "get_peers":
				guard let target = args[method == "find_node" ? "target" : "info_hash"]?.bytes, target.count == 20 else { throw NetworkFailure.invalid("DHT target") }
				guard !forbidden.contains(target) else { throw NetworkFailure.invalid("private DHT swarm") }
				let wanted = args["want"]?.list?.compactMap(\.text) ?? [packet.source.address.isIPv6 ? "n6" : "n4"]
				let contacts = table.closest(target, now: clock.now())
				for (flag, key, family) in [("n4", "nodes", false), ("n6", "nodes6", true)] where wanted.contains(flag) {
					var bytes = Data(); for node in contacts where node.endpoint.address.isIPv6 == family && addressFilter.allows(node.endpoint.address) { bytes.append(node.id); bytes.append(DHTWire.compact(node.endpoint)) }; response[key] = .bytes(bytes)
				}
				if method == "get_peers" {
					if DHTIdentity.valid(id, address: packet.source.address) { response["token"] = .bytes(tokens.token(address: packet.source.address, bucket: Int64(clock.now() / 300))) }
					let peers = peerCache[target, default: [:]].filter { clock.now() - $0.value < 1800 && addressFilter.allows($0.key.address) }
					if !peers.isEmpty { response["values"] = .list(peers.keys.filter { $0.address.isIPv6 == packet.source.address.isIPv6 }.prefix(packet.source.address.isIPv6 ? 16 : 32).map { .bytes(DHTWire.compact($0)) }) }
				}
			case "announce_peer":
				guard DHTIdentity.valid(id, address: packet.source.address), let hash = args["info_hash"]?.bytes, hash.count == 20, !forbidden.contains(hash),
					let token = args["token"]?.bytes, tokens.valid(token, address: packet.source.address, now: clock.now()) else { throw NetworkFailure.invalid("DHT announce token or identity") }
				let implied = args["implied_port"]?.integer != nil && args["implied_port"]?.integer != 0
				let number = implied ? Int64(packet.source.port) : args["port"]?.integer ?? 0
				guard (1...65535).contains(number) else { throw NetworkFailure.invalid("DHT announce port") }
				peerCache = peerCache.mapValues { $0.filter { clock.now() - $0.value < 1800 } }.filter { !$0.value.isEmpty }
				guard peerCache[hash] != nil || peerCache.count < 1024 else { throw NetworkFailure.limit("DHT stored swarms") }
				let peer = NetworkEndpoint(address: packet.source.address, port: UInt16(number))
				if peerCache[hash]?[peer] != nil || peerCache[hash, default: [:]].count < 64 { peerCache[hash, default: [:]][peer] = clock.now() }
				table.insert(DHTContact(id: id, endpoint: packet.source), now: clock.now())
			default:
				fields["y"] = .bytes(Data("e".utf8)); fields["e"] = .list([.integer(204), .bytes(Data("Unknown method".utf8))])
			}
			if fields["e"] == nil { fields["y"] = .bytes(Data("r".utf8)); fields["r"] = DHTWire.dictionary(response) }
		} catch {
			fields["y"] = .bytes(Data("e".utf8)); fields["e"] = .list([.integer(203), .bytes(Data("Invalid query".utf8))])
		}
		do { try Task.checkCancellation(); guard !closed, !permitted.isEmpty, addressFilter.allows(packet.source.address) else { return }; try await dispatcher.send(DHTWire.encode(fields), to: packet.source) }
		catch is CancellationError {} catch { lastFailure = String(describing: error) }
	}
}
