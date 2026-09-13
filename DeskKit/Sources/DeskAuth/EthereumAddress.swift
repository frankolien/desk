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
}
