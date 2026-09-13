import DeskUI
import SwiftUI

/// The signed-in shell deliberately uses Apple's native `TabView` rather than drawing
/// a tab bar. On iOS 26 the system supplies Liquid Glass, the moving selection lens,
/// search separation, refraction, safe-area placement and interaction behavior.
struct TradingShell: View {
    let model: AppModel

    @State private var market = MarketModel()
    /// The model's session, never one of our own. `openDesk` hands the enrolled key to
    /// `model.trading`, so a session created here would be a different object and the
    /// ticket would talk to one that had never been given a key.
    private var session: TradingSession { model.trading }
    @State private var tab: Destination
    @State private var showsAccount = false

    enum Destination: Hashable {
        case home, watchlist, signals, perps, search
    }

    init(model: AppModel) {
        self.model = model
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
        if arguments.contains("signals") || arguments.contains("signal-detail") { return .signals }
        if arguments.contains("watchlist") { return .watchlist }
        if arguments.contains("search") { return .search }
        if arguments.contains("market") || arguments.contains("empty") { return .perps }
        #endif
        return .home
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "creditcard.fill", value: .home) {
                HomeScreen(
                    model: model,
                    market: market,
                    onTrade: { tab = .perps },
                    onFund: { model.advance(to: .needsDesk) },
                    onAccount: { showsAccount = true })
            }

            Tab("Watchlist", systemImage: "bookmark.fill", value: .watchlist) {
                WatchlistScreen(market: market)
            }

            Tab("Signals", systemImage: "antenna.radiowaves.left.and.right", value: .signals) {
                SignalsScreen(market: market)
            }

            Tab("Perps", systemImage: "infinity", value: .perps) {
                MarketScreen(model: model, market: market, session: session)
            }

            Tab("Search", systemImage: "magnifyingglass", value: .search, role: .search) {
                MarketSearchScreen(market: market)
            }
        }
        .tint(.white)
        .sheet(isPresented: $showsAccount) {
            AccountScreen(model: model)
                .presentationBackground(.black)
        }
        .task { market.start() }
        // The head block arrives on the same context call the price does, and every
        // order's deadline is computed against it.
        .onChange(of: market.headBlock) { _, block in session.noteHeadBlock(block) }
        .onDisappear(perform: market.stop)
    }
}
