import DeskAuth
import DeskChain
import DeskMoney
import DeskPerpl
import Foundation

public struct ExchangeAddresses: Sendable, Hashable {
    public let collateralToken: EthereumAddress
    public let exchange: EthereumAddress
    public let minimumToOpen: Money

    public enum Failure: Error, Sendable, Equatable {
        case collateralTokenMissing
        case instanceMissing
        case addressMalformed(String)
        case addressNotPinned(String)
    }

    public init(collateralToken: EthereumAddress, exchange: EthereumAddress, minimumToOpen: Money) {
        self.collateralToken = collateralToken
        self.exchange = exchange
        self.minimumToOpen = minimumToOpen
    }

    public init(context: PerplContext, pinnedTo network: DeskNetwork? = nil) throws {
        guard let token = context.collateralToken else { throw Failure.collateralTokenMissing }
        guard let instance = context.instances.first else { throw Failure.instanceMissing }
        collateralToken = try Self.address(token.address)
        exchange = try Self.address(instance.address)
        if let network {
            try Self.match(exchange, network.pinnedExchange, "exchange")
            try Self.match(collateralToken, network.pinnedCollateralToken, "collateral token")
        }
        guard let minimum = instance.minAccountOpen else { throw Failure.instanceMissing }
        minimumToOpen = minimum
    }

    private static func match(_ address: EthereumAddress, _ pinned: String, _ what: String) throws {
        let served = address.checksummed.dropFirst(2).lowercased()
        guard served == pinned.lowercased() else { throw Failure.addressNotPinned(what) }
    }

    private static func address(_ text: String) throws -> EthereumAddress {
        let digits = text.hasPrefix("0x") || text.hasPrefix("0X") ? String(text.dropFirst(2)) : text
        var bytes = Data()
        var index = digits.startIndex
        while index < digits.endIndex, let next = digits.index(index, offsetBy: 2, limitedBy: digits.endIndex) {
            guard let byte = UInt8(digits[index..<next], radix: 16) else {
                throw Failure.addressMalformed(text)
            }
            bytes.append(byte)
            index = next
        }
        guard let address = EthereumAddress(bytes: bytes) else { throw Failure.addressMalformed(text) }
        return address
    }
}

