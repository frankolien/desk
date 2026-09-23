import DeskPerpl
import DeskMoney
import DeskUI
import SwiftUI

struct MarketScreen: View {
    private struct PositionContext: Identifiable {
        let held: PerplPosition
        let market: Market
        let figures: PositionFigures
        var id: String { "\(held.accountID):\(held.positionID)" }
    }

    let model: AppModel
    let market: MarketModel
    let session: TradingSession
    let onOrderFilled: (Direction, String) -> Void

    @State private var query = ""
    @State private var showsMarket = false
    @State private var selectedPosition: PerplPosition?
    @State private var showsWithdraw = false
    @State private var showsFunding = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        searchField.padding(.top, 16)
                        collateralCard.padding(.top, 24)
                        Divider().overlay(Color.white.opacity(0.10)).padding(.top, 30)
                        positions.padding(.top, 16)
                        Divider().overlay(Color.white.opacity(0.10)).padding(.top, 26)
                        markets.padding(.top, 18)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 116)
                }
                .refreshable { await market.refreshNow() }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showsMarket) {
                PerpDetailScreen(
                    model: model, market: market, session: session,
                    onOrderFilled: { side, symbol in
                        showsMarket = false
                        onOrderFilled(side, symbol)
                    })
                    .toolbar(.hidden, for: .tabBar)
            }
            .task { await openRequestedMarket() }
            .onChange(of: MarketOpenRequest.shared.pending) { _, symbol in if symbol != nil { Task { await openRequestedMarket() } } }
            #if DEBUG
            .task { if ProcessInfo.processInfo.arguments.contains("-price-demo") { MarketOpenRequest.shared.open("ETH") } }
            .task { if ProcessInfo.processInfo.arguments.contains("-open-withdraw") { showsWithdraw = true } }
            #if DEBUG
            .task {
                guard ProcessInfo.processInfo.arguments.contains("-open-ticket") else { return }
                while market.allMarkets.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
                guard let first = market.allMarkets.first else { return }
                market.select(first)
                await session.selectMarket(first)
                showsMarket = true
            }
            #endif
            #endif
            .sheet(isPresented: $showsWithdraw) {
                WithdrawSheet(model: model) { showsWithdraw = false }
                    .presentationDetents([.large])
            }
            // `item:` rather than `isPresented:`. With a boolean, SwiftUI can evaluate
            // this closure before the sibling `selectedPosition` write has landed, and the
            // sheet then presents with no content at all — a blank card, which is what
            // tapping a position actually did.
            .sheet(item: $selectedPosition) { held in
                PositionScreen(position: held, market: market, session: session, model: model)
            }
            .sheet(isPresented: $showsFunding) { AddFundsSheet(model: model) }
        }
    }

    /// A title and nothing else.
    ///
    /// There was a search button here, directly above the search field. A second entry
    /// point to a control already on screen is furniture — it costs a tap target, it
    /// implies a second behaviour that does not exist, and its absence is not missed.
    private var header: some View {
        Text("Perpetuals")
            .font(.system(size: 17, weight: .bold, design: .rounded))
            .foregroundStyle(DeskColor.nightText.color)
            .frame(height: 42)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(DeskColor.nightMuted.color)
            TextField("Search", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(DeskColor.nightText.color)
        }
        .font(.system(size: 15, weight: .medium, design: .rounded))
        .padding(.horizontal, 15)
        .frame(height: 44)
        .perpGlass(interactive: true, in: Capsule())
    }

    private var collateralCard: some View {
        HStack(spacing: 14) {
            TokenLogo(asset: .ausd, size: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text("Available")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
                Text("\(model.collateral.value?.display() ?? "—") AUSD")
                    .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(DeskColor.nightText.color)
            }

            Spacer()

            Button { showsWithdraw = true } label: {
                Image(systemName: "minus")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .perpGlass(interactive: true, in: Circle())

            Button { showsFunding = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .perpGlass(interactive: true, in: Circle())
        }
        .foregroundStyle(DeskColor.nightText.color)
        .padding(.horizontal, 16)
        .frame(height: 70)
        .perpGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    /// Derived at the point of display so that the header total, the PnL and the
    /// liquidation distance all descend from the one mark current when the screen drew.
    private var positionContexts: [PositionContext] {
        model.openPositions.compactMap { held in
            guard let positionMarket = market.market(id: held.marketID),
                  let mark = market.price(for: positionMarket),
                  let figures = PositionFigures(
                    position: held, market: positionMarket.config, mark: mark)
            else { return nil }
            return PositionContext(held: held, market: positionMarket, figures: figures)
        }
    }

    private var totalPositionPnL: Money? {
        let contexts = positionContexts
        guard !contexts.isEmpty else { return nil }
        return contexts.reduce(.zero) { $0 + $1.figures.unrealisedPnL }
    }

    private var positions: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Open Positions")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(DeskColor.nightMuted.color)

            // The header total is unrealised PnL, not notional. Notional is the number
            // that looks impressive and answers nothing; this is the one a person came
            // to see.
            Text(DisplayCurrency.shared.format(totalPositionPnL ?? .zero, signed: true))
                .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle((totalPositionPnL.map { !$0.isNegative && !$0.isZero ? DeskColor.rise : DeskColor.fall }
                                  ?? DeskColor.nightText).color)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.25), value: totalPositionPnL?.raw)
                .padding(.top, 3)

            if !positionContexts.isEmpty {
                LazyVStack(spacing: 12) {
                    ForEach(positionContexts) { position in
                        OpenPositionCard(
                            figures: position.figures,
                            symbol: position.market.symbol,
                            isStale: market.freshness.freezesDigits) {
                                market.select(position.market)
                                selectedPosition = position.held
                                Task { await session.selectMarket(position.market) }
                            }
                    }
                }
                .padding(.top, 16)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "infinity")
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundStyle(DeskColor.nightMuted.color)
                    Text("No Open Positions")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                    Text("Choose a market below to open one")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 190)
            }
        }
    }

    private var markets: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MARKETS")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(0.9)
                .foregroundStyle(DeskColor.nightMuted.color)

            let visible = market.allMarkets.filter { item in
                query.isEmpty || item.symbol.localizedCaseInsensitiveContains(query)
            }
            if !visible.isEmpty {
                ForEach(visible, id: \.id) { item in
                Button {
                    market.select(item)
                    Task {
                        await session.selectMarket(item)
                        showsMarket = true
                    }
                } label: {
                    HStack(spacing: 12) {
                        MarketTokenLogo(symbol: item.symbol, size: 42)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.symbol)
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .foregroundStyle(DeskColor.nightText.color)
                            Text("MAX \(item.config.maxLeverage)×")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(DeskColor.nightMuted.color)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .overlay(Capsule().stroke(Color.white.opacity(0.13), lineWidth: 0.7))
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            let price = market.markText(for: item)
                            Text(price == "—" ? "—" : "$" + price)
                                .font(.system(size: 18, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle(DeskColor.nightText.color)
                            let change = market.changePercent(for: item)
                            Text(change.map { String(format: "%+.2f%%", $0) } ?? "—")
                                .font(.system(size: 14, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle((change ?? 0) >= 0 ? DeskColor.rise.color : DeskColor.fall.color)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
                }
            } else {
                Text("No supported market found")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
        }
    }
}

struct PerpDetailScreen: View {
    let model: AppModel
    let market: MarketModel
    /// Handed down rather than rebuilt: an order outlives the sheet that sent it, and a
    /// session created per presentation would lose the answer.
    let session: TradingSession
    let onOrderFilled: (Direction, String) -> Void

    private enum Tab: String, CaseIterable { case holders = "Holders", about = "About" }

    @Environment(\.dismiss) private var dismiss
    @State private var ticket: Direction?
    @State private var showsSetup = false
    @State private var pendingSide: Direction?
    @State private var tab: Tab = .holders
    @State private var holders = MarketHoldersModel()
    @State private var directory = TraderDirectory()
    @State private var openHolder: MarketHolder?
    @AppStorage("desk.watchlist") private var savedIDs = ""

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    detailHeader
                    priceRow.padding(.top, 26)
                    chart.padding(.top, 20)
                    ranges.padding(.top, 16)
                    tabs.padding(.top, 24)
                    switch tab {
                    case .holders:
                        MarketHoldersList(model: holders, directory: directory) { openHolder = $0 }
                    case .about:
                        about.padding(.top, 16)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 120)
            }
            .refreshable { await market.refreshNow(); await holders.load(symbol: market.symbol) }

            HStack(spacing: 10) {
                tradeButton(.down, title: "Short")
                tradeButton(.up, title: "Long")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .toolbar(.hidden, for: .navigationBar)
        .task(id: market.symbol) { await holders.run(symbol: market.symbol) }
        .task { await directory.refreshFollowing() }
        .task {
            #if DEBUG
            // The ticket sits behind a floating bar that UI automation cannot hit, so it
            // gets the same way in that `-stage` gives every other screen.
            if ProcessInfo.processInfo.arguments.contains("-open-ticket") { ticket = .up }
            #endif
        }
        .fullScreenCover(isPresented: $showsSetup) {
            FundScreen(model: model) { showsSetup = false }
        }
        .sheet(item: $ticket) { side in
            TicketSheet(
                side: side, market: market.market, mark: market.mark.value, session: session
            ) {
                session.clear()
                ticket = nil
                dismiss()
                onOrderFilled(side, market.symbol)
            }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $pendingSide) { side in
            LeverageExplainer(
                onAgree: {
                    model.hasSeenLeverageExplainer = true
                    pendingSide = nil
                    ticket = side
                },
                onBack: { pendingSide = nil })
        }
        .sheet(item: $openHolder) { holder in
            HolderPositionSheet(holder: holder, market: market, directory: directory)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private var isSaved: Bool {
        guard let id = market.market?.id else { return false }
        return savedIDs.split(separator: ",").compactMap { UInt32($0) }.contains(id)
    }

    private func toggleSaved() {
        guard let id = market.market?.id else { return }
        var ids = savedIDs.split(separator: ",").compactMap { UInt32($0) }
        if let index = ids.firstIndex(of: id) { ids.remove(at: index) } else { ids.append(id) }
        savedIDs = ids.map(String.init).joined(separator: ",")
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private var detailHeader: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 32, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(DeskColor.nightMuted.color)

            MarketTokenLogo(symbol: market.symbol, size: 46)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(market.symbol)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                    if let leverage = market.market?.config.maxLeverage, leverage > 0 {
                        Text("\(leverage)x")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(DeskColor.nightText.color)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
                Text(TraderFormat.assetName(market.symbol))
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
            Spacer()
            Button(action: toggleSaved) {
                Image(systemName: isSaved ? "star.fill" : "star")
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 40, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(isSaved ? DeskColor.action.color : DeskColor.nightMuted.color)
            ShareLink(item: URL(string: "https://trydesk.trade/app/trade/\(market.symbol)")!) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(DeskColor.nightMuted.color)
        }
    }

    /// The day's move in money and in percent, against the venue's previous mark.
    private var change: (text: String, up: Bool)? {
        guard let listed = market.market, let mark = market.mark.value else { return nil }
        let scale = pow(10.0, Double(listed.config.priceDecimals))
        let previous = Double(listed.state.previousRaw) / scale
        let now = Double(mark.raw) / scale
        guard previous > 0 else { return nil }
        let difference = now - previous
        let percent = abs(difference / previous * 100)
        return ("\(TraderFormat.dollars(String(abs(difference)), signed: false)) (\(String(format: "%.2f", percent))%)", difference >= 0)
    }

    private var openInterestText: String? {
        guard let listed = market.market, listed.state.openInterestRaw > 0, let mark = market.mark.value else { return nil }
        let size = Double(listed.state.openInterestRaw) / pow(10.0, Double(listed.config.sizeDecimals))
        let price = Double(mark.raw) / pow(10.0, Double(listed.config.priceDecimals))
        return TraderFormat.compact(size * price)
    }

    private var priceRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                AmountText(market.markText == "—" ? "—" : "$" + market.markText, size: 40)
                    .contentTransition(.numericText())
                HStack(spacing: 6) {
                    if let change {
                        Image(systemName: change.up ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                            .font(.system(size: 9, weight: .bold))
                        Text(change.text)
                            .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                    } else {
                        Text(market.changePercentText ?? "—")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                    }
                    Text("24h")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                }
                .foregroundStyle(market.trend.color)
            }
            Spacer()
            if let openInterestText {
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(DeskColor.nightMuted.color)
                        Text(openInterestText)
                            .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(DeskColor.nightText.color)
                    }
                    Text("Open interest")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                }
                .padding(.top, 8)
            }
        }
    }

    @ViewBuilder private var chart: some View {
        if !market.candles.isEmpty, let config = market.market?.config {
            let scale = pow(10.0, Double(config.priceDecimals))
            CandlestickChart(candles: market.candles.map { $0.chartCandle(scale: scale) })
                .frame(height: 250)
                .overlay(alignment: .bottom) { Divider().overlay(Color.white.opacity(0.12)) }
        } else {
            VStack(spacing: 18) {
                SkeletonRow(widthFraction: 0.88)
                SkeletonRow(widthFraction: 0.64)
                SkeletonRow(widthFraction: 0.76)
            }
            .frame(height: 250)
        }
    }

    private var ranges: some View { CandleIntervalRail(market: market) }

    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { item in
                Button { withAnimation(.snappy(duration: 0.22)) { tab = item } } label: {
                    VStack(spacing: 10) {
                        Text(item.rawValue)
                            .font(.system(size: 15, weight: tab == item ? .bold : .medium, design: .rounded))
                            .foregroundStyle(tab == item ? .white : Color.white.opacity(0.45))
                        Rectangle().fill(tab == item ? Color.white : .clear).frame(height: 2)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5) }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 12) {
            ValueRow(label: "Market", value: "\(market.symbol)-PERP")
            ValueRow(label: "Maximum leverage", value: "\(market.market?.config.maxLeverage ?? 0)×")
            if let openInterestText { ValueRow(label: "Open interest", value: openInterestText) }
            if holders.loaded { ValueRow(label: "Open positions", value: "\(holders.count)") }
            if holders.longValue + holders.shortValue > 0 {
                let share = holders.longValue / (holders.longValue + holders.shortValue)
                VStack(alignment: .leading, spacing: 8) {
                    GeometryReader { proxy in
                        HStack(spacing: 3) {
                            Capsule().fill(DeskColor.rise.color).frame(width: max(0, proxy.size.width - 3) * share)
                            Capsule().fill(DeskColor.fall.color)
                        }
                    }
                    .frame(height: 8)
                    HStack {
                        Text("\(Int((share * 100).rounded()))% long · \(TraderFormat.compact(holders.longValue))")
                            .foregroundStyle(DeskColor.rise.color)
                        Spacer()
                        Text("\(Int(((1 - share) * 100).rounded()))% short · \(TraderFormat.compact(holders.shortValue))")
                            .foregroundStyle(DeskColor.fall.color)
                    }
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                }
                .padding(.top, 4)
            }
            ValueRow(label: "Data", value: market.freshness == .live ? "Live" : "Last known")
        }
        .padding(16)
        .perpGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func tradeButton(_ side: Direction, title: String) -> some View {
        Button {
            if !model.hasTradingAccount {
                showsSetup = true
            } else if model.hasSeenLeverageExplainer {
                ticket = side
            } else {
                pendingSide = side
            }
        } label: {
            Text(title)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(side.color.color)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .perpGlass(interactive: true, in: Capsule())
    }
}

extension Direction: @retroactive Identifiable {
    public var id: String { rawValue }
}

private extension View {
    @ViewBuilder
    func perpGlass<S: Shape>(interactive: Bool = false, in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(interactive), in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }
}

extension MarketScreen {
    /// A market named by a push: wait for the list if it is still loading, then open it.
    fileprivate func openRequestedMarket() async {
        guard let symbol = MarketOpenRequest.shared.take() else { return }
        for _ in 0..<40 where market.allMarkets.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
        guard let found = market.allMarkets.first(where: { $0.symbol.caseInsensitiveCompare(symbol) == .orderedSame }) else { return }
        market.select(found)
        await session.selectMarket(found)
        showsMarket = true
    }
}
