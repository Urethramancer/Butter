import Foundation

struct PortChecker {
	// Only called by the explicit Check Port action; no background reachability requests.
	var fetch: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }
	func check(_ port: Int) async -> String {
		guard (1...65535).contains(port) else { return "Unknown — no confirmed listening port" }
		var request = URLRequest(url: URL(string: "https://portcheck.transmissionbt.com/\(port)")!); request.timeoutInterval = 20
		do {
			let (data, response) = try await fetch(request)
			guard let response = response as? HTTPURLResponse, response.statusCode == 200, let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), body == "0" || body == "1" else { return "Unknown — port-check service returned an unexpected response" }
			return body == "1" ? "External TCP reachable" : "External TCP not reachable"
		} catch { return "Unknown — port-check service unavailable" }
	}
}
