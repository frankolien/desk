import DeskAuth
import DeskChain
import DeskMoney
import Foundation

/// One read of everything the account screens show.
///
/// The rule this type exists to enforce: **one balance failing must never blank the
/// others.** Three independent RPC calls go out; each lands in its own slot with its own
/// outcome, so a hiccup on the AUSD read leaves the gas balance and the desk status
/// exactly as they were. The alternative — a single throwing call that returns a whole
/// snapshot or nothing — turns any one flaky read into an empty screen, which a person
/// reads as "my money is gone" rather than as "the network is slow".
///
/// Nothing here is cached or held. The caller owns freshness, through `LastGood`.
public struct BalanceReader: Sendable {
    /// A value that is either present or explained. Never an optional, because a `nil`
    /// balance and a zero balance are different facts and the screen renders them
    /// differently — `--` against `0.00`.
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
        /// AUSD sitting in the wallet, not at the exchange.
        public let walletAUSD: Read<Money>
        /// MON, for gas.
        public let gas: Read<NativeAmount>
        /// Whether a Perpl account exists for this address.
        public let hasDesk: Read<Bool>

        /// True when every read failed, which is the signal that the network is down
        /// rather than that one call was unlucky.
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

    /// The three reads, concurrently. They are independent, and running them in series
    /// would make the screen wait for the slowest three times over.
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

    /// A sentence a person can act on, and never the underlying error's own text — a
    /// transport error can carry a URL, and a URL can carry a key.
    static func sentence(for error: any Error, reading subject: String) -> String {
        if let failure = error as? MonadRPC.Failure, case .rejected = failure {
            return "The network refused the request for \(subject)."
        }
        return "Could not reach Monad to read \(subject)."
    }
}

/// A uint256 word at AUSD's scale.
///
/// Shared with `OpeningSequence`, which needs the identical clamp: a number this app
/// cannot hold is clamped rather than wrapped, because an allowance is routinely the
/// uint256 maximum and wrapping that shows a tiny number.
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
