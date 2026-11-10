import Foundation

// XML is bounded and entities/DTDs are refused before any router-controlled URL is used.
final class UPnPXML: NSObject, XMLParserDelegate {
	struct Service { let type: String; let control: String }
	private var stack: [(String, String)] = []
	private var service: [String: String]?
	private var serviceDepth = 0
	private var elements = 0
	private var textBytes = 0
	private var failure: Error?
	private(set) var services: [Service] = []
	private(set) var base: String?
	private(set) var fields: [String: String] = [:]
	private(set) var responses: [String: String] = [:]
	static func parse(_ data: Data) throws -> UPnPXML {
		guard data.count <= 1_048_576 else { throw NetworkFailure.limit("UPnP XML bytes") }
		let inspection = String(decoding: data.filter { $0 != 0 }, as: UTF8.self)
		guard inspection.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
			inspection.range(of: "<!ENTITY", options: .caseInsensitive) == nil else { throw NetworkFailure.invalid("UPnP XML DTD or entity") }
		let result = UPnPXML(), parser = XMLParser(data: data)
		parser.delegate = result; parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.externalEntityResolvingPolicy = .never
		guard parser.parse(), result.failure == nil else { throw result.failure ?? NetworkFailure.invalid("UPnP XML") }
		return result
	}
	private func fail(_ parser: XMLParser, _ reason: String) { failure = NetworkFailure.invalid(reason); parser.abortParsing() }
	func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
		let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
		elements += 1
		guard stack.count < 32, elements <= 10_000 else { fail(parser, "UPnP XML structure limit"); return }
		stack.append((name, ""))
		if name == "service" { guard service == nil else { fail(parser, "nested UPnP service"); return }; service = [:]; serviceDepth = stack.count }
		if name.hasSuffix("Response"), stack.count == 3, stack[0].0 == "Envelope", stack[1].0 == "Body" {
			guard responses[name] == nil else { fail(parser, "duplicate UPnP action response"); return }
			responses[name] = namespaceURI ?? ""
		}
	}
	func parser(_ parser: XMLParser, foundCharacters string: String) {
		textBytes += string.utf8.count
		guard textBytes <= 1_048_576 else { fail(parser, "UPnP XML text limit"); return }
		if stack.isEmpty { if !string.allSatisfy(\.isWhitespace) { fail(parser, "text outside UPnP XML root") }; return }
		stack[stack.count - 1].1 += string
	}
	func parser(_ parser: XMLParser, foundCDATA data: Data) {
		guard let text = String(data: data, encoding: .utf8) else { fail(parser, "UPnP XML CDATA"); return }
		self.parser(parser, foundCharacters: text)
	}
	func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
		guard let (name, raw) = stack.last else { fail(parser, "UPnP XML nesting"); return }
		let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		if let current = service, stack.count == serviceDepth + 1, ["serviceType", "controlURL"].contains(name) {
			guard current[name] == nil else { fail(parser, "duplicate UPnP service field"); return }
			service?[name] = text
		}
		if name == "service", stack.count == serviceDepth {
			if let type = service?["serviceType"], let control = service?["controlURL"] {
				guard services.count < 32 else { fail(parser, "UPnP service count"); return }
				services.append(Service(type: type, control: control))
			}
			service = nil
		}
		if name == "URLBase", stack.count == 2 { guard base == nil else { fail(parser, "duplicate UPnP URLBase"); return }; base = text }
		if name == "errorCode" || name.hasPrefix("New") {
			guard fields[name] == nil else { fail(parser, "duplicate UPnP response field"); return }
			fields[name] = text
		}
		stack.removeLast()
	}
	func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { fail(parser, "UPnP XML entity declaration") }
	func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { fail(parser, "UPnP XML external entity") }
	func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { fail(parser, "UPnP XML external entity"); return nil }
	static func escape(_ value: String) -> String {
		value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
	}
}
