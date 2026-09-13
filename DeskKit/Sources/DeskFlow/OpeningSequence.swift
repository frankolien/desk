import DeskAuth
import DeskChain
import DeskMoney
import DeskPerpl
import Foundation

/// Where the two contracts live, taken from `pub/context` rather than hardcoded.
public struct ExchangeAddresses: Sendable, Hashable {
    public let collateralToken: EthereumAddress
    public let exchange: EthereumAddress
    public let minimumToOpen: Money

    public enum Failure: Error, Sendable, Equatable {
        case collateralTokenMissing
        case instanceMissing
        case addressMalformed(String)
    }

    public init(context: PerplContext) throws {
        guard let token = context.collateralToken else { throw Failure.collateralTokenMissing }
        guard let instance = context.instances.first else { throw Failure.instanceMissing }
        collateralToken = try Self.address(token.address)
        exchange = try Self.address(instance.address)
        guard let minimum = instance.minAccountOpen else { throw Failure.instanceMissing }
        minimumToOpen = minimum
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

/// Opening a desk: approve, create, allow forwarding, enrol.
///
/// Four steps, not three. Each is checked before it is run, so a failure anywhere resumes
/// from the first unsatisfied precondition rather than from the beginning — which is what
/// the product document asks for, and what stops a retry paying for an approval twice.
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

    public func open(
        wallet: WalletKey,
        trading: TradingKey,
        deposit: Money,
        label: String,
        /// Forwarding cannot be read back before enrolment — the flag lives on the
        /// account object in the wallet snapshot, which needs the key this sequence is
        /// still creating. Setting it true when it already is costs one cheap
        /// transaction, so it runs unless the caller has seen it enabled.
        forwardingKnownEnabled: Bool = false,
        report: @Sendable (Progress) -> Void = { _ in }
    ) async throws -> APIKey {
        guard deposit.raw >= addresses.minimumToOpen.raw else {
            throw Failure.belowMinimum(deposit: deposit, minimum: addresses.minimumToOpen)
        }
        let held = try await collateralBalance(of: wallet.address)
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

        if try await hasAccount(wallet.address) {
            report(Progress(step: .createAccount, outcome: .alreadySatisfied))
        } else {
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

        report(Progress(step: .enrol, outcome: .started))
        let key = try await enrolment.enrol(
            address: wallet.address,
            label: label,
            signers: .using(wallet: wallet, trading: trading))
        report(Progress(step: .enrol, outcome: .finished))
        return key
    }

    // MARK: - Preconditions

    public func allowance(owner: EthereumAddress) async throws -> Money {
        let result = try await rpc.callContract(
            to: addresses.collateralToken,
            data: try Calldata.allowance(owner: owner, spender: addresses.exchange))
        return Self.money(result)
    }

    public func collateralBalance(of owner: EthereumAddress) async throws -> Money {
        let result = try await rpc.callContract(
            to: addresses.collateralToken, data: try Calldata.balanceOf(owner))
        return Self.money(result)
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

    // MARK: - Machinery

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

    /// A balance or an allowance: one uint256 word, at the collateral's scale.
    ///
    /// A number this app cannot hold is clamped rather than wrapped. An allowance is
    /// routinely set to the uint256 maximum, and wrapping that would show a tiny number
    /// and send an approval the user did not need.
    static func money(_ word: Data) -> Money {
        guard !word.isEmpty else { return .zero }
        let high = word.count > 8 ? word.prefix(word.count - 8) : Data()
        let value = word.suffix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard high.allSatisfy({ $0 == 0 }), value <= UInt64(Money.maxRaw),
              let money = Money(raw: Int64(value))
        else { return Money(raw: Money.maxRaw) ?? .zero }
        return money
    }
}
