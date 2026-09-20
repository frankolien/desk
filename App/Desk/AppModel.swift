import DeskAuth
import DeskChain
import DeskFlow
import DeskMoney
import DeskPerpl
import Foundation
import Observation
import WidgetKit
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
    /// Positions the venue has already closed, newest first. They arrive on the same
    /// `mt: 26`/`mt: 27` stream and carry the exit price and the realised PnL.
    private(set) var closedPositions: [PerplPosition] = []

    /// Whether the trading key is in memory right now.
    ///
    /// There is no countdown. The key stays while Desk is open, is wiped twenty seconds
    /// after Desk leaves the foreground or the moment the phone locks, and comes back with
    /// one Face ID prompt. Locked is not signed out: the address, balances and positions
    /// stay on screen, because none of them needs the key to be read.
    private(set) var isKeyUnlocked = false
    /// Why the last unlock did not finish, if it did not.
    private(set) var unlockProblem: String?
    private var isUnlocking = false
    /// Why the last attempt to open a desk stopped, if it did.
    private(set) var openingProblem: String?
    /// A setup failure that happened before the exchange-opening sequence.
    private(set) var fundingProblem: String?
    /// Set when Desk's faucet cannot help, so setup offers Monad's own instead.
    private(set) var needsManualFaucet = false
    /// What the faucet is waiting on, while it waits.
    private(set) var fundingStatus: String?
    private let faucet = DeskFaucet()
    /// Which of the four steps is running, for the Fund screen to render.
    private(set) var openingStep: OpeningSequence.Progress?
    /// Handed the enrolled key the moment one exists.
    let trading = TradingSession()
    /// Whether this network's Perpl account is open and its key is in the session.
    /// Separate from `stage`: an account missing on one network is a card on Home, not a
    /// trip back through onboarding.
    private(set) var hasTradingAccount = false
    /// Which derived trading key the signing session holds. Each network's Perpl token
    /// belongs to one index, so a switch to a network whose token uses another index has to
    /// drop the key and derive the right one at the next Face ID prompt.
    private var sessionTradingIndex: UInt32?

    /// True once a desk has been opened on any network. After that, onboarding never
    /// returns; a network without an account is set up from inside the app.
    private func hasOnboarded(_ address: EthereumAddress) -> Bool {
        DeskNetwork.allCases.contains { APIKeyStore.forNetwork($0).load(for: address) != nil }
    }
    /// Shown once, ever, the first time leverage is reached.
    var hasSeenLeverageExplainer = false
    private let session = SigningSession()
    private let passkey: any PasskeyService
    private var apiKeys: APIKeyStore { APIKeyStore.forNetwork(network) }
    /// Testnet until the person chooses otherwise. Remembered, because waking up on a
    /// different network than the one left is exactly the confusion the switch exists to
    /// prevent.
    private(set) var network: DeskNetwork = DeskNetwork(
        rawValue: UserDefaults.standard.string(forKey: "desk.network") ?? "") ?? .testnet
    private var balancePoller: Task<Void, Never>?
    /// Built once, on the first refresh: it needs the venue's context to learn which
    /// contracts to read, and that is one network call rather than a constant.
    private var balances: BalanceReader?
    /// MON on Monad mainnet: real funds, spent only on spot purchases.
    private(set) var mainnetMON = LastGood<NativeAmount>()
    /// One sender for mainnet, so its nonces stay in order across purchases.
    private var mainnetSender: TransactionSender?

    init(passkey: any PasskeyService) {
        self.passkey = passkey
        trading.network = network
        trading.onAccount = { [weak self] account in
            guard let free = account.free else { return }
            self?.collateral.record(free)
        }
        trading.onPositions = { [weak self] positions in
            let open = positions.filter(\.isOpen)
            self?.openPositions = open
            self?.openPosition = open.first
            // By the venue's own monotonic position id, so the order never reshuffles.
            self?.closedPositions = positions
                .filter { !$0.isOpen }
                .sorted { $0.positionID > $1.positionID }
        }
        // An order that finds Desk locked asks for Face ID once and carries on. Only a
        // locked key qualifies: a connection that failed for any other reason is reported
        // as itself, not answered with a prompt that would not fix it.
        trading.onNeedsUnlock = { [weak self] in
            guard let self, await session.isOpen == false else { return false }
            return await unlock()
        }
        #if DEBUG
        // `-stage fund|market` jumps straight to a screen, so each one can be captured
        // and reviewed without walking the flow. Debug only, and never a way into a
        // signed-in state on a real build.
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-stage"),
           index + 1 < ProcessInfo.processInfo.arguments.count {
            let name = ProcessInfo.processInfo.arguments[index + 1]
            stage = switch name {
            case "market", "signals", "signal-detail", "empty", "watchlist", "search", "home", "home-setup": .trading
            case "fund", "fund-empty": .needsDesk
            default: .welcome
            }
            // `empty` is the state a real first run is actually in: signed in, funded by
            // nothing. It is the screen most likely to be wrong and the least likely to
            // be looked at, so it gets its own way in.
            if name == "empty" || name == "fund-empty" {
                // Its own seed: the shared review wallet holds real testnet funds.
                let seed: UInt8 = name == "fund-empty" ? 0x2B : 0x2A
                address = try? PasskeyAccounts.deriveAddress(prfOutput: Data(repeating: seed, count: 32))
                walletAUSD.record(.zero)
                walletMON.record(.zero)
                collateral.record(.zero)
                hasDesk.record(false)
                isKeyUnlocked = true
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
                closedPositions = Self.reviewClosedPositions
                isKeyUnlocked = true
                // `home-setup` is a signed-in person on a network with no account yet.
                hasTradingAccount = name != "home-setup"
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

    /// Two positions the venue has already closed, so History can be drawn and reviewed
    /// before an account with a real trading past exists. The same `mt: 26` shape as the
    /// open one, with the exit price and realised PnL a closed position carries: a short
    /// that made 325 AUSD and a long that lost 67.50.
    static let reviewClosedPositions: [PerplPosition] = {
        let body = Data(#"""
        [{"mkt":16,"acc":42,"pid":"5","sd":2,"c":"1200000000","ep":768000,"s":50000,
          "lv":1000,"efs":"0","xfs":"0","fee":"1920000","xp":761500,
          "dpnl":"325000000","fnd":"-125000","st":2},
         {"mkt":16,"acc":42,"pid":"4","sd":1,"c":"800000000","ep":772000,"s":25000,
          "lv":1200,"efs":"0","xfs":"0","fee":"965000","xp":769300,
          "dpnl":"-67500000","fnd":"40000","st":2}]
        """#.utf8)
        return (try? JSONDecoder().decode([PerplPosition].self, from: body)) ?? []
    }()
    #endif

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

    /// This device has signed in before. Nothing about the key is stored — only the
    /// address it derived last time — but that is enough to know the onboarding has
    /// been read, and that the next thing this person wants is Face ID, not a pitch.
    var isReturning: Bool { passkey.lastSeenAddress != nil }

    func signIn() async {
        await authenticate(creating: false)
    }

    /// Reached only from an explicit "create a new account" choice.
    func createAccount() async {
        await authenticate(creating: true)
    }

    enum Resumption: Equatable { case arrived, cancelled, unavailable }

    /// The returning path: the sealed trading key, opened with one Face ID, and the
    /// account it belongs to brought back. No passkey ceremony. Nothing here can create
    /// a wallet or change which one is on screen — the address is the one last seen.
    func resume() async -> Resumption {
        guard let last = passkey.lastSeenAddress else { return .unavailable }
        switch await TradingKeyVault.open(address: last, network: network.rawValue, reason: "Unlock Desk") {
        case .opened(let key):
            isWorking = true
            defer { isWorking = false }
            address = last
            await session.open(key)
            sessionTradingIndex = apiKeys.tradingIndex(for: last)
            isKeyUnlocked = true
            do {
                try await arrive(at: last)
            } catch {
                // The venue did not answer. The account is still this person's; the
                // trading screens report the connection themselves.
                stage = hasOnboarded(last) ? .trading : .needsDesk
            }
            return .arrived
        case .cancelled:
            return .cancelled
        case .missing, .unavailable:
            return .unavailable
        }
    }

    /// With the key open, brings the account up and picks the screen.
    ///
    /// `hasDesk` is an on-chain fact. Passkey derivation deliberately cannot answer it, so
    /// checking a derived flag here always sent returning users back to setup. The account
    /// is read before the destination is chosen, and the authenticated socket is rebuilt
    /// before the first order can be opened — a returning user who jumped straight to the
    /// trading UI once found a ticket that could only answer "not connected".
    private func arrive(at address: EthereumAddress) async throws {
        await refreshBalances()
        startPollingBalances()
        if hasDesk.value == true, let stored = apiKeys.load(for: address) {
            let context = try await PerplREST(configuration: network.perpl()).context()
            await enterTrading(stored, context: context)
        } else {
            stage = hasOnboarded(address) ? .trading : .needsDesk
        }
    }

    private func authenticate(creating: Bool) async {
        isWorking = true
        signInProblem = nil
        defer { isWorking = false }
        do {
            let store = apiKeys
            // Read before deriving. `derive` records the address it just derived, so asking
            // afterwards compares a value against itself and the guard can never fire — which
            // is exactly the case it exists for.
            let lastSeen = passkey.lastSeenAddress
            let keys = creating
                ? try await passkey.createAccounts(tradingIndex: { store.tradingIndex(for: $0) })
                : try await passkey.deriveAccounts(tradingIndex: { store.tradingIndex(for: $0) })
            // The address guard runs before any balance is shown: Apple's synced-passkey
            // bug derives a different address on a second device, and rendering that
            // account's zero would read as theft.
            let verdict = AddressGuard.check(derived: keys.address, against: lastSeen)
            guard verdict.mayShowBalance else {
                signInProblem = "This passkey derived a different address than last time. "
                    + "Your funds are safe — do not continue until this is sorted."
                return
            }
            address = keys.address
            await session.open(keys.trading)
            sessionTradingIndex = store.tradingIndex(for: keys.address)
            isKeyUnlocked = true
            TradingKeyVault.seal(keys.trading, address: keys.address, network: network.rawValue)
            try await arrive(at: keys.address)
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
            let rest = PerplREST(configuration: try network.perpl())
            let context = try await rest.context()
            let addresses = try ExchangeAddresses(context: context, pinnedTo: network)
            if let address, let stored = apiKeys.load(for: address) {
                await enterTrading(stored, context: context)
                return
            }
            let rpc = MonadRPC(configuration: try network.rpc())
            let sequence = OpeningSequence(
                rpc: rpc,
                sender: TransactionSender(rpc: rpc),
                enrolment: Enrolment(rest: rest, chainID: context.chain.chainID),
                addresses: addresses)

            let session = session
            let enrolled = try await passkey.withKeys { [weak self] wallet, tradingKeys in
                // A token lost to a reinstall or a wiped keychain can never be reissued for
                // the same key, so enrolment moves on to the next derived key inside this
                // one prompt. The on-chain steps before it check themselves first.
                let opened = try await sequence.open(
                    wallet: wallet,
                    tradingKeys: { try tradingKeys.key(at: $0) },
                    indices: TradingKeyIndex.initial..<(TradingKeyIndex.initial + TradingKeyIndex.attempts),
                    deposit: deposit,
                    label: "Desk on iPhone",
                    report: { progress in
                        Task { @MainActor in self?.openingStep = progress }
                    })
                await session.open(try tradingKeys.key(at: opened.index))
                return APIKeyStore.Stored(apiKey: opened.apiKey, tradingIndex: opened.index)
            }
            if let address { try apiKeys.save(enrolled.apiKey, tradingIndex: enrolled.tradingIndex, for: address) }
            sessionTradingIndex = enrolled.tradingIndex
            isKeyUnlocked = true

            // The key exists only now. Handing it to the session is what turns the
            // ticket's confirm button from a sentence into an order.
            await enterTrading(enrolled, context: context)
        } catch {
            openingProblem = Self.openingSentence(for: error)
            openingStep = nil
        }
    }

    private func enterTrading(_ stored: APIKeyStore.Stored, context: PerplContext) async {
        guard let market = context.market(id: network.defaultMarketID) ?? context.markets.first else { return }
        if sessionTradingIndex != stored.tradingIndex {
            // The key in the session is not the one this token was issued for. Signing
            // with it would be refused, so it goes, and connecting asks for Face ID once.
            await session.end()
            sessionTradingIndex = nil
            isKeyUnlocked = false
        }
        trading.adopt(apiKey: stored.apiKey, session: session, market: market)
        hasTradingAccount = true
        if let head = context.chain.gas?.headBlock { trading.noteHeadBlock(head) }
        // The account and API key already exist at this point. A live-stream outage is
        // a connectivity state, not a reason to send the user back through onboarding.
        stage = .trading
        await refreshBalances()
        try? await trading.connect()
    }

    /// Moves the whole app to another network: balances, account, positions, sockets and
    /// the enrolled key all belong to one exchange, so none of them is carried across.
    /// The address is the same on both, so no new passkey is involved.
    func switchNetwork(to next: DeskNetwork) async {
        guard next != network, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        balancePoller?.cancel()
        await trading.abandon()
        hasTradingAccount = false
        network = next
        trading.network = next
        UserDefaults.standard.set(next.rawValue, forKey: "desk.network")
        balances = nil
        collateral = LastGood()
        walletAUSD = LastGood()
        walletMON = LastGood()
        hasDesk = LastGood()
        openPosition = nil
        openPositions = []
        closedPositions = []
        fundingProblem = nil
        openingProblem = nil
        needsManualFaucet = false
        guard let address else { return }
        await refreshBalances()
        startPollingBalances()
        if hasDesk.value == true, let stored = apiKeys.load(for: address),
           let context = try? await PerplREST(configuration: network.perpl()).context() {
            await enterTrading(stored, context: context)
        }
        // A switch never moves the screen. Without an account on this network, Home and
        // Perps offer to open one where the person already is.
    }

    /// Asks Desk's faucet for whatever this wallet lacks: MON for gas and test AUSD to
    /// trade. Neither needs the wallet to hold anything first, and neither needs Face ID.
    func fundWallet() async {
        guard let address, !isWorking, network.hasFaucet else { return }
        isWorking = true
        fundingProblem = nil
        defer { fundingStatus = nil }
        do {
            var outcome = try await faucet.fund(address)
            // Agora allows one claim a minute across every caller, so a busy faucet is
            // waited out here rather than handed back as a second tap.
            for _ in 0..<5 where outcome.ausd.reason == "cooldown" {
                if outcome.mon.arrived { await refreshUntilChanged() }
                fundingStatus = "Agora's faucet is busy. Your AUSD is next in line…"
                try await Task.sleep(for: .seconds(15))
                outcome = try await faucet.fund(address)
            }
            fundingStatus = nil
            fundingProblem = DeskFaucet.problem(in: outcome)
            needsManualFaucet = outcome.mon.status == "unavailable"
            if outcome.mon.arrived || outcome.ausd.arrived {
                await refreshUntilChanged()
            } else {
                await refreshBalances()
            }
            isWorking = false
        } catch DeskFaucet.Failure.tooSoon {
            fundingProblem = "This wallet was just funded. Give it a minute."
            await refreshBalances()
            isWorking = false
        } catch is CancellationError {
            isWorking = false
        } catch {
            needsManualFaucet = true
            isWorking = false
            let lacksAUSD = (walletAUSD.value ?? .zero) < (Money(text: "100") ?? .zero)
            if hasSetupGas && lacksAUSD {
                await claimTestAUSD()
            } else {
                fundingProblem = "Desk's faucet is unreachable. Use Monad's faucet for MON."
            }
        }
    }

    func refreshMainnetMON() async {
        guard let address else { return }
        do {
            let rpc = MonadRPC(configuration: try .mainnet())
            mainnetMON.record(NativeAmount(bigEndian: try await rpc.balance(of: address)))
        } catch {
            mainnetMON.recordFailure("Monad mainnet could not be reached.")
        }
    }

    /// Signs and sends a checked Relay deposit on Monad mainnet with one Face ID prompt,
    /// and returns once the deposit is mined. Filling it on the other chain is Relay's
    /// part, tracked by the caller.
    func buy(_ deposit: RelayDeposit) async throws {
        let sender: TransactionSender
        if let mainnetSender {
            sender = mainnetSender
        } else {
            sender = TransactionSender(rpc: MonadRPC(configuration: try .mainnet()))
            mainnetSender = sender
        }
        let signed = try await passkey.withKeys { wallet, _ in
            try await sender.send(
                to: deposit.to, data: deposit.data, value: deposit.value.bigEndianBytes, from: wallet)
        }
        _ = try await sender.wait(for: signed)
        await refreshMainnetMON()
    }

    /// A mined receipt can reach the faucet before the balance view does.
    private func refreshUntilChanged() async {
        let before = (walletMON.value?.raw, walletAUSD.value)
        for _ in 0..<6 {
            await refreshBalances()
            if walletMON.value?.raw != before.0 || walletAUSD.value != before.1 { return }
            try? await Task.sleep(for: .milliseconds(700))
        }
    }

    /// Claims the real test collateral from Agora's Monad-testnet faucet.
    /// The wallet signs the faucet call because the caller pays its gas; the faucet pays
    /// the derived address supplied in calldata.
    func claimTestAUSD() async {
        guard let address, network.hasFaucet else { return }
        guard hasSetupGas else {
            fundingProblem = "Add at least 0.05 MON before claiming test AUSD. It pays for setup gas."
            return
        }
        isWorking = true
        fundingProblem = nil
        defer { isWorking = false }
        do {
            let faucet = try Self.ethereumAddress("d236c18d274e54faccc3dd9dda4b27965a73ee6c")
            let rpc = MonadRPC(configuration: try network.rpc())
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
            let rest = PerplREST(configuration: try network.perpl())
            let context = try await rest.context()
            let addresses = try ExchangeAddresses(context: context, pinnedTo: network)
            guard let minimum = context.instances.first?.minDeposit, amount >= minimum else {
                deposit = .failed("Perpl's minimum deposit is \(context.instances.first?.minDeposit?.display() ?? "—") AUSD.")
                return
            }
            let rpc = MonadRPC(configuration: try network.rpc())
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

    enum WithdrawalSource: Equatable, Sendable {
        /// Collateral held at the exchange.
        case trading
        /// AUSD already sitting in the wallet.
        case wallet
    }

    struct WithdrawalReceipt: Equatable, Sendable {
        let amount: Money
        /// Nil when the funds stopped in this wallet.
        let recipient: EthereumAddress?
        let transactions: [String]
    }

    enum Withdrawal: Equatable {
        case idle
        case confirming
        case withdrawing
        case sending
        case sent(WithdrawalReceipt)
        case failed(String)

        var isBusy: Bool { self == .confirming || self == .withdrawing || self == .sending }
    }

    /// Moves AUSD out: from the exchange to this wallet, from the exchange on to another
    /// address, or from the wallet to another address.
    ///
    /// Signed by the wallet key and never by the API key — the trading key exists so that
    /// a trading session cannot move money, and a withdrawal that the session could sign
    /// would delete that distinction. So this is a fresh Face ID prompt, and both
    /// transactions of a withdrawal to another address sit inside that one prompt.
    func withdraw(_ amount: Money, from source: WithdrawalSource, to recipient: EthereumAddress?) async {
        guard !withdrawal.isBusy else { return }
        let destination = recipient == address ? nil : recipient
        guard source == .trading || destination != nil else { return }
        withdrawal = .confirming
        do {
            let rest = PerplREST(configuration: try network.perpl())
            let context = try await rest.context()
            let addresses = try ExchangeAddresses(context: context, pinnedTo: network)
            if source == .trading,
               let minimum = context.instances.first?.minWithdraw, amount < minimum {
                withdrawal = .failed("Perpl's smallest withdrawal is \(minimum.display()) AUSD.")
                return
            }

            let rpc = MonadRPC(configuration: try network.rpc())
            let sender = TransactionSender(rpc: rpc)
            let hashes = try await passkey.withKeys { [weak self] wallet, _ in
                var hashes: [String] = []
                if source == .trading {
                    await MainActor.run { self?.withdrawal = .withdrawing }
                    let signed = try await sender.send(
                        to: addresses.exchange,
                        data: try Calldata.withdrawCollateral(amount: amount),
                        from: wallet)
                    // Waited for rather than assumed: a hash is not a receipt, and the
                    // transfer below would spend AUSD the wallet does not hold yet.
                    _ = try await sender.wait(for: signed)
                    hashes.append(signed.hashHex)
                }
                if let destination {
                    await MainActor.run { self?.withdrawal = .sending }
                    let signed = try await sender.send(
                        to: addresses.collateralToken,
                        data: try Calldata.transfer(to: destination, amount: amount),
                        from: wallet)
                    _ = try await sender.wait(for: signed)
                    hashes.append(signed.hashHex)
                }
                return hashes
            }
            withdrawal = .sent(WithdrawalReceipt(amount: amount, recipient: destination, transactions: hashes))
            await refreshBalances()
            if source == .trading { await trading.reconnect() }
        } catch {
            withdrawal = .failed(Self.withdrawSentence(for: error, stage: withdrawal))
        }
    }

    /// Which half failed matters: after the exchange step the AUSD is safe in this wallet,
    /// and saying "nothing moved" then would be wrong.
    static func withdrawSentence(for error: any Error, stage: Withdrawal = .confirming) -> String {
        if let failure = error as? PasskeyFailure { return failure.sentence }
        switch stage {
        case .sending:
            return "The AUSD reached your wallet but could not be sent on. It is still in your wallet."
        default:
            return "The withdrawal could not be sent. Your collateral has not moved."
        }
    }

    func clearWithdrawal() { withdrawal = .idle }

    /// Signs out: the key, the connection and the account on screen all go.
    func endSession() async {
        if let address { TradingKeyVault.forget(address: address, network: network.rawValue) }
        await trading.close()
        await session.end()
        isKeyUnlocked = false
        unlockProblem = nil
        stage = .welcome
        address = nil
        balancePoller?.cancel()
        balancePoller = nil
        // Everything the last account put on screen goes with it. Leaving the balances and
        // the positions behind meant the next person to sign in read someone else's book as
        // their own until a socket snapshot replaced it — which needs their Face ID first.
        balances = nil
        collateral = LastGood()
        walletAUSD = LastGood()
        walletMON = LastGood()
        hasDesk = LastGood()
        openPosition = nil
        openPositions = []
        closedPositions = []
        hasTradingAccount = false
        sessionTradingIndex = nil
        fundingProblem = nil
        openingProblem = nil
        needsManualFaucet = false
        // And everything Desk told other people about them: the server's copy of the
        // subscription, the follow list, the nicknames, and the glance the widget draws.
        await TradeAlerts.shared.signOut()
        UserDefaults.standard.removeObject(forKey: "desk.followedTraders")
        AutoCopyGlance.forget()
        PortfolioGlance.forget()
        WidgetCenter.shared.reloadTimelines(ofKind: AutoCopyControl.widgetKind)
        WidgetCenter.shared.reloadTimelines(ofKind: PortfolioGlance.widgetKind)
    }

    // MARK: - The trading key

    /// Desk left the foreground. The key survives a short trip to another app; the scene
    /// holds a background task open for the grace and calls `expireIfAway` at the end of
    /// it, so the wipe runs while Desk can still execute.
    func enterBackground() async {
        await session.enterBackground()
    }

    /// The end of the background grace.
    func expireIfAway() async {
        await session.expireIfOverdue()
        if await session.isOpen == false, address != nil { await lock() }
    }

    /// Back in the foreground.
    ///
    /// If the key did not survive the absence, Face ID is asked for once, now — before the
    /// person reaches for an order — rather than at the moment they try to send one. Only
    /// on the trading screens: setup signs every transaction with a fresh ceremony anyway,
    /// so an unlock there would be a prompt for nothing.
    func enterForeground() async {
        await session.enterForeground()
        if await session.isOpen == false, isKeyUnlocked { await lock() }
        guard !isKeyUnlocked, address != nil, stage == .trading else { return }
        await unlock()
    }

    /// Wipes the key without signing out. The phone locking, iOS ending Desk's background
    /// time early, and the person choosing to lock all come here.
    func lock() async {
        await session.end()
        isKeyUnlocked = false
        // An authenticated socket keeps accepting orders with no key behind it, so a lock
        // that left it open would not be a lock. Closed, the next order has to sign in
        // again — and signing in is what asks for Face ID.
        await trading.close()
    }

    /// Brings the trading key back with one Face ID prompt, without signing out.
    ///
    /// Assertion only, so it can never create a passkey. And the derived address must be
    /// the one already on screen: a different address is a different wallet, and adopting
    /// it quietly would swap the account out from under the balances being looked at.
    @discardableResult
    func unlock() async -> Bool {
        if await session.isOpen {
            isKeyUnlocked = true
            return true
        }
        guard let address, !isUnlocking else { return false }
        isUnlocking = true
        unlockProblem = nil
        defer { isUnlocking = false }
        let store = apiKeys
        switch await TradingKeyVault.open(address: address, network: network.rawValue, reason: "Unlock Desk") {
        case .opened(let key):
            await session.open(key)
            sessionTradingIndex = store.tradingIndex(for: address)
            isKeyUnlocked = true
            await trading.reconnect()
            return true
        case .cancelled:
            return false
        case .missing, .unavailable:
            break
        }
        do {
            let keys = try await passkey.deriveAccounts(tradingIndex: { store.tradingIndex(for: $0) })
            guard keys.address == address else {
                unlockProblem = "That passkey belongs to a different wallet, so Desk stayed "
                    + "locked. Sign out to switch accounts."
                return false
            }
            await session.open(keys.trading)
            sessionTradingIndex = store.tradingIndex(for: address)
            isKeyUnlocked = true
            TradingKeyVault.seal(keys.trading, address: address, network: network.rawValue)
            await trading.reconnect()
            return true
        } catch PasskeyFailure.cancelledByUser {
            return false
        } catch let failure as PasskeyFailure {
            unlockProblem = failure.sentence
            return false
        } catch {
            unlockProblem = "Face ID could not unlock Desk. Try again."
            return false
        }
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
        let rest = PerplREST(configuration: try network.perpl())
        let reader = BalanceReader(
            rpc: MonadRPC(configuration: try network.rpc()),
            addresses: try ExchangeAddresses(context: await rest.context(), pinnedTo: network))
        balances = reader
        return reader
    }
}
