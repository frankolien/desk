import DeskUI
import SwiftUI

struct TradingShell: View {
    let model: AppModel

    @State private var market: MarketModel
    @State private var copier: CopyTrader
    @State private var glances = HomeGlancePublisher()
    @State private var opensTopTraders = false
    /// The model's session, never a new one: `openDesk` gives the enrolled key to `model.trading`,
    /// and a session created here would never have been given a key.
    private var session: TradingSession { model.trading }
    @State private var tab: Destination
    @State private var showsAccount = false
    @State private var showsFunding = false
    @State private var showsSetup = false
    @State private var showsWithdraw = false
    @State private var showsNetwork = false
    @State private var showsSwap = false
    @State private var showsOnramp = false
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
            Tab("Home", systemImage: "house.fill", value: .perps) {
                MarketScreen(
                    model: model, market: market, session: session, copier: copier,
                    onOrderFilled: orderFilled,
                    onOpenTraders: { tab = .signals },
                    onOpenTopTraders: { opensTopTraders = true; tab = .signals },
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
                    onOrderFilled: orderFilled, opensTop: $opensTopTraders)
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
                    onAccount: { showsAccount = true },
                    isActive: tab == .home)
            }
        }
        .tint(.white)
        .onChange(of: tab) { _, _ in Haptics.selection() }
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
            if arguments.contains("-open-onramp") { showsOnramp = true }
        }
        #endif
        .sheet(isPresented: $showsSwap) {
            SwapSheet(model: model) { showsSwap = false }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showsOnramp) {
            OnrampSheet(model: model) { showsOnramp = false }
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
        .sheet(isPresented: $showsSetup) { AddFundsSheet(model: model) }
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
        .onChange(of: TradeAlerts.shared.opened, initial: true) { _, opened in
            guard opened != nil else { return }
            closeSheets()
            tab = .signals
        }
        .onChange(of: TradeAlerts.shared.openedTrader, initial: true) { _, trader in
            guard trader != nil else { return }
            closeSheets()
            tab = .signals
        }
        .onChange(of: TradeAlerts.shared.opensProfile, initial: true) { _, opens in
            guard opens else { return }
            TradeAlerts.shared.opensProfile = false
            closeSheets()
            tab = .home
            Task { await model.refreshBalances() }
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
        .onAppear {
            let session = session
            let network = market.network
            market.onHeadBlock = { [weak session] block in
                guard let session, session.network == network else { return }
                session.noteHeadBlock(block)
            }
            if market.headBlock > 0, session.network == network { session.noteHeadBlock(market.headBlock) }
        }
        .onDisappear {
            market.onHeadBlock = nil
            market.stop()
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                if !Connectivity.shared.isOnline {
                    Label("Offline · showing saved data", systemImage: "wifi.slash")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let fillConfirmation {
                    Label(fillConfirmation, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 16)
                        .frame(height: 44)
                        .background(DeskColor.rise.color, in: Capsule())
                        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.top, 8)
        }
        .animation(.snappy(duration: 0.28), value: fillConfirmation)
        .animation(.snappy(duration: 0.28), value: Connectivity.shared.isOnline)
    }

    private func closeSheets() {
        showsAccount = false
        showsFunding = false
        showsNetwork = false
        showsActivity = false
        showsWithdraw = false
    }

    private func orderFilled(_ side: Direction, _ symbol: String) {
        tab = .perps
        let said = session.lastFillSentence
        session.lastFillSentence = nil
        toast(said.flatMap { $0 == "Filled" ? nil : "\(side.word()) · \($0)" } ?? "\(side.word()) \(symbol) filled")
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
