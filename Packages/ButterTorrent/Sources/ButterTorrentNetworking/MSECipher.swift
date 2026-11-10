import Foundation
import CommonCrypto
import CryptoKit

// RC4 is used only for legacy MSE interoperability through Apple's public CommonCrypto API.
final class MSECipher: @unchecked Sendable {
	private let lock = NSLock()
	private let context: CCCryptorRef
	init(key: Data) throws {
		var context: CCCryptorRef?
		let status = key.withUnsafeBytes { CCCryptorCreate(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmRC4), 0, $0.baseAddress, key.count, nil, &context) }
		guard status == kCCSuccess, let context else { throw NetworkFailure.invalid("MSE cipher initialisation") }
		self.context = context
		_ = try apply(Data(repeating: 0, count: 1024))
	}
	func apply(_ data: Data) throws -> Data {
		try lock.withLock {
			if data.isEmpty { return Data() }
			var output = Data(count: data.count), written = 0
			let status = output.withUnsafeMutableBytes { destination in data.withUnsafeBytes { source in CCCryptorUpdate(context, source.baseAddress, source.count, destination.baseAddress, destination.count, &written) } }
			guard status == kCCSuccess, written == data.count else { throw NetworkFailure.invalid("MSE cipher update") }; return output
		}
	}
	deinit { CCCryptorRelease(context) }
}

func mseHash(_ label: String, _ data: Data, _ suffix: Data = Data()) -> Data {
	var hash = Insecure.SHA1(); hash.update(data: Data(label.utf8)); hash.update(data: data); hash.update(data: suffix); return Data(hash.finalize())
}
