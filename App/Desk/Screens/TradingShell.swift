import DeskUI
import SwiftUI

/// The signed-in shell deliberately uses Apple's native `TabView` rather than drawing
/// a tab bar. On iOS 26 the system supplies Liquid Glass, the moving selection lens,
/// search separation, refraction, safe-area placement and interaction behavior.
struct TradingShell: View {
    let model: AppModel

    @State private var market = MarketModel()
    @State private var tab: Destination
    @State private var showsAccount = false

    enum Destination: Hashable {
        case home, watchlist, signals, perps, search
    }

    init(model: AppModel) {
        self.model = model
        let arguments = ProcessInfo.processInfo.arguments
        _tab = State(initialValue: arguments.contains("signals") || arguments.contains("signal-detail") ? .signals : arguments.contains("market") ? .perps : .home)
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
                WatchlistScreen()
            }

            Tab("Signals", systemImage: "antenna.radiowaves.left.and.right", value: .signals) {
                SignalsScreen()
            }

            Tab("Perps", systemImage: "infinity", value: .perps) {
                MarketScreen(model: model, market: market)
            }

            Tab("Search", systemImage: "magnifyingglass", value: .search, role: .search) {
                MarketSearchScreen()
            }
        }
        .tint(.white)
        .sheet(isPresented: $showsAccount) {
            AccountScreen(model: model)
                .presentationBackground(.black)
        }
        .task { market.start() }
        .onDisappear(perform: market.stop)
    }
}
