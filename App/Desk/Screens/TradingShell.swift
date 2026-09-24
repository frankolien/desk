import DeskUI
import SwiftUI

/// Apple's own `TabView`, not a drawn bar: iOS supplies the glass, the selection lens and the safe-area placement.
struct TradingShell: View {
    let model: AppModel

    @State private var market: MarketModel
    @State private var copier: CopyTrader
    @State private var glances = HomeGlancePublisher()
    /// The model's session, never one of our own. `openDesk` hands the enrolled key to
    /// `model.trading`, so a session created here would be a different object and the
    /// ticket would talk to one that had never been given a key.
    private var session: TradingSession { model.trading }
    @State private var tab: Destination
    @State private var showsAccount = false
    @State private var showsFunding = false
    @State private var showsSetup = false
    @State private var showsWithdraw = false
    @State private var showsNetwork = false
    @State private var showsSwap = false
    @State private var showsActivity = false
    @State private var fillConfirmation: String?

    enum Destination: Hashable {
        case home, signals, perps, search
    }

    init(model: AppModel) {
        self.model = model
        _market = State(initialValue: MarketModel(network: model.network))
        _copier = State(initialValue: CopyTrader(network: model.network))
        _tab = State(initialValue: Self.startingTab())
    }

    /// Which tab a debug launch opens on.
    ///
    /// `-stage <name>` already decides whether the app is signed in; this reads the same
    /// argument to pick a destination, so every tab can be captured and reviewed without
    /// tapping — which is the only way to look at them in a simulator, and the reason the
    /// fabricated Watchlist survived as long as it did.
    ///
    /// Debug only. A release build always opens on Home.
    private static func startingTab() -> Destination {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("signals") || arguments.contains("signal-detail") || arguments.contains("watchlist") { return .signals }
        if arguments.contains("search") { return .search }
        if arguments.contains("home") || arguments.contains("home-setup") { return .home }
        #endif
        return .perps
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab("Trade", systemImage: "arrow.left.arrow.right", value: .perps) {
                MarketScreen(
                    model: model, market: market, session: session, copier: copier,
                    onOrderFilled: orderFilled,
                    onOpenTraders: { tab = .signals },
                    onFund: { if model.hasTradingAccount { showsFunding = true } else { showsSetup = true } })
            }

            Tab("Search", systemImage: "magnifyingglass", value: .search) {
                MarketSearchScreen(
                    model: model, market: market, session: session,
                    onOrderFilled: orderFilled)
            }

            Tab("Signals", systemImage: "antenna.radiowaves.left.and.right", value: .signals) {
                SignalsScreen(
                    model: model, market: market, session: session, copier: copier,
                    onOrderFilled: orderFilled)
            }

            Tab("Profile", systemImage: "person.crop.circle.fill", value: .home) {
                HomeScreen(
                    model: model,
                    market: market,
                    onTrade: { tab = .perps },
                    onFund: { if model.hasTradingAccount { showsFunding = true } else { showsSetup = true } },
                    onSetup: { showsSetup = true },
                    onWithdraw: { showsWithdraw = true },
                    onNetwork: { showsNetwork = true },
                    onFollowing: { tab = .signals },
                    onActivity: { showsActivity = true },
                    onSpot: { tab = .search },
                    onSwap: { showsSwap = true },
                    onAccount: { showsAccount = true })
            }
        }
        .tint(.white)
        .onChange(of: TokenOpenRequest.shared.pending) { _, target in if target != nil { tab = .search } }
        .onChange(of: MarketOpenRequest.shared.pending) { _, symbol in if symbol != nil { tab = .perps } }
        .sheet(isPresented: $showsAccount) {
            AccountScreen(model: model)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showsFunding) { AddFundsSheet(model: model) }
        .sheet(isPresented: $showsNetwork) {
            NetworkSheet(model: model)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        #if DEBUG
        .task {
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-open-activity") { showsActivity = true }
            if arguments.contains("-open-settings") { showsAccount = true }
            if arguments.contains("-open-withdraw") { showsWithdraw = true }
            if arguments.contains("-open-funds") { showsFunding = true }
            if arguments.contains("-open-network") { showsNetwork = true }
            if arguments.contains("-open-swap") { showsSwap = true }
        }
        #endif
        .sheet(isPresented: $showsSwap) {
            SwapSheet(model: model) { showsSwap = false }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showsActivity) {
            ActivityScreen(model: model)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showsWithdraw) {
            WithdrawSheet(model: model) { showsWithdraw = false }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showsSetup) {
            FundScreen(model: model) { showsSetup = false }
        }
        .task { market.start() }
        .task {
            while !Task.isCancelled {
                glances.publish(model: model, market: market)
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .task {
            copier.onEvent = { message in toast(message) }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-copy-demo") { copier.seedForReview() }
            #endif
            await copier.run(model: model, market: market, session: session)
        }
        // A tapped trade alert opens on Signals, over whatever was in front.
        .onChange(of: TradeAlerts.shared.opened, initial: true) { _, opened in
            guard opened != nil else { return }
            showsAccount = false
            showsFunding = false
            showsNetwork = false
            showsActivity = false
            showsWithdraw = false
            tab = .signals
        }
        #if DEBUG
        .task {
            let arguments = ProcessInfo.processInfo.arguments
            guard arguments.contains("-alert-demo") || arguments.contains("-alert-copy-demo") else { return }
            try? await Task.sleep(for: .seconds(1))
            TradeAlerts.shared.openedToCopy = arguments.contains("-alert-copy-demo")
            TradeAlerts.shared.opened = TradeAlert(
                event: .opened, trader: "0x95D2602d30DA1179fd13274839e60345857ca648", market: "ETH", side: "long",
                leverage: 4, entry: "1847.99", value: "12236.1", observedAt: .now.addingTimeInterval(-95))
        }
        #endif
        // The head block arrives on the same context call the price does, and every
        // order's deadline is computed against it.
        .onChange(of: market.headBlock) { _, block in session.noteHeadBlock(block) }
        .onDisappear(perform: market.stop)
        .overlay(alignment: .top) {
            if let fillConfirmation {
                Label(fillConfirmation, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .background(DeskColor.rise.color, in: Capsule())
                    .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.28), value: fillConfirmation)
    }

    private func orderFilled(_ side: Direction, _ symbol: String) {
        tab = .perps
        toast("\(side.word()) \(symbol) filled")
    }

    private func toast(_ message: String) {
        fillConfirmation = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.4))
            guard fillConfirmation == message else { return }
            fillConfirmation = nil
        }
    }
}
