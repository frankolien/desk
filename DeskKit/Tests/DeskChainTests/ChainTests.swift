import DeskAuth
import DeskMoney
import Foundation
import Testing
@testable import DeskChain

@Suite("Calldata")
struct CalldataTests {
    let exchange = EthereumAddress(bytes: Data(hex: "1964c32f0be608e7d29302aff5e61268e72080cc"))!
    let wallet = EthereumAddress(bytes: Data(hex: "50b240678777451befd67b7e8c3b4366482ba8f9"))!

    // Cross-checked against `cast sig` on 13 September 2026.
    @Test("selectors match the signatures they claim")
    func selectors() throws {
        let expected = [
            "approve(address,uint256)": "095ea7b3",
            "balanceOf(address)": "70a08231",
            "allowance(address,address)": "dd62ed3e",
            "createAccount(uint256)": "cab13915",
            "depositCollateral(uint256)": "bad4a01f",
            "withdrawCollateral(uint256)": "6112fe2e",
            "transfer(address,uint256)": "a9059cbb",
            "allowOrderForwarding(bool)": "7962f910",
            "getAccountByAddr(address)": "12e8eb2c",
            "requestFunds(address)": "544c7cf9",
        ]
        for (signature, selector) in expected {
            #expect(Calldata.selector(signature).hex == selector, "\(signature)")
        }
    }

    @Test("approve encodes the spender and the amount")
    func approve() throws {
        let data = try Calldata.approve(spender: exchange, amount: #require(Money(text: "100.0")))
        #expect(data.count == 4 + 32 + 32)
        #expect(data.hex == "095ea7b3"
            + "0000000000000000000000001964c32f0be608e7d29302aff5e61268e72080cc"
            + "0000000000000000000000000000000000000000000000000000000005f5e100")  // 100_000_000
    }

    @Test("createAccount carries the collateral at six decimals")
    func createAccount() throws {
        // Testnet's minimum is 100 AUSD, which is 100_000_000 raw.
        let data = try Calldata.createAccount(amount: #require(Money(text: "100.0")))
        #expect(data.hex.hasPrefix("cab13915"))
        #expect(data.suffix(32).hex.hasSuffix("05f5e100"))
    }

    @Test("allowOrderForwarding encodes a bool in a full word")
    func allowOrderForwarding() {
        #expect(Calldata.allowOrderForwarding(true).hex
            == "7962f910" + String(repeating: "00", count: 31) + "01")
        #expect(Calldata.allowOrderForwarding(false).hex
            == "7962f910" + String(repeating: "00", count: 32))
    }

    @Test("the faucet pays its argument, not the caller")
    func requestFunds() throws {
        let data = try Calldata.requestFunds(to: wallet)
        #expect(data.hex == "544c7cf9"
            + "00000000000000000000000050b240678777451befd67b7e8c3b4366482ba8f9")
    }

    @Test("the faucet's three reverts are recognised")
    func faucetReverts() {
        #expect(FaucetRevert(selector: Data(hex: "20e5bc67")) == .cooldownActive)
        #expect(FaucetRevert(selector: Data(hex: "0949dab9")) == .recipientAlreadyFunded)
        #expect(FaucetRevert(selector: Data(hex: "5274afe7")) == .transferFailed)
        #expect(FaucetRevert(selector: Data(hex: "deadbeef")) == nil)
    }
}

@Suite("Gas policy")
struct GasPolicyTests {
    // Monad charges the limit, so a conventional 2x buffer is an 86% overcharge.
    @Test("the margin is Monad's 1.075, not a library default")
    func margin() throws {
        #expect(try GasPolicy.gasLimit(estimate: 71_099) == 76_432)
        #expect(try GasPolicy.gasLimit(estimate: 130_407) == 140_188)
        #expect(try GasPolicy.gasLimit(estimate: 100_000) == 107_500)
        // What the same estimate would cost under a doubling multiplier.
        #expect(try GasPolicy.gasLimit(estimate: 71_099) * 100 / (71_099 * 2) == 53)
    }

    @Test("the margin rounds up so it never lands below the estimate")
    func marginRoundsUp() throws {
        for estimate in [1, 7, 21_000, 99_999, 1_000_003] as [UInt64] {
            #expect(try GasPolicy.gasLimit(estimate: estimate) >= estimate)
        }
    }

    @Test("a plain transfer is exact and takes no buffer")
    func plainTransfer() {
        #expect(GasPolicy.plainTransferGas == 21_000)
    }

    // Below 100 gwei a transaction is dropped as FeeTooLow; Monad's own docs still
    // show 50 gwei.
    @Test("the fee cap always clears the mempool floor")
    func feeFloor() {
        #expect(GasPolicy.maxFeePerGas(baseFeeWei: 100_000_000_000) == 202_000_000_000)
        #expect(GasPolicy.maxFeePerGas(baseFeeWei: 0) >= GasPolicy.minimumFeeWei)
        #expect(GasPolicy.maxFeePerGas(baseFeeWei: 50_000_000_000) >= GasPolicy.minimumFeeWei)
        for base in stride(from: UInt64(0), through: 500_000_000_000, by: 25_000_000_000) {
            #expect(GasPolicy.maxFeePerGas(baseFeeWei: base) >= GasPolicy.minimumFeeWei)
            #expect(GasPolicy.maxFeePerGas(baseFeeWei: base) >= base + GasPolicy.priorityFeeWei)
        }
    }
}

@Suite("Nonce registry")
struct NonceRegistryTests {
    let wallet = EthereumAddress(bytes: Data(hex: "50b240678777451befd67b7e8c3b4366482ba8f9"))!
    let other = EthereumAddress(bytes: Data(hex: "0000000000000000000000000000000000000001"))!

    // Monad's `pending` equals `latest`, so an in-flight transaction does not bump the
    // chain's count. The opening sequence sends three back to back.
    @Test("three back-to-back sends get three distinct nonces")
    func openingSequence() async throws {
        let registry = NonceRegistry()
        #expect(try await registry.reserve(for: wallet, chainCount: 5) == 5)
        #expect(try await registry.reserve(for: wallet, chainCount: 5) == 6)
        #expect(try await registry.reserve(for: wallet, chainCount: 5) == 7)
    }

    @Test("a chain count that has caught up is respected")
    func chainCatchesUp() async throws {
        let registry = NonceRegistry()
        _ = try await registry.reserve(for: wallet, chainCount: 5)
        _ = try await registry.reserve(for: wallet, chainCount: 5)
        #expect(try await registry.reserve(for: wallet, chainCount: 9) == 9)
    }

    @Test("a send that never left frees its nonce")
    func releaseReuses() async throws {
        let registry = NonceRegistry()
        let first = try await registry.reserve(for: wallet, chainCount: 5)
        await registry.release(for: wallet, nonce: first)
        #expect(try await registry.reserve(for: wallet, chainCount: 5) == first)
    }

    @Test("addresses do not share a counter")
    func addressesAreSeparate() async throws {
        let registry = NonceRegistry()
        #expect(try await registry.reserve(for: wallet, chainCount: 5) == 5)
        #expect(try await registry.reserve(for: other, chainCount: 0) == 0)
        #expect(try await registry.reserve(for: wallet, chainCount: 5) == 6)
    }
}

extension Data {
    init(hex: String) {
        precondition(hex.count % 2 == 0)
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
