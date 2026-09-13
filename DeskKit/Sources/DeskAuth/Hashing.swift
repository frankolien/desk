import CryptoKit
import CryptoSwift
import Foundation

enum Hashing {
    static func sha256(_ data: Data) -> Data {
        Data(CryptoKit.SHA256.hash(data: data))
    }

    /// Ethereum's keccak256, which is not NIST SHA3-256 — the padding differs.
    static func keccak256(_ data: Data) -> Data {
        Data(SHA3(variant: .keccak256).calculate(for: [UInt8](data)))
    }

    static func hmacSHA512(key: Data, message: Data) -> Data {
        var mac = CryptoKit.HMAC<CryptoKit.SHA512>(key: SymmetricKey(data: key))
        mac.update(data: message)
        return Data(mac.finalize())
    }

    static func pbkdf2SHA512(password: Data, salt: Data, iterations: Int, length: Int) -> Data {
        guard iterations >= 1, length > 0 else { return Data() }
        var output = Data()
        var block: UInt32 = 1
        while output.count < length {
            var counter = Data(count: 4)
            counter[0] = UInt8(truncatingIfNeeded: block >> 24)
            counter[1] = UInt8(truncatingIfNeeded: block >> 16)
            counter[2] = UInt8(truncatingIfNeeded: block >> 8)
            counter[3] = UInt8(truncatingIfNeeded: block)

            var chunk = hmacSHA512(key: password, message: salt + counter)
            var accumulated = chunk
            for _ in 1..<iterations {
                chunk = hmacSHA512(key: password, message: chunk)
                for index in 0..<accumulated.count { accumulated[index] ^= chunk[index] }
            }
            output += accumulated
            block += 1
        }
        return output.prefix(length)
    }
}
