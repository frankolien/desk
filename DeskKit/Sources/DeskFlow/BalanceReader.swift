import DeskAuth
import DeskChain
import DeskMoney
import Foundation

/// One balance failing must never blank the others: each read lands in its own slot with
/// its own outcome.
public struct BalanceReader: Sendable {
    public enum Read<Value: Sendable & Hashable>: Sendable, Hashable {
        case ok(Value)
        case failed(String)

        public var value: Value? {
            if case .ok(let value) = self { return value }
            return nil
        }

        public var problem: String? {
            if case .failed(let reason) = self { return reason }
            return nil
        }
    }

    public struct Snapshot: Sendable, Hashable {
        public let walletAUSD: Read<Money>
        public let gas: Read<NativeAmount>
        public let hasDesk: Read<Bool>

        public var isTotalFailure: Bool {
            walletAUSD.problem != nil && gas.problem != nil && hasDesk.problem != nil
        }
    }

    private let rpc: MonadRPC
    private let collateralToken: EthereumAddress
    private let exchange: EthereumAddress

    public init(rpc: MonadRPC, addresses: ExchangeAddresses) {
        self.rpc = rpc
        self.collateralToken = addresses.collateralToken
        self.exchange = addresses.exchange
    }

    public func read(for address: EthereumAddress) async -> Snapshot {
        async let ausd = walletAUSD(of: address)
        async let gas = gasBalance(of: address)
        async let desk = deskExists(for: address)
        return await Snapshot(walletAUSD: ausd, gas: gas, hasDesk: desk)
    }

    private func walletAUSD(of address: EthereumAddress) async -> Read<Money> {
        do {
            let word = try await rpc.callContract(
                to: collateralToken, data: try Calldata.balanceOf(address))
            return .ok(ABIMoney.decode(word))
        } catch {
            return .failed(Self.sentence(for: error, reading: "your AUSD balance"))
        }
    }

    private func gasBalance(of address: EthereumAddress) async -> Read<NativeAmount> {
        do {
            return .ok(NativeAmount(bigEndian: try await rpc.balance(of: address)))
        } catch {
            return .failed(Self.sentence(for: error, reading: "your MON balance"))
        }
    }

    /// `getAccountByAddr` reverts rather than returning zero when no account exists, so a
    /// revert is an answer — `false` — and only a transport failure is a failure.
    private func deskExists(for address: EthereumAddress) async -> Read<Bool> {
        do {
            let result = try await rpc.callContract(
                to: exchange, data: try Calldata.getAccountByAddr(address))
            return .ok(!result.isEmpty)
        } catch let failure as MonadRPC.Failure {
            if case .rejected = failure { return .ok(false) }
            return .failed(Self.sentence(for: failure, reading: "whether your desk is open"))
        } catch {
            return .failed(Self.sentence(for: error, reading: "whether your desk is open"))
        }
    }

    /// Never the underlying error's text: a transport error can carry a URL, and a URL a key.
    static func sentence(for error: any Error, reading subject: String) -> String {
        if let failure = error as? MonadRPC.Failure, case .rejected = failure {
            return "The network refused the request for \(subject)."
        }
        return "Could not reach Monad to read \(subject)."
    }
}

/// A uint256 word at AUSD's scale, clamped rather than wrapped: an allowance is routinely
/// the uint256 maximum, and wrapping it shows a tiny number.
public enum ABIMoney {
    public static func decode(_ word: Data) -> Money {
        guard !word.isEmpty else { return .zero }
        let high = word.count > 8 ? word.prefix(word.count - 8) : Data()
        let value = word.suffix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard high.allSatisfy({ $0 == 0 }), value <= UInt64(Money.maxRaw),
              let money = Money(raw: Int64(value))
        else { return Money(raw: Money.maxRaw) ?? .zero }
        return money
    }
}
