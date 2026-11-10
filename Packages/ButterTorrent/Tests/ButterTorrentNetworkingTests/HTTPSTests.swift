#if os(macOS)
import Foundation
import Network
import Security
import Testing
@testable import ButterTorrentNetworking

@Suite struct HTTPSTests {
	@Test func rejectsUntrustedLocalCertificate() async throws {
		guard #available(macOS 15, *) else { return } // Keep imported test keys entirely in memory.
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ButterTLS-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		func openssl(_ arguments: [String]) throws {
			let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
			process.arguments = arguments; process.currentDirectoryURL = directory
			process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
			let exited = DispatchSemaphore(value: 0)
			process.terminationHandler = { _ in exited.signal() }
			try process.run()
			guard exited.wait(timeout: .now() + 5) == .success else {
				process.terminate()
				if exited.wait(timeout: .now() + 1) != .success { kill(process.processIdentifier, SIGKILL) }
				throw HTTPServiceError.invalid("TLS fixture generation deadline")
			}
			guard process.terminationStatus == 0 else { throw HTTPServiceError.invalid("TLS fixture generation") }
		}
		try openssl(["req", "-new", "-x509", "-nodes", "-newkey", "rsa:2048", "-subj", "/CN=localhost", "-days", "1", "-keyout", "key.pem", "-out", "cert.pem"])
		try openssl(["pkcs12", "-export", "-inkey", "key.pem", "-in", "cert.pem", "-out", "identity.p12", "-passout", "pass:fixture"])
		let p12 = try Data(contentsOf: directory.appendingPathComponent("identity.p12"))
		var items: CFArray?
		let status = SecPKCS12Import(p12 as CFData, [kSecImportExportPassphrase: "fixture", kSecImportToMemoryOnly: true] as CFDictionary, &items)
		guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first, let value = first[kSecImportItemIdentity as String] else { throw HTTPServiceError.invalid("TLS fixture import") }
		let identity = value as! SecIdentity
		let tls = NWProtocolTLS.Options()
		sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(identity)!)
		let server = try await HTTPFixture.start(tls: tls) { _ in .init(body: Data("unexpected".utf8)) }
		let url = URL(string: server.url.absoluteString.replacingOccurrences(of: "http:", with: "https:"))!
		do {
			_ = try await FoundationHTTPTransport().get(HTTPRequest(url: url, timeout: 3))
			Issue.record("Untrusted HTTPS certificate was accepted")
		} catch {
			#expect([.serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid].contains((error as? URLError)?.code))
		}
		await server.stop()
	}
}
#endif
