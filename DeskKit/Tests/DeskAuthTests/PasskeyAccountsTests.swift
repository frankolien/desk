import Foundation
import Testing
@testable import DeskAuth

/// The vector was computed with @scure/bip39, @scure/bip32 and @noble/curves — the
/// libraries Mera's own demo uses. If Swift and this disagree, Swift is wrong.
@Suite("Mera derivation")
struct PasskeyAccountsTests {
    let prfOutput = Data((1...32).map(UInt8.init))

    @Test("the PRF salt is Mera's, unchanged")
    func prfSalt() {
        #expect(PasskeyAccounts.prfSalt.hex
            == "896d46ac4ac191885c46137439db7bb52fb05cff3ecd34af7cdae0a1e0c00db9")
    }

    @Test("derives the same accounts as Mera")
    func derivesMerasAccounts() throws {
        let wallet = try PasskeyAccounts.deriveWalletKey(prfOutput: prfOutput)
        let trading = try PasskeyAccounts.deriveTradingKey(prfOutput: prfOutput)

        #expect(wallet.privateKey.hex
            == "7c56100e187f2845a35ce856646662dfc2024be2b4a150b45ad1f62564617128")
        #expect(wallet.address.checksummed == "0x50B240678777451BEfd67B7e8c3b4366482ba8F9")
        #expect(trading.seed.hex
            == "e6ab0994f80a3abf9a1c10d8d27733d24de8c873af6bee177a93a0da5a4b0f79")
        #expect(trading.publicKey.hex
            == "89684d872dd939e6c13b2c9d501465bdfe3546a81d32c2889dca5b6847046100")
    }

    @Test("the address-only path agrees with the wallet path")
    func addressOnlyAgrees() throws {
        #expect(try PasskeyAccounts.deriveAddress(prfOutput: prfOutput)
            == PasskeyAccounts.deriveWalletKey(prfOutput: prfOutput).address)
    }

    @Test("the mnemonic is the one Mera's wordlist produces")
    func mnemonic() throws {
        #expect(try BIP39.mnemonic(entropy: prfOutput).joined(separator: " ")
            == "absurd avoid scissors anxiety gather lottery category door army half long "
             + "cage bachelor another expect people blade school educate curtain scrub "
             + "monitor lady beyond")
    }

    @Test("derivation is deterministic")
    func deterministic() throws {
        let first = try PasskeyAccounts.deriveWalletKey(prfOutput: prfOutput)
        let second = try PasskeyAccounts.deriveWalletKey(prfOutput: prfOutput)
        #expect(first.address == second.address)
        #expect(first.privateKey.constantTimeEquals(second.privateKey))

        let firstTrading = try PasskeyAccounts.deriveTradingKey(prfOutput: prfOutput)
        let secondTrading = try PasskeyAccounts.deriveTradingKey(prfOutput: prfOutput)
        #expect(firstTrading.seed.constantTimeEquals(secondTrading.seed))
    }

    @Test("each index gets its own pair of accounts")
    func indexSeparation() throws {
        let zero = try PasskeyAccounts.deriveWalletKey(prfOutput: prfOutput, index: 0)
        let one = try PasskeyAccounts.deriveWalletKey(prfOutput: prfOutput, index: 1)
        #expect(zero.address != one.address)
        #expect(try PasskeyAccounts.deriveTradingKey(prfOutput: prfOutput, index: 0).publicKey
            != PasskeyAccounts.deriveTradingKey(prfOutput: prfOutput, index: 1).publicKey)
    }

    @Test("PRF output of the wrong length is refused")
    func wrongLengthRefused() {
        for count in [0, 16, 31, 33, 64] {
            #expect(throws: PasskeyAccounts.Failure.prfOutputMustBe32Bytes(count)) {
                try PasskeyAccounts.deriveWalletKey(prfOutput: Data(repeating: 0, count: count))
            }
            #expect(throws: PasskeyAccounts.Failure.prfOutputMustBe32Bytes(count)) {
                try PasskeyAccounts.deriveTradingKey(prfOutput: Data(repeating: 0, count: count))
            }
        }
    }

    @Test("EIP-55 checksums the reference address")
    func eip55() throws {
        let address = try #require(EthereumAddress(
            bytes: Data(hex: "5aaeb6053f3e94c9b9a09f33669435e7ef1beaed")))
        #expect(address.checksummed == "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed")
    }

    @Test("the wordlist is intact")
    func wordlist() {
        #expect(BIP39Wordlist.words.count == 2048)
        #expect(BIP39Wordlist.words.first == "abandon")
        #expect(BIP39Wordlist.words.last == "zoo")
        #expect(Hashing.sha256(Data(BIP39Wordlist.words.joined(separator: "\n").utf8)).hex
            == "187db04a869dd9bc7be80d21a86497d692c0db6abd3aa8cb6be5d618ff757fae")
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    /// Traps on a malformed literal. A typo in a future vector must fail loudly rather
    /// than quietly become zeroes that something then asserts against.
    init(hex: String) {
        precondition(hex.count % 2 == 0, "hex literal has an odd length")
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                preconditionFailure("not hex: \(hex[index..<next])")
            }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

extension SecureBytes {
    var hex: String { withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() } }
}
