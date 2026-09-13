import DeskAuth
import Foundation

/// Estimate, price, number, sign, send.
///
/// The order matters and so does what happens when a step fails: a nonce handed out for
/// a transaction that never left has to go back, or every later send in the session is
/// numbered one too high and sits in the mempool forever.
public actor TransactionSender {
    public enum Failure: Error, Sendable, Equatable {
        case nodeReturnedADifferentHash(sent: String, returned: String)
        case reverted(hash: String)
        case notMinedInTime(hash: String)
    }

    private let rpc: MonadRPC
    private let nonces: NonceRegistry

    public init(rpc: MonadRPC, nonces: NonceRegistry = NonceRegistry()) {
        self.rpc = rpc
        self.nonces = nonces
    }

    /// An estimate that reverts is raised, never replaced with a large limit. On Monad
    /// the limit is the bill, so a fallback would charge the user for the whole guess.
    public func send(
        to: EthereumAddress,
        data: Data,
        value: Data = Data(),
        from key: WalletKey
    ) async throws -> SignedTransaction {
        let estimate = try await rpc.estimateGas(to: to, data: data, from: key.address)
        let gasLimit = try GasPolicy.gasLimit(estimate: estimate)
        let maxFee = GasPolicy.maxFeePerGas(baseFeeWei: try await rpc.baseFeePerGas())
        let chainCount = try await rpc.transactionCount(of: key.address)
        let nonce = try await nonces.reserve(for: key.address, chainCount: chainCount)

        do {
            let signed = try Transaction(
                chainID: await rpc.chainID,
                nonce: nonce,
                maxPriorityFeePerGas: GasPolicy.priorityFeeWei,
                maxFeePerGas: maxFee,
                gasLimit: gasLimit,
                to: to,
                value: value,
                data: data
            ).signed(with: key)

            let returned = try await rpc.sendRawTransaction(signed)
            // The hash covers the signed bytes, so a node that answers with a different
            // one is not talking about our transaction.
            guard returned.lowercased() == signed.hashHex.lowercased() else {
                throw Failure.nodeReturnedADifferentHash(sent: signed.hashHex, returned: returned)
            }
            return signed
        } catch {
            await nonces.release(for: key.address, nonce: nonce)
            throw error
        }
    }

    /// Monad finalises in two blocks, so this is short by Ethereum's standards on purpose.
    @discardableResult
    public func wait(
        for signed: SignedTransaction,
        timeout: Duration = .seconds(30),
        poll: Duration = .milliseconds(500)
    ) async throws -> TransactionReceipt {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let receipt = try await rpc.receipt(for: signed.hashHex) {
                guard receipt.succeeded else { throw Failure.reverted(hash: signed.hashHex) }
                return receipt
            }
            try await Task.sleep(for: poll)
        }
        throw Failure.notMinedInTime(hash: signed.hashHex)
    }
}
