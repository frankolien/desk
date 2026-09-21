import DeskMoney
import DeskPerpl
import DeskUI
import SwiftUI

struct SignalsScreen: View {
    let model: AppModel
    let market: MarketModel
    let session: TradingSession
    let copier: CopyTrader
    let onOrderFilled: (Direction, String) -> Void

    private enum Section: String, CaseIterable, Identifiable {
        case traders = "Traders", smart = "Smart money", market = "Market"
        var id: String { rawValue }
    }

    private struct CopyOrder: Identifiable {
        let side: Direction
        let leverage: Int
        var id: String { "\(side)-\(leverage)" }
    }

    @State private var section: Section = .traders
    @State private var directory = TraderDirectory()
    @State private var selectedTrader: TraderSnapshot?
    @State private var copyOrder: CopyOrder?
    @State private var pendingCopy: CopyOrder?
    @State private var unlistedMarket: String?
    @State private var tradeAlert: TradeAlert?
    @State private var showsCopying = false
    @State private var afterAlert: (() -> Void)?
    @State private var smartMoney = SignalsModel()
    @State private var trackedEditing: TrackedWallet?
    @State private var showsTrackNew = false
    #if DEBUG
    @State private var debugPrimer: TraderSnapshot?
    @State private var debugAutoCopy: TraderSnapshot?
    #endif

