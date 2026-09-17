import Foundation
import Testing
@testable import DeskAuth

@Suite("Typed addresses")
struct AddressTextTests {
    // EIP-55's own test vector.
    let checksummed = "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"

    @Test("a correct checksum and single-case forms are accepted")
    func accepts() throws {
        let address = try #require(EthereumAddress(text: checksummed))
        #expect(address.checksummed == checksummed)
        #expect(EthereumAddress(text: checksummed.lowercased()) == address)
        #expect(EthereumAddress(text: "0x" + checksummed.dropFirst(2).uppercased()) == address)
        #expect(EthereumAddress(text: "  \(checksummed)\n") == address)
    }

    @Test("a mixed-case typo is refused", arguments: [
        "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAeD",
        "0x5AAeb6053F3E94C9b9A09f33669435E7Ef1BeAed",
    ])
    func typo(text: String) {
        #expect(EthereumAddress(text: text) == nil)
    }

    @Test("anything that is not an address is refused", arguments: [
        "", "0x", "5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed", "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAe",
        "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAedd", "0xzaAeb6053F3E94C9b9A09f33669435E7Ef1BeAed", "vitalik.eth",
    ])
    func refuses(text: String) {
        #expect(EthereumAddress(text: text) == nil)
    }

    @Test("the zero address parses but says so")
    func zero() throws {
        #expect(try #require(EthereumAddress(text: "0x" + String(repeating: "0", count: 40))).isZero)
        #expect(EthereumAddress(text: checksummed)?.isZero == false)
    }
}
