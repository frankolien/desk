import Foundation
import Testing
@testable import DeskAuth

/// One test per finding from the adversarial audit of 13 September 2026. Every
/// standards vector passed while all of this was broken.
@Suite("Auth audit regressions")
struct AuthAuditRegressionTests {
    let prfOutput = Data((1...32).map(UInt8.init))

    // An index with the high bit set used to harden the last EVM step and, because `|`
    // is idempotent, collapse two ed25519 accounts onto one key: index 0 and index
    // 2^31 shared a Perpl API key while showing different addresses.
    @Test("an index that would harden the path is refused")
    func hardenedIndexRefused() {
        for index: UInt32 in [0x8000_0000, 0x8000_0001, 0x8000_0007, 0xFFFF_FFFF] {
            #expect(throws: PasskeyAccounts.Failure.indexOutOfRange(index)) {
                try PasskeyAccounts.deriveTradingKey(prfOutput: prfOutput, index: index)
            }
            #expect(throws: PasskeyAccounts.Failure.indexOutOfRange(index)) {
                try PasskeyAccounts.deriveWalletKey(prfOutput: prfOutput, index: index)
            }
            #expect(throws: PasskeyAccounts.Failure.indexOutOfRange(index)) {
                try PasskeyAccounts.deriveAddress(prfOutput: prfOutput, index: index)
            }
        }
        #expect(throws: Never.self) {
            try PasskeyAccounts.deriveTradingKey(prfOutput: prfOutput, index: 0x7FFF_FFFF)
        }
    }

    // BIP-39 mandates NFKD; Foundation's `precomposed...` spelling is NFKC. Invisible
    // with Mera's empty passphrase and an ASCII wordlist, which is why the pinned
    // vector could not see it. Ground truth from @scure/bip39.
    @Test("the seed uses NFKD, so a non-ASCII passphrase matches every other wallet")
    func seedNormalisationIsNFKD() throws {
        let words = try BIP39.mnemonic(entropy: prfOutput)
        let cases = [
            ("", "c93245abac584b8778e205e63b3ed21eccf6ffe64f41f2b2ea01a37430ad7a09"),
            ("TREZOR", "bc723d9fe7dcb0c4a3056f430a44f6da309e07bbb43d1480b179468cb178baff"),
            ("\u{30AC}", "641f0d2d0018605aa33e7e622b3c5362838361c3c6f904c47aeaee7554b68bc5"),
            ("\u{00E9}", "38c01a0c432af9d3147776df0a61a0bf05b7c7b44c48f3ec60234365e3919ccb"),
        ]
        for (passphrase, expected) in cases {
            #expect(BIP39.seed(mnemonic: words, passphrase: passphrase).prefix(32).hex == expected)
        }
    }

    @Test("equivalent Unicode spellings of a passphrase agree")
    func normalisationIsStable() throws {
        let words = try BIP39.mnemonic(entropy: prfOutput)
        #expect(BIP39.seed(mnemonic: words, passphrase: "\u{00E9}")
            == BIP39.seed(mnemonic: words, passphrase: "e\u{0301}"))
    }

    // The one hand-written primitive used to trap on `1..<0`.
    @Test("pbkdf2 declines degenerate parameters instead of trapping")
    func pbkdf2DoesNotTrap() {
        #expect(Hashing.pbkdf2SHA512(password: Data("x".utf8), salt: Data(), iterations: 0, length: 32).isEmpty)
        #expect(Hashing.pbkdf2SHA512(password: Data("x".utf8), salt: Data(), iterations: 2048, length: 0).isEmpty)
        #expect(Hashing.pbkdf2SHA512(password: Data("x".utf8), salt: Data(), iterations: 1, length: 65).count == 65)
    }

    @Test("an empty SecureBytes constructs, compares and deallocates")
    func emptySecureBytes() {
        let empty = SecureBytes(Data())
        #expect(empty.count == 0)
        #expect(empty.constantTimeEquals(SecureBytes(Data())))
        #expect(!empty.constantTimeEquals(SecureBytes(Data([1]))))
        empty.withUnsafeBytes { #expect($0.count == 0) }
    }

    @Test("secrets are never carried in a failure's payload")
    func failuresCarryNoSecrets() {
        // Every case holds a length or an index. If one ever gains a Data payload it
        // lands in a crash report, so this asserts on the rendered description.
        let failures: [PasskeyAccounts.Failure] = [
            .prfOutputMustBe32Bytes(31), .indexOutOfRange(0x8000_0000),
            .evmDerivationFailed, .ed25519DerivationFailed, .addressDerivationFailed,
        ]
        let secret = prfOutput.hex
        for failure in failures {
            #expect(!"\(failure)".lowercased().contains(secret))
        }
    }
}