    private var signals: MarketSignals? {
        market.market.map {
            MarketSignals(
                state: $0.state,
                priceDecimals: $0.config.priceDecimals,
                sizeDecimals: $0.config.sizeDecimals)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                DeskBackground()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Signals")
                            .font(.system(size: 30, weight: .heavy, design: .rounded))
                            .foregroundStyle(DeskColor.nightText.color)
                            .padding(.top, 10)

                        sectionPicker.padding(.top, 14)

                        switch section {
                        case .traders:
                            TrackedWalletsStrip(onOpen: { trackedEditing = $0 }, onAdd: { showsTrackNew = true })
                                .padding(.top, 20)
                            TradersFeed(directory: directory, copier: copier, onOpenCopying: { showsCopying = true }) {
                                selectedTrader = $0
                            }
                                .padding(.top, 28)
                                .padding(.bottom, 130)
                        case .smart:
                            SmartMoneyFeed(model: smartMoney) { signal in
                                TokenOpenRequest.shared.open(.init(chainIndex: signal.chainIndex, contract: signal.token))
                            }
                                .padding(.top, 20)
                                .padding(.bottom, 130)
                                .task { await smartMoney.run() }
                        case .market:
                            marketReadings
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .refreshable {
                    async let top: Void = directory.refreshTop()
                    async let following: Void = directory.refreshFollowing()
                    _ = await (top, following)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            #if DEBUG
            // `-smart-money` opens the Smart money segment; `-track-demo` seeds a tracked wallet.
            .task {
                let arguments = ProcessInfo.processInfo.arguments
                if arguments.contains("-track-demo"), TrackedWallets.shared.list.isEmpty {
                    TrackedWallets.shared.track("0x52ac212e7187a799a7382c7a768cb35b72a3e20a", name: "moncat degen")
                }
                if arguments.contains("-smart-money") { section = .smart }
            }
            #endif
            .sheet(item: $trackedEditing) { wallet in
                TrackWalletSheet(existing: wallet).fittedSheet().presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showsTrackNew) {
                TrackWalletSheet(existing: nil).fittedSheet().presentationDragIndicator(.visible)
            }
            .navigationDestination(item: $selectedTrader) { trader in
                TraderProfileScreen(initial: trader, directory: directory, copier: copier) { copy($0) }
                    .toolbar(.hidden, for: .tabBar)
            }
            .navigationDestination(isPresented: $showsCopying) {
                CopyActivityScreen(copier: copier, directory: directory)
                    .toolbar(.hidden, for: .tabBar)
            }
        }
        .task { await directory.run() }
        #if DEBUG
        .task { if ProcessInfo.processInfo.arguments.contains("-copy-activity") { showsCopying = true } }
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-crowd-demo") else { return }
            section = .market
            directory.seedCrowdForReview()
        }
        #endif
        #if DEBUG
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-alerts-primer") else { return }
            while directory.top.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            debugPrimer = directory.top.first
        }
        .task {
            let arguments = ProcessInfo.processInfo.arguments
            guard let flag = arguments.firstIndex(of: "-trader-profile") else { return }
            if arguments.indices.contains(flag + 1), arguments[flag + 1].hasPrefix("0x") {
                selectedTrader = TraderSnapshot(accountId: nil, address: arguments[flag + 1], pnl: nil, balance: nil, positions: [])
                return
            }
            while directory.top.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            selectedTrader = directory.top.first
        }
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-auto-copy-sheet") else { return }
            while directory.top.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            debugAutoCopy = directory.top.first
        }
        .sheet(item: $debugAutoCopy) { trader in
            AutoCopySheet(address: trader.address, name: directory.name(for: trader.address), copier: copier)
        }
        .sheet(item: $debugPrimer) { trader in
            AlertsPrimerSheet(trader: trader, name: directory.name(for: trader.address), onEnable: {}, onLater: {})
                .fittedSheet()
        }
        #endif
        .onChange(of: TradeAlerts.shared.opened, initial: true) { _, opened in
            guard let opened else { return }
            let straightToCopy = TradeAlerts.shared.openedToCopy
            TradeAlerts.shared.opened = nil
            TradeAlerts.shared.openedToCopy = false
            section = .traders
            copyOrder = nil
            pendingCopy = nil
            // Lets any sheet the tap interrupted finish leaving before this one arrives.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                if straightToCopy {
                    for _ in 0..<50 where market.allMarkets.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
                    copy(market: opened.market, isLong: opened.isLong, leverage: opened.leverage)
                } else {
                    tradeAlert = opened
                }
            }
        }
        .sheet(item: $tradeAlert, onDismiss: {
            afterAlert?()
            afterAlert = nil
        }) { alert in
            TradeAlertSheet(
                alert: alert, directory: directory,
                onCopy: { alert in
                    afterAlert = { copy(market: alert.market, isLong: alert.isLong, leverage: alert.leverage) }
                    tradeAlert = nil
                },
                onViewTrader: { address in
                    afterAlert = {
                        selectedTrader = directory.following.first { $0.id == address.lowercased() }
                            ?? TraderSnapshot(accountId: nil, address: address, pnl: nil, balance: nil, positions: [])
                    }
                    tradeAlert = nil
                })
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $copyOrder) { order in
            TicketSheet(
                side: order.side, market: market.market, mark: market.mark.value,
                session: session, initialLeverage: order.leverage
            ) {
                session.clear()
                copyOrder = nil
                onOrderFilled(order.side, market.symbol)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $pendingCopy) { order in
            LeverageExplainer(
                onAgree: {
                    model.hasSeenLeverageExplainer = true
                    pendingCopy = nil
                    copyOrder = order
                },
                onBack: { pendingCopy = nil })
        }
        .alert("Not on Desk yet", isPresented: Binding(
            get: { unlistedMarket != nil },
            set: { if !$0 { unlistedMarket = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("\(unlistedMarket ?? "This market") isn't listed on Perpl \(model.network.shortName.lowercased()), so it can't be copied here.")
        }
    }

    /// Their market, side and leverage on your own testnet ticket. The amount is yours to
    /// choose: their size is sized to their account, not to this one.
    private func copy(_ position: TraderPosition) {
        copy(market: position.market, isLong: position.isLong, leverage: position.leverage)
    }

    private func copy(market symbol: String, isLong: Bool, leverage: Double?) {
        guard let target = market.allMarkets.first(where: {
            $0.symbol.caseInsensitiveCompare(symbol) == .orderedSame
        }) else {
            unlistedMarket = symbol
            return
        }
        market.select(target)
        let order = CopyOrder(
            side: isLong ? .up : .down,
            leverage: max(1, Int((leverage ?? 1).rounded())))
        selectedTrader = nil
        if order.leverage > 1 && !model.hasSeenLeverageExplainer {
            pendingCopy = order
        } else {
            copyOrder = order
        }
    }

    private var sectionPicker: some View {
        HStack(spacing: 0) {
            ForEach(Section.allCases) { item in
                Button { withAnimation(.easeOut(duration: 0.18)) { section = item } } label: {
                    Text(item.rawValue)
                        .font(.system(size: 13, weight: section == item ? .bold : .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(section == item ? Color.white.opacity(0.24) : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.11), in: Capsule())
    }

    @ViewBuilder
    private var marketReadings: some View {
        MarketCrowdFeed(crowd: directory.crowd, name: directory.name) { address in
            selectedTrader = directory.top.first { $0.id == address.lowercased() }
                ?? TraderSnapshot(accountId: nil, address: address, pnl: nil, balance: nil, positions: [])
        }

        Text("\(market.symbol)-PERP, read live from Perpl")
            .font(DeskType.caption)
            .foregroundStyle(DeskColor.nightMuted.color)
            .padding(.top, 34)

        if let signals, !signals.isEmpty {
            premium(signals).padding(.top, 22)

            VStack(spacing: 10) {
                spread(signals)
                flow(signals)
                interest(signals)
            }
            .padding(.top, 12)
        } else {
            waiting.padding(.top, 30)
        }

        Text("These come from the venue's own figures — the mark against the "
             + "index, the bid against the ask, the last trade against the "
             + "middle. They describe the market, not what you should do.")
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(DeskColor.nightMuted.color.opacity(0.8))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 26)
            .padding(.bottom, 130)
    }

    // MARK: - The headline

    /// Mark against index: the one reading that says what the crowd is doing.
    ///
    /// Drawn as two marks on a line rather than stated as a percentage, because "0.2%
    /// above" means nothing to someone who has not held a perpetual, while two dots that
    /// do not line up is immediately legible.
    private func premium(_ signals: MarketSignals) -> some View {
        let micros = signals.premiumMicros ?? 0
        let above = micros > 0
        let tint: DeskRGB = !signals.premiumIsNotable ? DeskColor.nightMuted
            : (above ? DeskColor.rise : DeskColor.fall)

        return VStack(alignment: .leading, spacing: 0) {
            Text(signals.premiumIsNotable
                 ? (above ? "Buyers are paying above spot" : "Sellers are pushing below spot")
                 : "The perp is tracking spot")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(DeskColor.nightText.color)
                .fixedSize(horizontal: false, vertical: true)

            Text(signals.premiumIsNotable
                 ? "Holding a long here costs funding. Shorts are being paid it."
                 : "Neither side is paying much to hold a position.")
                .font(DeskType.caption)
                .foregroundStyle(DeskColor.nightMuted.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            premiumBar(micros: micros, tint: tint)
                .padding(.top, 20)

            HStack {
                Text("Index")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
                Spacer()
                Text(Self.percent(micros))
                    .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(tint.color)
                    .contentTransition(.numericText())
            }
            .padding(.top, 10)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DeskColor.nightChip.color.opacity(0.6),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(DeskColor.nightLine.color, lineWidth: 0.5))
        .animation(.snappy(duration: 0.3), value: micros)
    }

    /// The index sits at the centre; the perp sits off it. Clamped at half a percent,
    /// which is already a large premium on a liquid market.
    private func premiumBar(micros: Int, tint: DeskRGB) -> some View {
        GeometryReader { proxy in
            let limit = 5_000.0
            let offset = max(-1, min(1, Double(micros) / limit))
            let centre = proxy.size.width / 2

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DeskColor.nightLine.color)
                    .frame(height: 3)
                    .frame(maxHeight: .infinity, alignment: .center)

                // The index, fixed.
                Circle()
                    .strokeBorder(DeskColor.nightMuted.color, lineWidth: 2)
                    .frame(width: 11, height: 11)
                    .position(x: centre, y: proxy.size.height / 2)

                // The perp, offset by the premium.
                Circle()
                    .fill(tint.color)
                    .frame(width: 13, height: 13)
                    .shadow(color: tint.color.opacity(0.8), radius: 6)
                    .position(x: centre + offset * (centre - 10), y: proxy.size.height / 2)
            }
        }
        .frame(height: 18)
        .accessibilityElement()
        .accessibilityLabel("Premium over index")
        .accessibilityValue(Self.percent(micros))
    }

    // MARK: - The rows

    private func spread(_ signals: MarketSignals) -> some View {
        row(symbol: "arrow.left.and.right",
            title: "Spread",
            detail: signals.spreadMicros.map {
                $0 < 500 ? "Tight — cheap to get in and out" : "Wide — getting out will cost you"
            } ?? "No book to read",
            value: signals.spreadMicros.map(Self.percentUnsigned) ?? Unavailable.text,
            tint: signals.spreadMicros.map { $0 < 500 ? DeskColor.rise : DeskColor.action }
                ?? DeskColor.nightMuted)
    }

    private func flow(_ signals: MarketSignals) -> some View {
        let (detail, value, tint): (String, String, DeskRGB) = switch signals.lean {
        case .buyers: ("The last trade lifted the ask", "Buying", DeskColor.rise)
        case .sellers: ("The last trade hit the bid", "Selling", DeskColor.fall)
        case .balanced: ("Nothing decisive either way", "Balanced", DeskColor.nightMuted)
        }
        return row(symbol: "arrow.up.arrow.down", title: "Last trade",
                   detail: detail, value: value, tint: tint)
    }

    private func interest(_ signals: MarketSignals) -> some View {
        row(symbol: "chart.bar.fill",
            title: "Open interest",
            detail: signals.openInterest.map {
                $0.display(fractionDigits: 2) + " \(market.symbol) held across all positions"
            } ?? "Nothing open in this market",
            value: signals.openInterestNotional.map { "$" + $0.display(fractionDigits: 0) }
                ?? Unavailable.text,
            tint: DeskColor.nightText)
    }

    private func row(
        symbol: String, title: String, detail: String, value: String, tint: DeskRGB
    ) -> some View {
        HStack(spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DeskColor.nightMuted.color)
                .frame(width: 34, height: 34)
                .background(Color.white.opacity(0.05), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
                Text(detail)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Text(value)
                .font(.system(size: 14, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(tint.color)
                .contentTransition(.numericText())
        }
        .padding(14)
        .background(DeskColor.nightChip.color.opacity(0.45),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(DeskColor.nightLine.color, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }

    /// Skeletons rather than a spinner: the rows that will be here are drawn empty, so the
    /// screen reads as filling rather than as broken.
    private var waiting: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(0..<4, id: \.self) { index in
                SkeletonRow(widthFraction: [0.9, 0.55, 0.75, 0.45][index])
            }
        }
        .padding(18)
        .background(DeskColor.nightChip.color.opacity(0.45),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    static func percent(_ micros: Int) -> String {
        let sign = micros < 0 ? Direction.minus : "+"
        return sign + percentUnsigned(abs(micros))
    }

    static func percentUnsigned(_ micros: Int) -> String {
        "\(abs(micros) / 10_000).\(String(format: "%02d", (abs(micros) % 10_000) / 100))%"
    }
}
