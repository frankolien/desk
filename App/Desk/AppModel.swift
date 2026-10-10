import DeskAuth
import LocalAuthentication
import DeskChain
import DeskFlow
import DeskMoney
import DeskPerpl
import Foundation
import Observation
import Security
import WidgetKit
import UIKit

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
    private(set) var isSwitchingNetwork = false

    /// From the authenticated socket, not the chain: it stays unavailable (`--`, not `0.00`)
    /// until a session exists, because a zero would tell a funded user their collateral is gone.
    private(set) var collateral = LastGood<Money>()
    private(set) var walletAUSD = LastGood<Money>()
    /// MON, for gas. Eighteen decimals, so deliberately not `Money`.
    private(set) var walletMON = LastGood<NativeAmount>()
    private(set) var hasDesk = LastGood<Bool>()
    /// Kept raw and derived at display, so every figure comes from the same mark tick.
    /// Arrives on the authenticated socket as `mt: 26` then `mt: 27`; nil until a session exists.
    private(set) var openPosition: PerplPosition?
    private(set) var openPositions: [PerplPosition] = []
    var closedTrades: [ClosedTrade] {
        if let stagedClosedTrades { return stagedClosedTrades }
        guard let address else { return [] }
        return ClosedPositionsStore.shared.trades(network: network.rawValue, address: address.checksummed)
    }
    private var stagedClosedTrades: [ClosedTrade]?

    /// The key is wiped when the phone locks, or on return after five minutes away.
    /// Locked is not signed out: address, balances and positions stay on screen.
    private(set) var isKeyUnlocked = false
    private(set) var unlockProblem: String?
    private var isUnlocking = false
    private(set) var openingProblem: String?
    private(set) var fundingProblem: String?
    private(set) var needsManualFaucet = false
    private(set) var fundingStatus: String?
    private let faucet = DeskFaucet()
    private(set) var openingStep: OpeningSequence.Progress?
    let trading = TradingSession()
    private(set) var hasTradingAccount = false
    /// Each network's Perpl token belongs to one derived key index, so switching to a network
    /// whose token uses another index drops the key and derives the right one at the next Face ID.
    private var sessionTradingIndex: UInt32?

    private func hasOnboarded(_ address: EthereumAddress) -> Bool {
        DeskNetwork.allCases.contains { APIKeyStore.forNetwork($0).load(for: address) != nil }
    }

    private(set) var showsNameOnboarding = false

    private static func nameOnboardingKey(_ address: EthereumAddress) -> String { "desk.onboarding.name.\(address.checksummed)" }

    private func considerNameOnboarding(_ address: EthereumAddress) {
        showsNameOnboarding = !hasOnboarded(address) && !UserDefaults.standard.bool(forKey: Self.nameOnboardingKey(address))
    }

    func finishNameOnboarding() {
        if let address { UserDefaults.standard.set(true, forKey: Self.nameOnboardingKey(address)) }
        showsNameOnboarding = false
    }
    var hasSeenLeverageExplainer = UserDefaults.standard.bool(forKey: "desk.leverageExplainerSeen") {
        didSet { UserDefaults.standard.set(hasSeenLeverageExplainer, forKey: "desk.leverageExplainerSeen") }
    }
    private let session = SigningSession()
    private let passkey: any PasskeyService
    private var apiKeys: APIKeyStore { APIKeyStore.forNetwork(network) }
    private(set) var network: DeskNetwork = NetworkChoice.saved ?? .testnet
    /// False on a fresh install until the wallet is known, so a mainnet desk reopens on mainnet.
    private var networkIsSettled = NetworkChoice.saved != nil
    private var historyRefilled: Set<String> = []
    private var balancePoller: Task<Void, Never>?
    private var balances: BalanceReader?
    private(set) var mainnetMON = LastGood<NativeAmount>()
    private var mainnetSender: TransactionSender?

    init(passkey: any PasskeyService) {
        self.passkey = passkey
        #if DEBUG
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-network"),
           index + 1 < ProcessInfo.processInfo.arguments.count,
           let chosen = DeskNetwork(rawValue: ProcessInfo.processInfo.arguments[index + 1]) {
            network = chosen
            networkIsSettled = true
        }
        #endif
        if !networkIsSettled, let last = passkey.lastSeenAddress { settleNetwork(NetworkChoice.likely(for: last)) }
        trading.network = network
        trading.onAccount = { [weak self] account in
            guard let free = account.free else { return }
            self?.collateral.record(free)
        }
        trading.onPositions = { [weak self] positions in
            let open = positions.filter(\.isOpen)
            self?.openPositions = open
            self?.openPosition = open.first
            if let self, let address {
                ClosedPositionsStore.shared.record(positions, network: network.rawValue, address: address.checksummed)
            }
        }
        // Only a locked key asks for Face ID; any other connection failure is reported as itself.
        trading.onNeedsUnlock = { [weak self] in
            guard let self, await session.isOpen == false else { return false }
            return await unlock()
        }
        #if DEBUG
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-stage"),
           index + 1 < ProcessInfo.processInfo.arguments.count {
            let name = ProcessInfo.processInfo.arguments[index + 1]
            stage = switch name {
            case "market", "signals", "signal-detail", "empty", "watchlist", "search", "home", "home-setup", "name": .trading
            case "fund", "fund-empty": .needsDesk
            default: .welcome
            }
            if name == "name" { showsNameOnboarding = true }
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
                stagedClosedTrades = Self.reviewClosedPositions.map { ClosedTrade(position: $0) }
                isKeyUnlocked = true
                hasTradingAccount = name != "home-setup"
                if network.holdsRealFunds, name == "home-setup" || name == "fund" {
                    walletMON.record(NativeAmount(decimalText: "812.4") ?? .zero)
                    walletAUSD.record(.zero)
                    collateral.record(.zero)
                    hasDesk.record(false)
                    openPosition = nil
                    openPositions = []
                    stagedClosedTrades = []
                }
            }
        }
        #endif
    }

    #if DEBUG
    static let reviewPosition: PerplPosition? = {
        let body = Data(#"""
        {"mkt":16,"acc":42,"pid":"7","sd":1,"c":"5000000000","ep":770000,"epr":21845,
         "s":100000,"lv":1500,"efs":"0","xfs":"0","fee":"3850000","st":1}
        """#.utf8)
        return try? JSONDecoder().decode(PerplPosition.self, from: body)
    }()

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

    func copyAddress() {
        guard let address else { return }
        UIPasteboard.general.string = address.checksummed
    }

    func sendNadCall(_ call: NadCall, value: NativeAmount) async throws -> String {
        let checked = try call.checked(expectingValue: value)
        let sender: TransactionSender
        if let mainnetSender {
            sender = mainnetSender
        } else {
            sender = TransactionSender(rpc: MonadRPC(configuration: try .mainnet()))
            mainnetSender = sender
        }
        let signed = try await passkey.withKeys { wallet, _ in
            try await sender.send(to: checked.to, data: checked.data, value: checked.value.bigEndianBytes, from: wallet)
        }
        _ = try await sender.wait(for: signed)
        await refreshMainnetMON()
        if let address { await IdentityDirectory.shared.refresh(address.checksummed) }
        return signed.hashHex
    }

    @discardableResult
    func saveProfile(name: String, image: Data?) async throws -> String? {
        guard let address else { return nil }
        let passkey = passkey
        let saved = try await DeskProfile.save(address: address, name: name, image: image) { digest in
            try await passkey.withKeys { wallet, _ in try WalletSigner.sign(digest: digest, with: wallet) }
        }
        await IdentityDirectory.shared.refresh(address.checksummed)
        return saved.avatar
    }

    /// True only when this device has never derived an address: iOS reports a dismissed sheet and
    /// "no credential matched" both as `.canceled`, and a second passkey strands the first wallet.
    var mayOfferCreate: Bool { passkey.lastSeenAddress == nil }

    var isReturning: Bool { passkey.lastSeenAddress != nil }

    func signIn() async {
        await authenticate(creating: false)
    }

    func createAccount() async {
        await authenticate(creating: true)
    }

    enum Resumption: Equatable { case arrived, cancelled, unavailable }

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
                considerNameOnboarding(last)
                stage = .trading
            }
            return .arrived
        case .cancelled:
            return .cancelled
        case .missing, .unavailable:
            return .unavailable
        }
    }

    private func arrive(at address: EthereumAddress) async throws {
        TradeAlerts.shared.signedIn(as: address.checksummed)
        await refreshBalances()
        startPollingBalances()
        if hasDesk.value == true, let stored = apiKeys.load(for: address) {
            let context = try await PerplREST(configuration: network.perpl()).context()
            noteMinimumToOpen(context)
            await enterTrading(stored, context: context)
        } else {
            considerNameOnboarding(address)
            stage = .trading
            Task { await refreshMinimumToOpen() }
        }
    }

    private func authenticate(creating: Bool) async {
        isWorking = true
        signInProblem = nil
        defer { isWorking = false }
        do {
            let settled = networkIsSettled
            let current = network
            let tradingIndex: @Sendable (EthereumAddress) -> UInt32 = { address in
                APIKeyStore.forNetwork(settled ? current : NetworkChoice.likely(for: address)).tradingIndex(for: address)
            }
            // Read before deriving: `derive` records the address it derived, so reading after
            // would compare it against itself and the guard could never fire.
            let lastSeen = passkey.lastSeenAddress
            let keys = creating
                ? try await passkey.createAccounts(tradingIndex: tradingIndex)
                : try await passkey.deriveAccounts(tradingIndex: tradingIndex)
            // The address guard runs before any balance is shown: a synced passkey can derive another
            // address on a second device, and showing that account's zero would read as theft.
            let verdict = AddressGuard.check(derived: keys.address, against: lastSeen)
            guard verdict.mayShowBalance else {
                signInProblem = "This passkey derived a different address than last time. "
                    + "Your funds are safe — do not continue until this is sorted."
                return
            }
            if !settled { settleNetwork(NetworkChoice.likely(for: keys.address)) }
            address = keys.address
            await session.open(keys.trading)
            sessionTradingIndex = apiKeys.tradingIndex(for: keys.address)
            isKeyUnlocked = true
            TradingKeyVault.seal(keys.trading, address: keys.address, network: network.rawValue)
            try await arrive(at: keys.address)
        } catch PasskeyFailure.cancelledByUser {
            // A dismissed sheet is not a failure; registering here would turn a mis-tap into a second wallet.
            signInProblem = nil
        } catch let failure as PasskeyFailure {
            signInProblem = failure.sentence
        } catch {
            signInProblem = "Sign in could not finish. Try again."
        }
    }

    /// One wallet key, scoped to the closure and never returned, signs all four steps under one
    /// Face ID. Resumable: each step checks whether it is already done before spending anything.
    func openDesk() async {
        isWorking = true
        openingProblem = nil
        openingStep = nil
        defer { isWorking = false }
        do {
            // Never trust the figure a view rendered: funding can arrive while this screen is open.
            await refreshBalances()
            guard let deposit = walletAUSD.value ?? (hasDesk.value == true ? .zero : nil) else {
                openingProblem = walletAUSD.lastFailure
                    ?? "Your AUSD balance is still loading. Try again in a moment."
                return
            }
            let rest = PerplREST(configuration: try network.perpl())
            let context = try await rest.context()
            noteMinimumToOpen(context)
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
            let vaultNetwork = network.rawValue
            let expected = address
            let enrolled = try await passkey.withKeys { [weak self] wallet, tradingKeys in
                // Another passkey picked at the prompt is another wallet. Opening its desk
                // here would file its key under this account.
                if let expected, wallet.address != expected { throw OpeningMismatch.differentWallet }
                // A lost token can never be reissued for the same key, so enrolment moves on to the
                // next derived key inside this one prompt.
                let opened = try await sequence.open(
                    wallet: wallet,
                    tradingKeys: { try tradingKeys.key(at: $0) },
                    indices: TradingKeyIndex.initial..<(TradingKeyIndex.initial + TradingKeyIndex.attempts),
                    deposit: deposit,
                    label: "Desk on iPhone",
                    report: { progress in
                        Task { @MainActor in self?.openingStep = progress }
                    })
                let enrolledKey = try tradingKeys.key(at: opened.index)
                // Enrolment can move past the key sign-in sealed. The vault has to hold this one,
                // or the next launch unlocks a key Perpl no longer accepts.
                TradingKeyVault.seal(enrolledKey, address: wallet.address, network: vaultNetwork)
                await session.open(enrolledKey)
                return APIKeyStore.Stored(apiKey: opened.apiKey, tradingIndex: opened.index)
            }
            if let address { try apiKeys.save(enrolled.apiKey, tradingIndex: enrolled.tradingIndex, for: address) }
            sessionTradingIndex = enrolled.tradingIndex
            isKeyUnlocked = true

            await enterTrading(enrolled, context: context)
        } catch {
            openingProblem = Self.openingSentence(for: error)
            openingStep = nil
        }
    }

    private func enterTrading(_ stored: APIKeyStore.Stored, context: PerplContext) async {
        guard let market = context.market(id: network.defaultMarketID) ?? context.markets.first else { return }
        if sessionTradingIndex != stored.tradingIndex {
            await session.end()
            sessionTradingIndex = nil
            isKeyUnlocked = false
        }
        await trading.adopt(apiKey: stored.apiKey, session: session, market: market)
        hasTradingAccount = true
        if let head = context.chain.gas?.headBlock { trading.noteHeadBlock(head) }
        stage = .trading
        await refreshBalances()
        try? await trading.connect()
        Task { await refillClosedTrades() }
    }

    private func settleNetwork(_ chosen: DeskNetwork) {
        networkIsSettled = true
        guard chosen != network else { return }
        network = chosen
        trading.network = chosen
    }

    /// The phone's list of closed positions goes with the app; Perpl keeps the real one.
    private func refillClosedTrades() async {
        guard let address else { return }
        let network = network
        let key = "\(network.rawValue):\(address.checksummed)"
        guard !historyRefilled.contains(key) else { return }
        let closed = await trading.closedHistory()
        guard !closed.isEmpty, self.network == network, self.address == address else { return }
        historyRefilled.insert(key)
        ClosedPositionsStore.shared.record(closed, network: network.rawValue, address: address.checksummed)
    }

    @discardableResult
    func switchNetwork(to next: DeskNetwork) async -> Bool {
        guard next != network, !isWorking else { return false }
        isWorking = true
        isSwitchingNetwork = true
        defer { isWorking = false; isSwitchingNetwork = false }
        balancePoller?.cancel()
        await trading.abandon()
        hasTradingAccount = false
        network = next
        networkIsSettled = true
        trading.network = next
        NetworkChoice.save(next)
        balances = nil
        collateral = LastGood()
        walletAUSD = LastGood()
        walletMON = LastGood()
        hasDesk = LastGood()
        openPosition = nil
        openPositions = []
        fundingProblem = nil
        openingProblem = nil
        needsManualFaucet = false
        guard let address else { return true }
        await refreshBalances()
        startPollingBalances()
        if hasDesk.value == true, let stored = apiKeys.load(for: address),
           let context = try? await PerplREST(configuration: network.perpl()).context() {
            await enterTrading(stored, context: context)
        }
        return true
    }

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

    static let gasReserve = NativeAmount(decimalText: "0.5") ?? .zero

    /// Perpl's `min_account_open_amount`: 100 AUSD on testnet, 10 on mainnet.
    var minimumToOpenDesk: Money {
        liveMinimumToOpen[network] ?? Money(text: network.hasFaucet ? "100" : "10") ?? .zero
    }

    /// Perpl's `min_account_open_amount` per network, once its context has been read; the
    /// values its docs publish stand in until then. Perpl asks integrators not to hardcode it.
    private var liveMinimumToOpen: [DeskNetwork: Money] = [:]

    private func noteMinimumToOpen(_ context: PerplContext) {
        if let minimum = context.instances.first?.minAccountOpen { liveMinimumToOpen[network] = minimum }
    }

    private func refreshMinimumToOpen() async {
        guard let context = try? await PerplREST(configuration: network.perpl()).context() else { return }
        noteMinimumToOpen(context)
    }

    var ausdShortfall: Money? {
        guard hasDesk.value != true else { return nil }
        let held = walletAUSD.value ?? .zero
        guard held < minimumToOpenDesk, let short = Money(raw: minimumToOpenDesk.raw - held.raw) else { return nil }
        return short
    }

    var swappableMON: NativeAmount? {
        guard network.holdsRealFunds, let held = walletMON.value, held.raw > Self.gasReserve.raw,
              let spare = NativeAmount(raw: held.raw - Self.gasReserve.raw), spare.raw >= 1_000_000_000_000_000_000
        else { return nil }
        return spare
    }

    enum SwapStep: Equatable, Sendable { case checking, signing, approving, sending }

    struct SwapReceipt: Equatable, Sendable {
        let hash: String
        let received: Money
    }

    struct MONSwapReceipt: Equatable, Sendable {
        let hash: String
        let received: NativeAmount
    }

    /// AUSD in the wallet that can go back to MON, for gas and tokens; a dollar or more.
    var swappableAUSD: Money? {
        guard network.holdsRealFunds, let held = walletAUSD.value, held.raw >= 1_000_000 else { return nil }
        return held
    }

    enum SwapFailure: Error, Equatable, Sendable {
        case wrongNetwork
        case underdelivers(Money)
        case routeReverts
    }

    /// Simulated unsigned first, with AUSD read either side; only a route that leaves at least
    /// the quoted minimum is then signed.
    func swapMON(_ swap: AUSDSwap, progress: @MainActor @escaping (SwapStep) -> Void) async throws -> SwapReceipt {
        guard network.holdsRealFunds, let address else { throw SwapFailure.wrongNetwork }
        progress(.checking)
        let rpc = MonadRPC(configuration: try network.rpc())
        let ausd = try Self.ethereumAddress(network.pinnedCollateralToken)
        let balanceOf = try Calldata.balanceOf(address)
        let simulated = try await rpc.simulate([
            SimulatedCall(to: ausd, data: balanceOf),
            SimulatedCall(from: address, to: swap.to, data: swap.data, value: swap.value.bigEndianBytes),
            SimulatedCall(to: ausd, data: balanceOf),
        ])
        guard simulated[1].succeeded else { throw SwapFailure.routeReverts }
        let before = ABIMoney.decode(simulated[0].returnData)
        let after = ABIMoney.decode(simulated[2].returnData)
        guard after.raw - before.raw >= swap.minimumOut.raw,
              let gain = Money(raw: after.raw - before.raw) else {
            throw SwapFailure.underdelivers(Money(raw: max(0, after.raw - before.raw)) ?? .zero)
        }

        let sender: TransactionSender
        if let mainnetSender {
            sender = mainnetSender
        } else {
            sender = TransactionSender(rpc: rpc)
            mainnetSender = sender
        }
        progress(.signing)
        let signed = try await passkey.withKeys { wallet, _ in
            try await sender.send(to: swap.to, data: swap.data, value: swap.value.bigEndianBytes, from: wallet)
        }
        progress(.sending)
        _ = try await sender.wait(for: signed)
        let held = walletAUSD.value ?? before
        await refreshUntilChanged()
        let received = walletAUSD.value.flatMap { Money(raw: max(0, $0.raw - held.raw)) } ?? gain
        return SwapReceipt(hash: signed.hashHex, received: received.raw > 0 ? received : gain)
    }

    /// The approval and the swap are simulated together first. The holder reverts below the quoted
    /// floor, so a route that would hand back less never reaches Face ID.
    func swapAUSD(_ swap: MONSwap, progress: @MainActor @escaping (SwapStep) -> Void) async throws -> MONSwapReceipt {
        guard network.holdsRealFunds, let address else { throw SwapFailure.wrongNetwork }
        progress(.checking)
        let rpc = MonadRPC(configuration: try network.rpc())
        let ausd = try Self.ethereumAddress(network.pinnedCollateralToken)
        let allowance = ABIMoney.decode(try await rpc.callContract(
            to: ausd, data: try Calldata.allowance(owner: address, spender: swap.to)))
        let approval = try Calldata.approve(spender: swap.to, amount: swap.amount)
        let needsApproval = allowance < swap.amount
        var calls: [SimulatedCall] = []
        if needsApproval { calls.append(SimulatedCall(from: address, to: ausd, data: approval)) }
        calls.append(SimulatedCall(from: address, to: swap.to, data: swap.data))
        let simulated = try await rpc.simulate(calls)
        guard simulated.allSatisfy(\.succeeded) else { throw SwapFailure.routeReverts }

        let sender: TransactionSender
        if let mainnetSender {
            sender = mainnetSender
        } else {
            sender = TransactionSender(rpc: rpc)
            mainnetSender = sender
        }
        let before = walletMON.value
        progress(.signing)
        let hash = try await passkey.withKeys { wallet, _ in
            if needsApproval {
                await MainActor.run { progress(.approving) }
                let approved = try await sender.send(to: ausd, data: approval, from: wallet)
                _ = try await sender.wait(for: approved)
            }
            await MainActor.run { progress(.sending) }
            let swapped = try await sender.send(to: swap.to, data: swap.data, from: wallet)
            _ = try await sender.wait(for: swapped)
            return swapped.hashHex
        }
        await refreshUntilChanged()
        // What landed, by the wallet's own balance; the floor stands in until the node catches up.
        var received = swap.minimumOut
        if let before, let after = walletMON.value, after.raw > before.raw,
           let gained = NativeAmount(raw: after.raw - before.raw) {
            received = gained
        }
        return MONSwapReceipt(hash: hash, received: received)
    }

    /// Buys a Monad token with MON through 0x's holder, after the route is simulated and the
    /// token balance it would leave is checked against the quoted floor; below it, Face ID is
    /// never asked. Returns the transaction hash once mined.
    func buyToken(_ swap: TokenSwap, progress: @MainActor @escaping (SwapStep) -> Void) async throws -> String {
        guard network.holdsRealFunds, let address else { throw SwapFailure.wrongNetwork }
        progress(.checking)
        let rpc = MonadRPC(configuration: try network.rpc())
        let balanceOf = try Calldata.balanceOf(address)
        let simulated = try await rpc.simulate([
            SimulatedCall(to: swap.token, data: balanceOf),
            SimulatedCall(from: address, to: swap.to, data: swap.data, value: swap.value.bigEndianBytes),
            SimulatedCall(to: swap.token, data: balanceOf),
        ])
        guard simulated[1].succeeded else { throw SwapFailure.routeReverts }
        let before = NativeAmount(bigEndian: simulated[0].returnData).raw
        let after = NativeAmount(bigEndian: simulated[2].returnData).raw
        guard after - before >= swap.minimumOutRaw else { throw SwapFailure.underdelivers(.zero) }

        let sender: TransactionSender
        if let mainnetSender {
            sender = mainnetSender
        } else {
            sender = TransactionSender(rpc: rpc)
            mainnetSender = sender
        }
        progress(.signing)
        let signed = try await passkey.withKeys { wallet, _ in
            try await sender.send(to: swap.to, data: swap.data, value: swap.value.bigEndianBytes, from: wallet)
        }
        progress(.sending)
        _ = try await sender.wait(for: signed)
        await refreshMainnetMON()
        return signed.hashHex
    }

    private func refreshUntilChanged() async {
        let before = (walletMON.value?.raw, walletAUSD.value)
        for _ in 0..<6 {
            await refreshBalances()
            if walletMON.value?.raw != before.0 || walletAUSD.value != before.1 { return }
            try? await Task.sleep(for: .milliseconds(700))
        }
    }

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
    enum OpeningMismatch: Error { case differentWallet }

    static func openingSentence(for error: any Error) -> String {
        switch error {
        case OpeningMismatch.differentWallet:
            return "That passkey belongs to a different wallet. Choose the one you signed in with."

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

    private(set) var withdrawal: Withdrawal = .idle

    #if DEBUG
    func seedWithdrawalSentForReview() {
        withdrawal = .sent(WithdrawalReceipt(
            amount: Money(text: "107783.80") ?? .zero,
            recipient: EthereumAddress(text: "0x82f0c4a9e1b7d3f5a2c8e6b4d0a9f1e3c5b7d3ae"),
            transactions: [
                "0xd4236470b7532e15fb9a3c1e8d2f4b6a0c7e9d1f3b5a7c9e1d3f5b7a9c1e3f5a11b459811f4fbc945c7",
                "0x22b5f79ac1c3320752e4d6f8a0b2c4d6e8f0a2b4c6d8e0f2a4b6c8d0e2f4a6b858ac29e37b65964af2ed",
            ]))
    }
    #endif
    private(set) var deposit: Deposit = .idle

    enum Deposit: Equatable {
        case idle
        case approving
        case depositing
        case sent(String)
        case failed(String)

        var isBusy: Bool { self == .approving || self == .depositing }
    }

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
        case trading
        case wallet
    }

    struct WithdrawalReceipt: Equatable, Sendable {
        let amount: Money
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

    /// Signed by the wallet key, never the API key: a trading session must not be able to move money.
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

    func deleteAccount() async -> String? {
        guard let address else { return nil }
        let passkey = passkey
        do {
            try await DeskProfile.delete(address: address) { digest in
                try await passkey.withKeys { wallet, _ in try WalletSigner.sign(digest: digest, with: wallet) }
            }
        } catch PasskeyFailure.cancelledByUser {
            return "Nothing was deleted."
        } catch DeskProfile.Failure.refused(let reason) {
            return reason
        } catch {
            return "Desk's server couldn't be reached, so nothing was deleted. Try again."
        }
        for network in DeskNetwork.allCases { APIKeyStore.forNetwork(network).delete(for: address) }
        for network in DeskNetwork.allCases { TradingKeyVault.forget(address: address, network: network.rawValue) }
        await endSession()
        return nil
    }

    func endSession() async {
        if let address {
            TradingKeyVault.forget(address: address, network: network.rawValue)
            ClosedPositionsStore.shared.forget(address: address.checksummed)
        }
        await trading.abandon()
        await session.end()
        isKeyUnlocked = false
        unlockProblem = nil
        stage = .welcome
        address = nil
        balancePoller?.cancel()
        balancePoller = nil
        balances = nil
        collateral = LastGood()
        walletAUSD = LastGood()
        walletMON = LastGood()
        hasDesk = LastGood()
        openPosition = nil
        openPositions = []
        stagedClosedTrades = nil
        hasTradingAccount = false
        sessionTradingIndex = nil
        fundingProblem = nil
        openingProblem = nil
        needsManualFaucet = false
        await TradeAlerts.shared.signOut()
        UserDefaults.standard.removeObject(forKey: TraderDirectory.storageKey)
        UserDefaults.standard.removeObject(forKey: TraderDirectory.withoutAccountKey)
        // The next account on this phone inherits none of this one's copying or tracking.
        TrackedWallets.shared.forgetAll()
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("desk.copy.") {
            UserDefaults.standard.removeObject(forKey: key)
        }
        AutoCopyGlance.forget()
        PortfolioGlance.forget()
        WidgetCenter.shared.reloadTimelines(ofKind: AutoCopyControl.widgetKind)
        WidgetCenter.shared.reloadTimelines(ofKind: PortfolioGlance.widgetKind)
    }

    func enterBackground() async {
        await session.allowAway(AutoCopyAway.isOn)
        await session.enterBackground()
    }

    func expireIfAway() async {
        await session.expireIfOverdue()
        if await session.isOpen == false, address != nil { await lock() }
    }

    func enterForeground() async {
        let absence = await session.absence
        await session.enterForeground()
        if await session.isOpen == false, isKeyUnlocked { await lock() }
        if isKeyUnlocked, let absence, absence >= SigningSession.backgroundGrace,
           await LocalAuth.confirm("Unlock Desk") == false {
            await lock()
        }
        guard !isKeyUnlocked, address != nil, stage == .trading else { return }
        await unlock()
    }

    func lock() async {
        await session.end()
        isKeyUnlocked = false
        // An authenticated socket keeps accepting orders with no key behind it, so locking closes
        // it; the next order must sign in again, which asks for Face ID.
        await trading.close()
    }

    /// Assertion only, so it can never create a passkey. The derived address must match the one
    /// on screen: a different address is a different wallet.
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
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-stage"), arguments.contains("-network") { return }
        #endif
        do {
            let reader = try await balanceReader()
            let snapshot = await reader.read(for: address)
            record(snapshot.walletAUSD, into: &walletAUSD)
            record(snapshot.gas, into: &walletMON)
            record(snapshot.hasDesk, into: &hasDesk)
            await resumeTradingIfFound(address)
        } catch {
            let reason = "Could not reach the exchange to find out which contracts to read."
            walletAUSD.recordFailure(reason)
            walletMON.recordFailure(reason)
            hasDesk.recordFailure(reason)
        }
    }

    private func resumeTradingIfFound(_ address: EthereumAddress) async {
        guard hasDesk.value == true, !hasTradingAccount, !isWorking,
              stage == .trading, let stored = apiKeys.load(for: address) else { return }
        let network = network
        guard let configuration = try? network.perpl(),
              let context = try? await PerplREST(configuration: configuration).context() else { return }
        guard self.network == network, self.address == address, !hasTradingAccount, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        noteMinimumToOpen(context)
        await enterTrading(stored, context: context)
    }

    private func record<Value>(_ read: BalanceReader.Read<Value>, into slot: inout LastGood<Value>) {
        switch read {
        case .ok(let value): slot.record(value)
        case .failed(let reason): slot.recordFailure(reason)
        }
    }

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

/// UserDefaults is wiped with the app; the Keychain copy outlives a reinstall.
enum NetworkChoice {
    private static let defaultsKey = "desk.network"
    private static var item: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.opia.desk.network",
         kSecAttrAccount as String: "choice"]
    }

    static var saved: DeskNetwork? {
        if let text = UserDefaults.standard.string(forKey: defaultsKey) { return DeskNetwork(rawValue: text) }
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return DeskNetwork(rawValue: String(decoding: data, as: UTF8.self))
    }

    static func save(_ network: DeskNetwork) {
        UserDefaults.standard.set(network.rawValue, forKey: defaultsKey)
        let data = Data(network.rawValue.utf8)
        guard SecItemUpdate(item as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound
        else { return }
        var added = item
        added[kSecValueData as String] = data
        added[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(added as CFDictionary, nil)
    }

    /// With no choice saved, a wallet that enrolled on mainnet is a mainnet desk.
    static func likely(for address: EthereumAddress) -> DeskNetwork {
        APIKeyStore.forNetwork(.mainnet).load(for: address) != nil ? .mainnet : .testnet
    }
}

enum LocalAuth {
    static func confirm(_ reason: String) async -> Bool {
        let context = LAContext()
        var unavailable: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &unavailable) else { return true }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}
