import DeskAuth
import DeskChain
import DeskFlow
import DeskMoney
import DeskPerpl
import Foundation
import Observation
import UIKit

/// Where the app is. Not a router: the state decides the screen, so there is no way to
/// be on Fund with no address or on Market with no desk.
@MainActor
@Observable
final class AppModel {
    enum Stage: Equatable {
        case welcome
        case needsDesk
        case trading
    }

    private(set) var stage: Stage = .welcome
    private(set) var address: EthereumAddress?
    private(set) var signInProblem: String?
    private(set) var isWorking = false

    /// Collateral held at the exchange, backing positions.
    ///
    /// Unlike the two below, this does not come from the chain. It arrives on the
    /// authenticated socket with the account snapshot, so it stays unavailable — `--`,
    /// not `0.00` — until a real session exists. Showing a zero here would tell a funded
    /// user their collateral is gone.
    private(set) var collateral = LastGood<Money>()
    /// AUSD in the wallet: what can still be deposited. Read from the chain.
    private(set) var walletAUSD = LastGood<Money>()
    /// MON, for gas. Eighteen decimals, so deliberately not `Money`.
    private(set) var walletMON = LastGood<NativeAmount>()
    /// Whether a Perpl account exists for this address, read from the chain rather than
    /// assumed from having signed in.
    private(set) var hasDesk = LastGood<Bool>()
    /// The open position, exactly as the venue reports it.
    ///
    /// Kept raw rather than as derived figures, because the figures need a mark and the
    /// mark belongs to the market model. Deriving them at the point of display means
    /// every figure on the screen descends from the one tick that was current when it was
    /// drawn, rather than from two ticks a frame apart.
    ///
    /// It arrives on the authenticated socket as `mt: 26` then `mt: 27`, so it stays nil
    /// until a real session exists. Nil is rendered as "no position", which is correct
    /// while there is no way to have one.
    private(set) var openPosition: PerplPosition?
    private(set) var openPositions: [PerplPosition] = []

    private(set) var sessionRemaining: Duration = .zero
    /// Why the last attempt to open a desk stopped, if it did.
    private(set) var openingProblem: String?
    /// A setup failure that happened before the exchange-opening sequence.
    private(set) var fundingProblem: String?
    /// Which of the four steps is running, for the Fund screen to render.
    private(set) var openingStep: OpeningSequence.Progress?
    /// Handed the enrolled key the moment one exists.
    let trading = TradingSession()
    /// Shown once, ever, the first time leverage is reached.
    var hasSeenLeverageExplainer = false
    private let session = SigningSession()
    private let passkey: any PasskeyService
    private let apiKeys = APIKeyStore.standard
    private var ticker: Task<Void, Never>?
    private var balancePoller: Task<Void, Never>?
    /// Built once, on the first refresh: it needs the venue's context to learn which
    /// contracts to read, and that is one network call rather than a constant.
    private var balances: BalanceReader?

    init(passkey: any PasskeyService) {
        self.passkey = passkey
        trading.onAccount = { [weak self] account in
            guard let free = account.free else { return }
            self?.collateral.record(free)
        }
        trading.onPositions = { [weak self] positions in
            let open = positions.filter(\.isOpen)
            self?.openPositions = open
            self?.openPosition = open.first
        }
        #if DEBUG
        // `-stage fund|market` jumps straight to a screen, so each one can be captured
        // and reviewed without walking the flow. Debug only, and never a way into a
        // signed-in state on a real build.
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-stage"),
           index + 1 < ProcessInfo.processInfo.arguments.count {
            let name = ProcessInfo.processInfo.arguments[index + 1]
            stage = switch name {
            case "market", "signals", "signal-detail", "empty", "watchlist", "search": .trading
            case "fund": .needsDesk
            default: .welcome
            }
            // `empty` is the state a real first run is actually in: signed in, funded by
            // nothing. It is the screen most likely to be wrong and the least likely to
            // be looked at, so it gets its own way in.
            if name == "empty" {
                address = try? PasskeyAccounts.deriveAddress(prfOutput: Data(repeating: 0x2A, count: 32))
                walletAUSD.record(.zero)
                walletMON.record(.zero)
                collateral.record(.zero)
                hasDesk.record(false)
                sessionRemaining = .seconds(596)
            } else if stage != .welcome {
                address = try? PasskeyAccounts.deriveAddress(prfOutput: Data(repeating: 0x2A, count: 32))
                walletAUSD.record(Money(text: "10000") ?? .zero)
                // 0.19 MON, written at its own eighteen-decimal scale rather than
                // borrowed from AUSD's six.
                walletMON.record(NativeAmount(raw: 190_000_000_000_000_000) ?? .zero)
                collateral.record(Money(text: "1282.18") ?? .zero)
                hasDesk.record(true)
                openPosition = Self.reviewPosition
                openPositions = Self.reviewPosition.map { [$0] } ?? []
                sessionRemaining = .seconds(552)
            }
        }
        #endif
    }

