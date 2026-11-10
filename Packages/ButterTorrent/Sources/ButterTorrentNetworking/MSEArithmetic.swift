import Foundation
import Security

// Fixed to the MSE protocol's 768-bit prime; this is not a general-purpose integer API.
struct MSEInteger: Equatable, Sendable {
	var words: [UInt32]
	static let primeBytes: Data = {
		let hex = "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A63A36210000000000090563"
		return Data(stride(from: 0, to: hex.count, by: 2).map { offset in let start = hex.index(hex.startIndex, offsetBy: offset); return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)! })
	}()
	static let prime = MSEInteger(primeBytes)
	static let inverse: UInt32 = {
		var x: UInt32 = 1
		for _ in 0..<5 { x = x &* (2 &- prime.words[0] &* x) }; return 0 &- x
	}()
	static let r2: MSEInteger = { var value = MSEInteger(1); for _ in 0..<1536 { value = value.doubled() }; return value }()
	init(_ value: UInt32) { words = [value] + Array(repeating: 0, count: 23) }
	init(_ bytes: Data) {
		precondition(bytes.count == 96)
		let bytes = Array(bytes)
		words = (0..<24).map { index in let end = 96 - index * 4; return (end - 4..<end).reduce(UInt32(0)) { $0 << 8 | UInt32(bytes[$1]) } }
	}
	var bytes: Data { var data = Data(); for word in words.reversed() { PacketBytes.append(word, to: &data) }; return data }
	func less(_ other: Self) -> Bool {
		for index in (0..<24).reversed() where words[index] != other.words[index] { return words[index] < other.words[index] }; return false
	}
	func subtract(_ other: Self) -> Self {
		var result = self, borrow: UInt64 = 0
		for index in 0..<24 {
			let a = UInt64(words[index]), b = UInt64(other.words[index]) + borrow
			result.words[index] = UInt32(truncatingIfNeeded: a &- b); borrow = a < b ? 1 : 0
		}; return result
	}
	func doubled() -> Self {
		var result = self, carry: UInt32 = 0
		for index in 0..<24 { let next = words[index] >> 31; result.words[index] = words[index] << 1 | carry; carry = next }
		if carry != 0 || !result.less(Self.prime) { result = result.subtract(Self.prime) }; return result
	}
	func multiplied(_ other: Self) -> Self {
		var t = [UInt32](repeating: 0, count: 50)
		func addCarry(_ carry: UInt64, at start: Int) {
			var carry = carry, index = start
			while carry != 0 { let sum = UInt64(t[index]) + carry; t[index] = UInt32(truncatingIfNeeded: sum); carry = sum >> 32; index += 1 }
		}
		for i in 0..<24 {
			var carry: UInt64 = 0
			for j in 0..<24 { let sum = UInt64(words[i]) * UInt64(other.words[j]) + UInt64(t[i + j]) + carry; t[i + j] = UInt32(truncatingIfNeeded: sum); carry = sum >> 32 }
			addCarry(carry, at: i + 24)
		}
		for i in 0..<24 {
			let factor = t[i] &* Self.inverse; var carry: UInt64 = 0
			for j in 0..<24 { let sum = UInt64(factor) * UInt64(Self.prime.words[j]) + UInt64(t[i + j]) + carry; t[i + j] = UInt32(truncatingIfNeeded: sum); carry = sum >> 32 }
			addCarry(carry, at: i + 24)
		}
		var result = Self(0); result.words = Array(t[24..<48])
		if t[48] != 0 || !result.less(Self.prime) { result = result.subtract(Self.prime) }; return result
	}
	func power(_ exponent: Data) throws -> Self {
		var result = Self(1).multiplied(Self.r2)
		let base = multiplied(Self.r2)
		for byte in exponent {
			try Task.checkCancellation()
			for bit in (0..<8).reversed() {
				let square = result.multiplied(result), product = square.multiplied(base)
				let mask = UInt32(0) &- UInt32((byte >> bit) & 1)
				for index in 0..<24 { result.words[index] = (square.words[index] & ~mask) | (product.words[index] & mask) }
			}
		}; return result.multiplied(Self(1))
	}
}

func mseRandom(_ count: Int) throws -> Data {
	var bytes = [UInt8](repeating: 0, count: count)
	guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw NetworkFailure.invalid("secure random generation") }; return Data(bytes)
}

struct MSEKeyPair: Sendable {
	let secret: Data
	let publicKey: Data
	init(secret: Data) throws {
		guard secret.count == 20, secret.contains(where: { $0 != 0 }) else { throw NetworkFailure.invalid("MSE private key") }
		self.secret = Data(secret); publicKey = try MSEInteger(2).power(secret).bytes
	}
	func shared(_ remote: Data) throws -> Data {
		guard remote.count == 96 else { throw NetworkFailure.invalid("MSE public key length") }
		let value = MSEInteger(remote)
		guard !value.less(MSEInteger(2)), value.less(MSEInteger.prime.subtract(MSEInteger(1))) else { throw NetworkFailure.invalid("MSE public key range") }
		return try value.power(secret).bytes
	}
}

actor MSEWorkers {
	static let shared = MSEWorkers()
	private var active = 0
	private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []
	var waitingCount: Int { waiters.count }
	func acquire() async throws {
		try Task.checkCancellation()
		if active < 4 { active += 1; return }
		guard waiters.count < 64 else { throw NetworkFailure.limit("MSE arithmetic workers") }
		let id = UUID()
		try await withTaskCancellationHandler {
			try Task.checkCancellation()
			try await withCheckedThrowingContinuation { waiters.append((id, $0)) }
		} onCancel: { Task { await self.cancel(id) } }
	}
	private func cancel(_ id: UUID) { if let index = waiters.firstIndex(where: { $0.0 == id }) { waiters.remove(at: index).1.resume(throwing: CancellationError()) } }
	func release() { if waiters.isEmpty { active -= 1 } else { waiters.removeFirst().1.resume() } }
	func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
		try await acquire(); defer { release() }
		let work = Task.detached(priority: .utility) { try Task.checkCancellation(); return try body() }
		return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
	}
}
