import Foundation

public struct EthereumAddress: Hashable, Sendable, CustomStringConvertible {
    public let bytes: Data

    public init?(bytes: Data) {
        guard bytes.count == 20 else { return nil }
        self.bytes = bytes
    }

    /// EIP-55: a hex digit is uppercased when the matching nibble of the keccak of the
    /// lowercase hex is 8 or more.
    public var checksummed: String {
        let lowercase = bytes.map { String(format: "%02x", $0) }.joined()
        let hash = Hashing.keccak256(Data(lowercase.utf8))
        var result = "0x"
        for (index, character) in lowercase.enumerated() {
            let nibble = index % 2 == 0 ? hash[index / 2] >> 4 : hash[index / 2] & 0x0f
            result.append(nibble >= 8 ? Character(character.uppercased()) : character)
        }
        return result
    }

    public var description: String { checksummed }

    /// An address someone typed or pasted. All-lowercase and all-uppercase are accepted as
    /// unchecksummed; mixed case must be a correct EIP-55 checksum, because a mixed-case
    /// address with one wrong letter is a typo that would otherwise send funds nowhere.
    public init?(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 42, trimmed.hasPrefix("0x") else { return nil }
        let hex = trimmed.dropFirst(2)
        var bytes = Data(capacity: 20)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        guard let address = EthereumAddress(bytes: bytes) else { return nil }
        let letters = hex.filter(\.isLetter)
        let isSingleCase = letters == letters.lowercased() || letters == letters.uppercased()
        guard isSingleCase || address.checksummed == trimmed else { return nil }
        self = address
    }

    public var isZero: Bool { bytes.allSatisfy { $0 == 0 } }
}
