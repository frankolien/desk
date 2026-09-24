import Foundation
import Testing
@testable import DeskAuth

@Suite("Personal messages")
struct PersonalMessageTests {
    @Test("the digest is EIP-191's, checked against the reference vector for “hello”")
    func vector() {
        let digest = PersonalMessage.digest("hello").map { String(format: "%02x", $0) }.joined()
        #expect(digest == "50b2c43fd39106bafbba0da34fc430e1f91e3c96ea2acee2bc34119f92b37750")
    }

    @Test("the length in the prefix counts bytes, not characters")
    func bytes() {
        // Two characters, four bytes: a prefix that counted characters would hash a different string.
        let byCharacters = Keccak.hash(Data("\u{19}Ethereum Signed Message:\n2éé".utf8))
        let byBytes = Keccak.hash(Data("\u{19}Ethereum Signed Message:\n4éé".utf8))
        #expect(PersonalMessage.digest("éé") == byBytes)
        #expect(PersonalMessage.digest("éé") != byCharacters)
    }
}
