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

    private(set) var sessionRemaining: Duration = .zero
    /// Why the last attempt to open a desk stopped, if it did.
    private(set) var openingProblem: String?
    /// Which of the four steps is running, for the Fund screen to render.
    private(set) var openingStep: OpeningSequence.Progress?
    /// Handed the enrolled key the moment one exists.
    let trading = TradingSession()
    /// Shown once, ever, the first time leverage is reached.
    var hasSeenLeverageExplainer = false
    private let session = SigningSession()
    private let passkey: any PasskeyService
    private var ticker: Task<Void, Never>?
    private var balancePoller: Task<Void, Never>?
    /// Built once, on the first refresh: it needs the venue's context to learn which
    /// contracts to read, and that is one network call rather than a constant.
    private var balances: BalanceReader?

    init(passkey: any PasskeyService) {
        self.passkey = passkey
        #if DEBUG
        // `-stage fund|market` jumps straight to a screen, so each one can be captured
        // and reviewed without walking the flow. Debug only, and never a way into a
        // signed-in state on a real build.
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-stage"),
           index + 1 < ProcessInfo.processInfo.arguments.count {
            let name = ProcessInfo.processInfo.arguments[index + 1]
            stage = switch name {
            case "market", "signals", "signal-detail", "empty": .trading
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

    func advance(to stage: Stage) { self.stage = stage }

    /// The checksummed address, not the shortened one — a truncated address pasted into a
    /// block explorer is a support ticket.
    func copyAddress() {
        guard let address else { return }
        UIPasteboard.general.string = address.checksummed
    }

    func signIn() async {
        isWorking = true
        signInProblem = nil
        defer { isWorking = false }
        do {
            let keys = try await passkey.deriveAccounts()
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
            stage = keys.hasDesk ? .trading : .needsDesk
            startPollingBalances()
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
    func openDesk(depositing deposit: Money) async {
        isWorking = true
        openingProblem = nil
        defer { isWorking = false }
        do {
            let rest = PerplREST(configuration: try .testnet())
            let context = try await rest.context()
            let addresses = try ExchangeAddresses(context: context)
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

            // The key exists only now. Handing it to the session is what turns the
            // ticket's confirm button from a sentence into an order.
            if let market = context.market(id: 16) {
                trading.adopt(apiKey: apiKey, session: session, market: market)
                if let head = context.chain.gas?.headBlock { trading.noteHeadBlock(head) }
                try await trading.connect(lastForwarded: 0)
            }
            stage = .trading
            await refreshBalances()
        } catch {
            openingProblem = Self.openingSentence(for: error)
        }
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
        default:
            return "Your desk could not be opened. Nothing was deposited that you cannot "
                + "recover — try again, and the steps already done will be skipped."
        }
    }

    // MARK: - Withdrawing

    private(set) var withdrawal: Withdrawal = .idle

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
