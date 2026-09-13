import Foundation

enum BIP39 {
    enum Failure: Error, Equatable, Sendable {
        case entropyLengthUnsupported(Int)
    }

    /// Entropy to a mnemonic. Mera feeds 32 bytes of PRF output straight in, giving 24
    /// words; changing this mapping changes every derived address.
    /// Internal, not public: anything that can regenerate the 24 words undoes the
    /// promise that there is no phrase for a screen to show.
    static func mnemonic(entropy: Data) throws -> [String] {
        guard entropy.count % 4 == 0, (16...32).contains(entropy.count) else {
            throw Failure.entropyLengthUnsupported(entropy.count)
        }
        let checksumBits = entropy.count * 8 / 32
        let checksum = Hashing.sha256(entropy)

        var bits: [Bool] = []
        bits.reserveCapacity(entropy.count * 8 + checksumBits)
        for byte in entropy {
            for shift in (0..<8).reversed() { bits.append((byte >> UInt8(shift)) & 1 == 1) }
        }
        for index in 0..<checksumBits {
            let byte = checksum[index / 8]
            bits.append((byte >> UInt8(7 - index % 8)) & 1 == 1)
        }

        return stride(from: 0, to: bits.count, by: 11).map { start in
            var index = 0
            for bit in bits[start..<(start + 11)] { index = index << 1 | (bit ? 1 : 0) }
            return BIP39Wordlist.words[index]
        }
    }

    /// Mera derives with an empty passphrase.
    static func seed(mnemonic words: [String], passphrase: String = "") -> Data {
        let sentence = Data(words.joined(separator: " ").decomposedStringWithCompatibilityMapping.utf8)
        let salt = Data(("mnemonic" + passphrase).decomposedStringWithCompatibilityMapping.utf8)
        return Hashing.pbkdf2SHA512(password: sentence, salt: salt, iterations: 2048, length: 64)
    }
}