    #if DEBUG
    /// A position shaped exactly as `mt: 26` sends one, so the position UI can be drawn
    /// and reviewed before the authenticated socket exists. Decoded from JSON rather than
    /// built field by field, because a fixture that skips the decoder proves nothing
    /// about the decoder.
    ///
    /// A long of 1.00000 BTC entered at 77,000.0 against 5,000 AUSD, which is roughly 15x
    /// — near the ceiling, so the liquidation figure on screen is a real one and close
    /// enough to matter.
    static let reviewPosition: PerplPosition? = {
        let body = Data(#"""
        {"mkt":16,"acc":42,"pid":"7","sd":1,"c":"5000000000","ep":770000,"epr":21845,
         "s":100000,"lv":1500,"efs":"0","xfs":"0","fee":"3850000","st":1}
        """#.utf8)
        return try? JSONDecoder().decode(PerplPosition.self, from: body)
    }()
    #endif

    var sessionFraction: Double {
        let total = Double(SigningSession.defaultLifetime.components.seconds)
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(sessionRemaining.components.seconds) / total))
    }

    var addressShort: String {
        guard let address else { return "—" }
        let text = address.checksummed
        return text.prefix(6) + "…" + text.suffix(4)
    }

    /// Enough headroom for the faucet call plus the account-opening transactions.
    /// A non-zero balance is not enough: the faucet call alone has measured ~0.0143 MON.
    var hasSetupGas: Bool {
        guard let held = walletMON.value else { return false }
        return held.raw >= 50_000_000_000_000_000 // 0.05 MON
    }

    func advance(to stage: Stage) { self.stage = stage }

    /// The checksummed address, not the shortened one — a truncated address pasted into a
    /// block explorer is a support ticket.
    func copyAddress() {
        guard let address else { return }
        UIPasteboard.general.string = address.checksummed
    }

    /// Whether the welcome screen should offer to create a passkey.
    ///
    /// True exactly when this device has never derived an address. It cannot be inferred
    /// from a failed sign-in: iOS reports a dismissed sheet and "no credential matched"
    /// with the same `.canceled` code, so waiting for a distinguishable failure would
    /// leave a genuinely new user with no way in at all.
    ///
    /// So the offer is present from the start on a fresh device and absent once an
    /// account exists here — which is the case that matters, because creating a second
    /// passkey makes a second wallet and strands the first. Sign-in stays the primary
    /// action, since a passkey synced from another device is the commoner reason for a
    /// device to have none of its own.
    var mayOfferCreate: Bool { passkey.lastSeenAddress == nil }

    func signIn() async {
        await authenticate(creating: false)
    }

    /// Reached only from an explicit "create a new account" choice.
    func createAccount() async {
        await authenticate(creating: true)
    }

    private func authenticate(creating: Bool) async {
        isWorking = true
        signInProblem = nil
        defer { isWorking = false }
        do {
            let keys = creating
                ? try await passkey.createAccounts()
                : try await passkey.deriveAccounts()
            // The address guard runs before any balance is shown: Apple's synced-passkey
            // bug derives a different address on a second device, and rendering that
            // account's zero would read as theft.
            let verdict = AddressGuard.check(derived: keys.address, against: passkey.lastSeenAddress)
            guard verdict.mayShowBalance else {
                signInProblem = "This passkey derived a different address than last time. "
                    + "Your funds are safe — do not continue until this is sorted."
                return
            }
            address = keys.address
            await session.open(keys.trading)
            startTicking()
            // `hasDesk` is an on-chain fact. Passkey derivation deliberately cannot
            // answer it, so checking `keys.hasDesk` here always sent returning users
            // back to setup. Read the account before choosing the destination.
            await refreshBalances()
            startPollingBalances()
            if hasDesk.value == true, let apiKey = apiKeys.load(for: keys.address) {
                // A returning user used to jump straight to the trading UI without
                // rebuilding the authenticated socket. The ticket then had no desk and
                // could only answer “not connected”. Sign-in now restores the complete
                // trading session before the first order can be opened.
                let context = try await PerplREST(configuration: .testnet()).context()
                await enterTrading(apiKey: apiKey, context: context)
            } else {
                stage = .needsDesk
            }
        } catch PasskeyFailure.cancelledByUser {
            // A dismissed sheet is not a failure and not a reason to offer anything. It
            // used to run a registration, which is how a mis-tap became a second wallet.
            signInProblem = nil
        } catch let failure as PasskeyFailure {
            signInProblem = failure.sentence
        } catch {
            signInProblem = "Sign in could not finish. Try again."
        }
    }

    /// Opens the desk for real: approve, create the account, allow forwarding, enrol.
    ///
    /// The whole sequence runs inside one borrowed wallet key, so it is one Face ID
    /// prompt rather than four. The key is scoped to the closure and never returned,
    /// which is the only reason it is safe to hold a secp256k1 key across four
    /// transactions at all.
    ///
    /// Resumable by construction: each step checks whether it is already satisfied before
    /// spending anything, so a sequence interrupted after the approval picks up at the
    /// account rather than paying for the approval twice.
    func openDesk() async {
        isWorking = true
        openingProblem = nil
        openingStep = nil
        defer { isWorking = false }
        do {
            // Never trust the figure a view happened to render. Funding can arrive while
            // this screen is open, and opening with a stale cached zero produced the
            // contradictory “10,000 ready / deposit 0.00” state this guard replaces.
            await refreshBalances()
            guard let deposit = walletAUSD.value else {
                openingProblem = walletAUSD.lastFailure
                    ?? "Your AUSD balance is still loading. Try again in a moment."
                return
            }
            let rest = PerplREST(configuration: try .testnet())
            let context = try await rest.context()
            let addresses = try ExchangeAddresses(context: context)
            if let address, let apiKey = apiKeys.load(for: address) {
                await enterTrading(apiKey: apiKey, context: context)
                return
            }
            let rpc = MonadRPC(configuration: try .testnet())
            let sequence = OpeningSequence(
                rpc: rpc,
                sender: TransactionSender(rpc: rpc),
                enrolment: Enrolment(rest: rest, chainID: context.chain.chainID),
                addresses: addresses)

            let apiKey = try await passkey.withKeys { [weak self] wallet, trading in
                try await sequence.open(
                    wallet: wallet,
                    trading: trading,
                    deposit: deposit,
                    label: "Desk on iPhone",
                    report: { progress in
                        Task { @MainActor in self?.openingStep = progress }
                    })
            }
            if let address { try apiKeys.save(apiKey, for: address) }

            // The key exists only now. Handing it to the session is what turns the
            // ticket's confirm button from a sentence into an order.
            await enterTrading(apiKey: apiKey, context: context)
        } catch {
            openingProblem = Self.openingSentence(for: error)
            openingStep = nil
        }
    }

    private func enterTrading(apiKey: APIKey, context: PerplContext) async {
        guard let market = context.market(id: 16) else { return }
        trading.adopt(apiKey: apiKey, session: session, market: market)
        if let head = context.chain.gas?.headBlock { trading.noteHeadBlock(head) }
        // The account and API key already exist at this point. A live-stream outage is
        // a connectivity state, not a reason to send the user back through onboarding.
        stage = .trading
        await refreshBalances()
        try? await trading.connect(lastForwarded: 0)
    }

    /// Claims the real test collateral from Agora's Monad-testnet faucet.
    /// The wallet signs the faucet call because the caller pays its gas; the faucet pays
    /// the derived address supplied in calldata.
    func claimTestAUSD() async {
        guard let address else { return }
        guard hasSetupGas else {
            fundingProblem = "Add at least 0.05 MON before claiming test AUSD. It pays for setup gas."
            return
        }
        isWorking = true
        fundingProblem = nil
        defer { isWorking = false }
        do {
            let faucet = try Self.ethereumAddress("d236c18d274e54faccc3dd9dda4b27965a73ee6c")
            let rpc = MonadRPC(configuration: try .testnet())
            let sender = TransactionSender(rpc: rpc)
            let signed = try await passkey.withKeys { wallet, _ in
                try await sender.send(
                    to: faucet,
                    data: try Calldata.requestFunds(to: address),
                    from: wallet)
            }
            _ = try await sender.wait(for: signed)
            // Monad's balance view can trail a mined receipt briefly.
            try? await Task.sleep(for: .milliseconds(1400))
            await refreshBalances()
        } catch let failure as MonadRPC.Failure {
            if case .rejected(_, _, let data) = failure,
               let data, let reason = FaucetRevert(selector: data) {
                fundingProblem = switch reason {
                case .cooldownActive: "The faucet was just used. Wait a minute, then try again."
                case .recipientAlreadyFunded: "This wallet already has enough test AUSD."
                case .transferFailed: "The faucet could not send test AUSD right now."
                }
            } else {
                fundingProblem = "Test AUSD could not be claimed. Your wallet was not charged."
            }
        } catch let failure as PasskeyFailure {
            fundingProblem = failure.sentence
        } catch {
            fundingProblem = "Test AUSD could not be claimed. Your wallet was not charged."
        }
    }

    private static func ethereumAddress(_ digits: String) throws -> EthereumAddress {
        var bytes = Data()
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            guard let byte = UInt8(digits[index..<next], radix: 16) else {
                throw MonadRPC.Failure.malformedResponse("faucet address")
            }
            bytes.append(byte)
            index = next
        }
        guard let address = EthereumAddress(bytes: bytes) else {
            throw MonadRPC.Failure.malformedResponse("faucet address")
        }
        return address
    }

    /// The sentence a failed opening shows. Never the underlying error's text: a
    /// transport error can carry a URL and a URL can carry a key.
    static func openingSentence(for error: any Error) -> String {
        switch error {
        case OpeningSequence.Failure.belowMinimum(let deposit, let minimum):
            return "Perpl needs at least \(minimum.display()) AUSD to open a desk, and "
                + "this would deposit \(deposit.display())."
        case OpeningSequence.Failure.insufficientCollateral(let held, let needed):
            return "This wallet holds \(held.display()) AUSD and the deposit needs "
                + "\(needed.display()). Claim more from the faucet first."
        case let failure as PasskeyFailure:
            return failure.sentence
        case PerplREST.Failure.unauthorized(let status, let detail):
            return "Perpl refused trading-key registration (HTTP \(status))"
                + (detail.map { ": \($0)" } ?? ".")
        case PerplREST.Failure.rejected(let status, let detail):
            return "Perpl rejected trading-key registration (HTTP \(status))"
                + (detail.map { ": \($0)" } ?? ".")
        case PerplREST.Failure.rateLimited(let retryAfter):
            if let retryAfter {
                return "Perpl is rate limiting setup. Try again in \(retryAfter) seconds."
            }
            return "Perpl is rate limiting setup. Wait a moment, then try again."
        case PerplREST.Failure.malformedResponse:
            return "Perpl returned an enrollment response this build could not read."
        case Enrolment.Failure.apiKeyMissing:
            return "Perpl registered the trading key but did not return its API token."
        default:
            return "Your desk could not be opened. Nothing was deposited that you cannot "
                + "recover — try again, and the steps already done will be skipped."
        }
    }

    // MARK: - Withdrawing

    private(set) var withdrawal: Withdrawal = .idle
    private(set) var deposit: Deposit = .idle

    enum Deposit: Equatable {
        case idle
        case approving
        case depositing
        case sent(String)
        case failed(String)

        var isBusy: Bool { self == .approving || self == .depositing }
    }

    /// Moves AUSD from the wallet into the existing Perpl account. Receiving AUSD and
    /// depositing collateral are intentionally separate operations on-chain; the old
    /// sheet exposed only the former and made a funded wallet look trade-ready when it
    /// was not.
    func depositAUSD(_ amount: Money) async {
        guard !deposit.isBusy, amount.raw > 0 else { return }
        deposit = .approving
        do {
            await refreshBalances()
            guard let held = walletAUSD.value, held >= amount else {
                deposit = .failed("Your wallet does not hold that much AUSD.")
                return
            }
            let rest = PerplREST(configuration: try .testnet())
            let context = try await rest.context()
            let addresses = try ExchangeAddresses(context: context)
            guard let minimum = context.instances.first?.minDeposit, amount >= minimum else {
                deposit = .failed("Perpl's minimum deposit is \(context.instances.first?.minDeposit?.display() ?? "—") AUSD.")
                return
            }
            let rpc = MonadRPC(configuration: try .testnet())
            let sender = TransactionSender(rpc: rpc)
            let hash = try await passkey.withKeys { [weak self] wallet, _ in
                let allowanceData = try Calldata.allowance(
                    owner: wallet.address, spender: addresses.exchange)
                let allowance = ABIMoney.decode(try await rpc.callContract(
                    to: addresses.collateralToken, data: allowanceData))
                if allowance < amount {
                    let approval = try await sender.send(
                        to: addresses.collateralToken,
                        data: try Calldata.approve(spender: addresses.exchange, amount: amount),
                        from: wallet)
                    _ = try await sender.wait(for: approval)
                }
                await MainActor.run { self?.deposit = .depositing }
                let transaction = try await sender.send(
                    to: addresses.exchange,
                    data: try Calldata.depositCollateral(amount: amount),
                    from: wallet)
                _ = try await sender.wait(for: transaction)
                return transaction.hashHex
            }
            deposit = .sent(hash)
            let prior = collateral.value ?? .zero
            collateral.record(prior + amount)
            try? await Task.sleep(for: .milliseconds(900))
            await refreshBalances()
            await trading.reconnect()
        } catch let failure as PasskeyFailure {
            deposit = .failed(failure.sentence)
        } catch {
            deposit = .failed("AUSD could not be moved to your trading balance. Nothing was lost.")
        }
    }

    func clearDeposit() { deposit = .idle }

    enum Withdrawal: Equatable {
        case idle
        case sending
        case sent(String)
        case failed(String)

        var isBusy: Bool { self == .sending }
    }

    /// Moves collateral back out of the exchange to the derived address.
    ///
    /// Signed by the wallet key and never by the API key — the trading key exists so that
    /// a trading session cannot move money, and a withdrawal that the session could sign
    /// would delete that distinction. So this is a fresh Face ID prompt, which is exactly
    /// where one is earned.
    func withdraw(_ amount: Money) async {
        guard !withdrawal.isBusy else { return }
        withdrawal = .sending
        do {
            let rest = PerplREST(configuration: try .testnet())
            let context = try await rest.context()
            let addresses = try ExchangeAddresses(context: context)
            guard let minimum = context.instances.first?.minWithdraw, amount >= minimum else {
                withdrawal = .failed(
                    "Perpl's smallest withdrawal is "
                        + "\(context.instances.first?.minWithdraw?.display() ?? "—") AUSD.")
                return
            }

            let rpc = MonadRPC(configuration: try .testnet())
            let sender = TransactionSender(rpc: rpc)
            let hash = try await passkey.withKeys { wallet, _ in
                let signed = try await sender.send(
                    to: addresses.exchange,
                    data: try Calldata.withdrawCollateral(amount: amount),
                    from: wallet)
                // Waited for rather than assumed: a send returns a hash, and a hash is
                // not a receipt. Reporting success on the hash would tell the user their
                // money had moved while the transaction could still revert.
                _ = try await sender.wait(for: signed)
                return signed.hashHex
            }
            withdrawal = .sent(hash)
            await refreshBalances()
            await trading.reconnect()
        } catch {
            withdrawal = .failed(Self.withdrawSentence(for: error))
        }
    }

    func clearWithdrawal() { withdrawal = .idle }

    static func withdrawSentence(for error: any Error) -> String {
        switch error {
        case let failure as PasskeyFailure:
            return failure.sentence
        default:
            return "The withdrawal could not be sent. Your collateral has not moved."
        }
    }

    func endSession() async {
        await trading.close()
        await session.end()
        sessionRemaining = .zero
        stage = .welcome
        address = nil
        ticker?.cancel()
        ticker = nil
        balancePoller?.cancel()
        balancePoller = nil
    }

    func enterBackground() async {
        await session.enterBackground()
        sessionRemaining = .zero
    }

    // MARK: - Balances

    /// Polls the chain for what this address holds.
    ///
    /// Deliberately not tied to a screen. Home, Fund and Account all read these figures,
    /// and a poller owned by a view restarts on every navigation — which is both wasteful
    /// and visible, because the balance flickers back to unavailable each time.
    ///
    /// Backoff comes from `LastGood.retryDelay()`, so a node that is down is retried
    /// slower rather than hammered, and a recovered node is picked up on the next tick.
    private func startPollingBalances() {
        balancePoller?.cancel()
        balancePoller = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await refreshBalances()
                let delay = walletAUSD.retryDelay()
                try? await Task.sleep(for: delay == .zero ? .seconds(12) : delay)
            }
        }
    }

    func refreshBalances() async {
        guard let address else { return }
        do {
            let reader = try await balanceReader()
            let snapshot = await reader.read(for: address)
            // Each field lands on its own. A failed AUSD read must not disturb a good MON
            // one, which is the whole reason the snapshot carries three outcomes rather
            // than throwing once.
            record(snapshot.walletAUSD, into: &walletAUSD)
            record(snapshot.gas, into: &walletMON)
            record(snapshot.hasDesk, into: &hasDesk)
        } catch {
            let reason = "Could not reach the exchange to find out which contracts to read."
            walletAUSD.recordFailure(reason)
            walletMON.recordFailure(reason)
            hasDesk.recordFailure(reason)
        }
    }

    private func record<Value>(_ read: BalanceReader.Read<Value>, into slot: inout LastGood<Value>) {
        switch read {
        case .ok(let value): slot.record(value)
        case .failed(let reason): slot.recordFailure(reason)
        }
    }

    /// The venue says which contracts back it, so the addresses are fetched rather than
    /// compiled in. Built once and kept: the answer does not change within a session, and
    /// a context call before every balance poll would triple the traffic.
    private func balanceReader() async throws -> BalanceReader {
        if let balances { return balances }
        let rest = PerplREST(configuration: try .testnet())
        let reader = BalanceReader(
            rpc: MonadRPC(configuration: try .testnet()),
            addresses: try ExchangeAddresses(context: await rest.context()))
        balances = reader
        return reader
    }

    private func startTicking() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                sessionRemaining = await session.remaining ?? .zero
                if sessionRemaining == .zero, await session.isOpen == false, stage != .welcome {
                    stage = .welcome
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

extension Duration {
    /// `9m 12s`, the shape the Account screen's countdown wants.
    var clockText: String {
        let total = Int(components.seconds)
        return "\(total / 60)m \(String(format: "%02d", total % 60))s"
    }
}
