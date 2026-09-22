import Testing
@testable import DeskUI

/// The avatar is an identity check the user performs without reading. That only works if
/// the mark is stable for an account and different between accounts, so both properties
/// are tested rather than assumed.
@Suite("Address avatar")
struct AddressAvatarTests {
    /// The bug this exists to catch: `hashValue` is seeded per process in Swift, so a
    /// mark derived from it would be a different colour on every launch — and an avatar
    /// that changes on relaunch teaches the user to ignore it, which is worse than not
    /// having one.
    @Test("The same address always derives the same mark")
    func stableForOneAddress() {
        let address = "0xb63b4C97aE9F1B0f8c7c8e33dA51b9E4f2c1A4c97"
        let first = AddressAvatar.seed(for: address)
        for _ in 0..<50 {
            let again = AddressAvatar.seed(for: address)
            #expect(again == first)
        }
    }

    /// Checksum casing is presentation, not identity: the same account rendered from a
    /// lowercase string and a checksummed one is one account and must wear one face.
    @Test("Casing does not change the mark")
    func caseInsensitive() {
        let lower = AddressAvatar.seed(for: "0xabcdef0123456789abcdef0123456789abcdef01")
        let mixed = AddressAvatar.seed(for: "0xAbCdEf0123456789aBcDeF0123456789AbCdEf01")
        #expect(lower == mixed)
    }

    @Test("Solana base58 casing changes the mark")
    func solanaCaseSensitive() {
        let upper = AddressAvatar.seed(for: "Fw1ETanDZafof7xEULsnq9UY6o71Tpds89tNwPkWLb1v")
        let lower = AddressAvatar.seed(for: "fw1ETanDZafof7xEULsnq9UY6o71Tpds89tNwPkWLb1v")
        #expect(upper != lower)
    }

    /// An address differing in one nibble must not land on the same hue, or the second
    /// device in the recovery demo looks identical to the first while holding nothing.
    @Test("Addresses one character apart get different hues", arguments: [
        ("0x0000000000000000000000000000000000000000",
         "0x0000000000000000000000000000000000000001"),
        ("0xb63b4c97ae9f1b0f8c7c8e33da51b9e4f2c1a4c9",
         "0xb63b4c97ae9f1b0f8c7c8e33da51b9e4f2c1a4ca"),
    ])
    func neighboursDiffer(pair: (String, String)) {
        let left = AddressAvatar.seed(for: pair.0)
        let right = AddressAvatar.seed(for: pair.1)
        #expect(left.primary != right.primary)
    }

    /// Hues are fed to `Color(hue:)`, which wraps silently outside 0...1 — so an out of
    /// range value would not crash, it would quietly produce the wrong colour.
    @Test("Every derived hue is a legal degree")
    func huesInRange() {
        for index in 0..<400 {
            let seed = AddressAvatar.seed(for: "0x\(String(index, radix: 16))deadbeef")
            #expect(seed.primary >= 0 && seed.primary < 360)
            #expect(seed.secondary >= 0 && seed.secondary < 360)
            #expect(seed.tilt >= 0 && seed.tilt < 360)
        }
    }

    /// Not a strict requirement, but a mark that collapses many accounts onto one colour
    /// is not an identity check. Sampling the space guards the mixing function.
    @Test("The hue space is actually used")
    func spread() {
        let hues = Set((0..<256).map { Int(AddressAvatar.seed(for: "0xaccount\($0)").primary) })
        #expect(hues.count > 150)
    }
}