/// Opening a desk: approve, create, allow forwarding, enrol. Each step is checked before it runs,
/// so a retry resumes at the first unsatisfied one and never pays for an approval twice.
public actor OpeningSequence {
    public enum Step: String, Sendable, Hashable, CaseIterable {
        case approve
        case createAccount
        case allowOrderForwarding
        case enrol
    }

    public enum Outcome: Sendable, Hashable {
        case alreadySatisfied
        case started
        case finished
    }

    public struct Progress: Sendable, Hashable {
        public let step: Step
        public let outcome: Outcome
    }

    public enum Failure: Error, Sendable, Equatable {
        case belowMinimum(deposit: Money, minimum: Money)
        case insufficientCollateral(held: Money, needed: Money)
    }

    private let rpc: MonadRPC
    private let sender: TransactionSender
    private let enrolment: Enrolment
    private let addresses: ExchangeAddresses

    public init(
        rpc: MonadRPC,
        sender: TransactionSender,
        enrolment: Enrolment,
        addresses: ExchangeAddresses
    ) {
        self.rpc = rpc
        self.sender = sender
        self.enrolment = enrolment
        self.addresses = addresses
    }

    /// Returns the derived key index Perpl enrolled; every later session has to derive that one.
    public func open(
        wallet: WalletKey,
        tradingKeys: @escaping @Sendable (UInt32) throws -> TradingKey,
        indices: Range<UInt32>,
        deposit: Money,
        label: String,
        report: @Sendable (Progress) -> Void = { _ in }
    ) async throws -> (apiKey: APIKey, index: UInt32) {
        try await prepare(wallet: wallet, deposit: deposit, forwardingKnownEnabled: false, report: report)
        report(Progress(step: .enrol, outcome: .started))
        let enrolled = try await enrolment.enrolFirstUnregistered(
            address: wallet.address, label: label, indices: indices,
            signers: { .using(wallet: wallet, trading: try tradingKeys($0)) })
        report(Progress(step: .enrol, outcome: .finished))
        return enrolled
    }

    public func open(
        wallet: WalletKey,
        trading: TradingKey,
        deposit: Money,
        label: String,
        /// Forwarding cannot be read back before enrolment (the flag needs the key being created),
        /// so it is set unless the caller has seen it enabled; re-setting costs one cheap transaction.
        forwardingKnownEnabled: Bool = false,
        report: @Sendable (Progress) -> Void = { _ in }
    ) async throws -> APIKey {
        try await prepare(wallet: wallet, deposit: deposit,
                          forwardingKnownEnabled: forwardingKnownEnabled, report: report)
        report(Progress(step: .enrol, outcome: .started))
        let key = try await enrolment.enrol(
            address: wallet.address,
            label: label,
            signers: .using(wallet: wallet, trading: trading))
        report(Progress(step: .enrol, outcome: .finished))
        return key
    }

    /// The account is looked for first: an existing one already holds its collateral at the exchange.
    private func prepare(
        wallet: WalletKey,
        deposit: Money,
        forwardingKnownEnabled: Bool,
        report: @Sendable (Progress) -> Void
    ) async throws {
        if try await hasAccount(wallet.address) {
            report(Progress(step: .approve, outcome: .alreadySatisfied))
            report(Progress(step: .createAccount, outcome: .alreadySatisfied))
        } else {
            guard deposit.raw >= addresses.minimumToOpen.raw else {
                throw Failure.belowMinimum(deposit: deposit, minimum: addresses.minimumToOpen)
            }
            let held = try await walletAUSD(of: wallet.address)
            guard held.raw >= deposit.raw else {
                throw Failure.insufficientCollateral(held: held, needed: deposit)
            }
            if try await allowance(owner: wallet.address).raw >= deposit.raw {
                report(Progress(step: .approve, outcome: .alreadySatisfied))
            } else {
                try await run(
                    .approve, from: wallet, to: addresses.collateralToken,
                    data: try Calldata.approve(spender: addresses.exchange, amount: deposit),
                    report: report)
            }
            try await run(
                .createAccount, from: wallet, to: addresses.exchange,
                data: try Calldata.createAccount(amount: deposit), report: report)
        }

        if forwardingKnownEnabled {
            report(Progress(step: .allowOrderForwarding, outcome: .alreadySatisfied))
        } else {
            try await run(
                .allowOrderForwarding, from: wallet, to: addresses.exchange,
                data: Calldata.allowOrderForwarding(true), report: report)
        }
    }

    public func allowance(owner: EthereumAddress) async throws -> Money {
        let result = try await rpc.callContract(
            to: addresses.collateralToken,
            data: try Calldata.allowance(owner: owner, spender: addresses.exchange))
        return ABIMoney.decode(result)
    }

    public func walletAUSD(of owner: EthereumAddress) async throws -> Money {
        let result = try await rpc.callContract(
            to: addresses.collateralToken, data: try Calldata.balanceOf(owner))
        return ABIMoney.decode(result)
    }

    /// `getAccountByAddr` reverts rather than returning zero when no account exists, so
    /// a revert here is an answer and not an error.
    public func hasAccount(_ address: EthereumAddress) async throws -> Bool {
        do {
            let result = try await rpc.callContract(
                to: addresses.exchange, data: try Calldata.getAccountByAddr(address))
            return !result.isEmpty
        } catch let failure as MonadRPC.Failure {
            guard case .rejected = failure else { throw failure }
            return false
        }
    }

    private func run(
        _ step: Step,
        from wallet: WalletKey,
        to target: EthereumAddress,
        data: Data,
        report: @Sendable (Progress) -> Void
    ) async throws {
        report(Progress(step: step, outcome: .started))
        let signed = try await sender.send(to: target, data: data, from: wallet)
        try await sender.wait(for: signed)
        report(Progress(step: step, outcome: .finished))
    }

    static func money(_ word: Data) -> Money { ABIMoney.decode(word) }
}
