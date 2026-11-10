import Foundation
import OSLog
import ButterTorrentNetworking

/// RouterMappingRoute describes a default gateway and the local address used to reach it.
public struct RouterMappingRoute: Hashable, Sendable {
	public let gateway: NetworkEndpoint
	public let source: IPAddress
	public let interfaceIndex: UInt32?
	public init(gateway: NetworkEndpoint, source: IPAddress, interfaceIndex: UInt32? = nil) {
		self.gateway = gateway; self.source = source; self.interfaceIndex = interfaceIndex
	}
	static func systemRoutes() async throws -> [Self] {
		let environment = try await NetworkEnvironment.snapshot(timeout: 3)
		return environment.gateways.compactMap { address in
			guard !address.isLoopback, !address.isMulticast, !address.isUnspecified else { return nil }
			let gateway = NetworkEndpoint(address: address, port: 5351)
			guard let source = try? NetworkEnvironment.sourceAddress(for: gateway), !source.isLoopback,
				let interface = environment.interfaces.first(where: { $0.address == source }) else { return nil }
			return Self(gateway: gateway, source: source, interfaceIndex: interface.index)
		}
	}
}

actor SessionRouterMapping {
	typealias Routes = @Sendable () async throws -> [RouterMappingRoute]
	private static let log = Logger(subsystem: "ButterTorrent", category: "RouterMapping")
	private let listener: ListeningPort
	private let kinds: [MappedTransport]
	private let clock: any TransportClock
	private let routes: Routes
	private let filter: PeerAddressFilter
	private var supervisor: Task<Void, Never>?
	private var workers: [RouterMappingRoute: Task<Void, Never>] = [:]
	private var statuses: [RouterMappingRoute: [String: Bool]] = [:]
	private var discoveryFailed = false
	init(listener: ListeningPort, tcp: Bool, clock: any TransportClock, routes: @escaping Routes, filter: PeerAddressFilter) {
		self.listener = listener; kinds = tcp ? [.tcp, .udp] : [.udp]; self.clock = clock; self.routes = routes; self.filter = filter
	}
	func start() {
		guard supervisor == nil else { return }
		supervisor = Task { await self.run() }
	}
	func shutdown() async {
		supervisor?.cancel(); await supervisor?.value; supervisor = nil
	}
	var error: String {
		let results = statuses.values.flatMap(\.values)
		guard discoveryFailed || !results.isEmpty && results.allSatisfy({ !$0 }) else { return "" }
		return "Automatic router mapping failed. Configure port forwarding on your router."
	}
	var mapped: Bool { statuses.values.contains { $0.values.contains(true) } }
	private func run() async {
		while !Task.isCancelled {
			do {
				let current = try await routes().filter { filter.allows($0.gateway.address) }
				try Task.checkCancellation()
				let available = Set(current.prefix(8)); discoveryFailed = available.isEmpty
				let retired = workers.keys.filter { !available.contains($0) }
				for route in retired { workers[route]?.cancel() }
				for route in retired { await workers.removeValue(forKey: route)?.value; statuses[route] = nil }
				for route in available where workers[route] == nil {
					workers[route] = Task { await self.mapRoute(route) }
				}
			} catch is CancellationError { break }
			catch { discoveryFailed = true; Self.log.error("Could not discover mapping gateways: \(error.localizedDescription)") }
			do { try await clock.sleep(for: 30) } catch { break }
		}
		for worker in workers.values { worker.cancel() }
		for worker in workers.values { await worker.value }
		workers.removeAll(); statuses.removeAll()
	}
	private func mapRoute(_ route: RouterMappingRoute) async {
		await withTaskGroup(of: Void.self) { group in
			group.addTask { await self.mapUDP(route) }
			if !route.source.isIPv6, let index = route.interfaceIndex { group.addTask { await self.mapUPnP(route, interfaceIndex: index) } }
			await group.waitForAll()
		}
	}
	private func record(_ route: RouterMappingRoute, protocol name: String, error: Error?) {
		if let error {
			guard !Task.isCancelled else { return }
			if statuses[route]?[name] != false { Self.log.error("\(name, privacy: .public) mapping failed: \(error.localizedDescription)") }
		}
		statuses[route, default: [:]][name] = error == nil
	}
	private func mapUDP(_ route: RouterMappingRoute) async {
		do {
			let socket = try DatagramSocket(bind: NetworkEndpoint(address: route.source, port: 0))
			defer { socket.close() }
			let dispatcher = UDPDispatcher(transport: socket, clock: clock)
			let client = try NATPMPClient(dispatcher: dispatcher, gateway: route.gateway, clock: clock, pcpSource: route.source)
			await maintain(route, protocol: "PCP/NAT-PMP", map: { kind, port in
				_ = try await client.map(kind, internalPort: port, externalPort: port)
			}, renew: { try await client.renewIfDue() }, remove: { try await client.remove($0) })
			try await dispatcher.shutdown()
		} catch { record(route, protocol: "PCP/NAT-PMP", error: error) }
	}
	private func mapUPnP(_ route: RouterMappingRoute, interfaceIndex: UInt32) async {
		let discovery: UPnPDiscovery
		do { discovery = try UPnPDiscovery.open(interfaceAddress: route.source, interfaceIndex: interfaceIndex, clock: clock) }
		catch { record(route, protocol: "UPnP", error: error); return }
		let searches = Task {
			while !Task.isCancelled {
				do { _ = try await discovery.searchIfDue(); try await clock.sleep(for: 30) }
				catch is CancellationError { return }
				catch {
					self.record(route, protocol: "UPnP", error: error)
					do { try await clock.sleep(for: 30) } catch { return }
				}
			}
		}
		var service: (URL, UPnPClient)?, upkeep: Task<Void, Never>?
		for await candidate in discovery.devices {
			guard !Task.isCancelled else { break }
			guard candidate.gateway == route.gateway.address, clock.now() < candidate.expires else { continue }
			if let service, service.0 == candidate.location {
				if let boot = candidate.bootID { await service.1.observeBootID(boot) }
				continue
			}
			do {
				let description = try await UPnPService.load(candidate)
				let client = try UPnPClient(service: description, internalClient: route.source, clock: clock)
				upkeep?.cancel(); await upkeep?.value
				try Task.checkCancellation(); service = (candidate.location, client)
				upkeep = Task {
					await self.maintain(route, protocol: "UPnP", map: { kind, port in
						_ = try await client.map(kind, internalPort: port, externalPort: port)
					}, renew: { try await client.renewIfDue() }, remove: { try await client.remove($0) })
				}
			} catch is CancellationError { break }
			catch { record(route, protocol: "UPnP", error: error) }
		}
		upkeep?.cancel(); searches.cancel(); try? await discovery.shutdown()
		await searches.value; await upkeep?.value
	}
	private func maintain(_ route: RouterMappingRoute, protocol name: String,
		map: @Sendable (MappedTransport, UInt16) async throws -> Void, renew: @Sendable () async throws -> Void,
		remove: @escaping @Sendable (MappedTransport) async throws -> Void) async {
		var mapped: Set<MappedTransport> = []
		while !Task.isCancelled {
			var failure: Error?
			do { try await renew() } catch { failure = error }
			for kind in kinds where !Task.isCancelled && !mapped.contains(kind) {
				do { try await map(kind, listener.port); mapped.insert(kind) }
				catch { failure = failure ?? error }
			}
			record(route, protocol: name, error: failure)
			do { try await clock.sleep(for: failure == nil ? 1 : 10) } catch { break }
		}
		// The listener remains open until the bounded delete exchange has drained.
		let kinds = kinds, clock = clock
		let cleanup = Task {
			await withTaskGroup(of: Void.self) { group in
				group.addTask {
					for kind in kinds where !Task.isCancelled {
						do { try await remove(kind) }
						catch { if !Task.isCancelled { Self.log.error("\(name, privacy: .public) mapping removal failed: \(error.localizedDescription)") } }
					}
				}
				group.addTask { try? await clock.sleep(for: 3) }
				_ = await group.next(); group.cancelAll()
			}
		}
		await cleanup.value
	}
}
