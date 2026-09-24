import DeskPerpl
import DeskMoney
import DeskUI
import SwiftUI

/// The Home tab: what the room is doing, then every market, then who is doing it.
///
/// Ordered by what a person opening the app wants first: the markets traders are
/// crowding into, the full list, and the traders worth following. Their own positions
/// live on Profile. All of it is read from Perpl through Desk's server; nothing here is
/// a table of invented figures.
struct MarketScreen: View {
    private enum Shelf: String, CaseIterable, Identifiable {
        case perps = "Perps", trending = "Trending", watchlist = "Watchlist"
        var id: String { rawValue }
    }

    let model: AppModel
    let market: MarketModel
    let session: TradingSession
    let copier: CopyTrader
    let onOrderFilled: (Direction, String) -> Void
    var onOpenTraders: () -> Void = {}
    var onFund: () -> Void = {}

    @State fileprivate var showsMarket = false
    @State private var shelf: Shelf = .perps
    @State private var selectedTrader: TraderSnapshot?
    @State private var openToken: TokenOpenRequest.Target?
    @State private var directory = TraderDirectory()
    @State private var news = NewsModel()
    @State private var article: NewsItem?
    @StateObject private var discovery = TokenDiscoveryModel()
    @AppStorage("desk.watchlist") private var savedIDs = ""
    @AppStorage("desk.spotWatchlist") private var savedSpotData = ""

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()
                DeskAurora().ignoresSafeArea()

                // Each section pads itself so the hot-markets strip can run edge to edge
                // without widening the page — a negative padding did, and the whole
                // screen could then be dragged sideways.
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        header.padding(.horizontal, 16)
                        if !Self.tradersOnly {
                            hotMarkets.padding(.top, 34)
                            explore.padding(.top, 32).padding(.horizontal, 16)
                        }
                        if !Self.newsOnly {
                            liveTrades.padding(.top, 32).padding(.horizontal, 16)
                            topTraders.padding(.top, 32).padding(.horizontal, 16)
                        }
                        newsSection.padding(.top, 32).padding(.horizontal, 16)
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 116)
                }
                .refreshable {
                    async let markets: Void = market.refreshNow()
                    async let top: Void = directory.refreshTop()
                    async let crowd: Void = directory.refreshCrowd()
                    async let spot: Void = discovery.refresh()
                    async let headlines: Void = news.load()
                    _ = await (markets, top, crowd, spot, headlines)
                }
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
            .navigationDestination(item: $selectedTrader) { trader in
                TraderProfileScreen(initial: trader, directory: directory, copier: copier) { position in
                    selectedTrader = nil
                    open(symbol: position.market)
                }
                .toolbar(.hidden, for: .tabBar)
            }
            .navigationDestination(item: $openToken) { target in
                SpotTokenPage(target: target, model: model)
                    .toolbar(.hidden, for: .tabBar)
            }
            .task { await directory.run() }
            .task { await discovery.run() }
            .task { await news.run() }
            .sheet(item: $article) { item in
                if let link = item.link { InAppSafari(url: link).ignoresSafeArea() }
            }
            .task { await openRequestedMarket() }
            .onChange(of: MarketOpenRequest.shared.pending) { _, symbol in if symbol != nil { Task { await openRequestedMarket() } } }
            #if DEBUG
            .task { if ProcessInfo.processInfo.arguments.contains("-price-demo") { MarketOpenRequest.shared.open("ETH") } }
            .task { if ProcessInfo.processInfo.arguments.contains("-crowd-demo") { directory.seedCrowdForReview() } }
            .task {
                guard ProcessInfo.processInfo.arguments.contains("-open-ticket") else { return }
                while market.allMarkets.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
                guard let first = market.allMarkets.first else { return }
                market.select(first)
                await session.selectMarket(first)
                showsMarket = true
            }
            #endif
        }
    }

    /// `-trade-traders` and `-trade-news` show a lower section first, so it can be captured without a scroll.
    private static var tradersOnly: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-trade-traders") || newsOnly
        #else
        false
        #endif
    }

    private static var newsOnly: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-trade-news")
        #else
        false
        #endif
    }

    // MARK: Header

    /// The mark, then the one figure a trader checks before every order.
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            DeskBrandMark(size: 28)
                .frame(height: 36, alignment: .leading)
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    if model.hasTradingAccount {
                        AmountText(model.collateral.value.map { DisplayCurrency.shared.format($0) } ?? Unavailable.text, size: 34)
                        Text("AUSD available to trade")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(DeskColor.nightMuted.color)
                    } else {
                        Text("No desk yet")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(DeskColor.nightText.color)
                        Text("Fund it to trade on Perpl")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(DeskColor.nightMuted.color)
                    }
                }
                Spacer(minLength: 8)
                Button(action: onFund) {
                    Text(model.hasTradingAccount ? "Add funds" : "Open desk")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(DeskColor.night.color)
                        .padding(.horizontal, 16)
                        .frame(height: 38)
                        .background(DeskColor.nightText.color, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Hot markets

    /// Markets ranked by the money traders have open in them, with the lean of the crowd.
    private var hotCrowd: [MarketCrowd] {
        directory.crowd
            .filter { crowd in market.allMarkets.contains { $0.symbol == crowd.market } }
            .sorted { $0.total > $1.total }
            .prefix(6)
            .map { $0 }
    }

    private var hotMarkets: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                sectionTitle("Hot Markets")
                Text("Based on trader activity")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
            .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    if hotCrowd.isEmpty {
                        ForEach(0..<2, id: \.self) { _ in hotPlaceholder }
                    } else {
                        ForEach(hotCrowd) { crowd in
                            if let listed = market.allMarkets.first(where: { $0.symbol == crowd.market }) {
                                Button { open(listed) } label: { HotMarketCard(crowd: crowd, market: listed, model: market) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var hotPlaceholder: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color.white.opacity(0.05))
            .frame(width: 250, height: 104)
    }

    // MARK: Explore

    private var savedMarketIDs: Set<UInt32> { Set(savedIDs.split(separator: ",").compactMap { UInt32($0) }) }

    private var explore: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Explore Markets")
            HStack(spacing: 8) {
                ForEach(Shelf.allCases) { item in
                    Button {
                        UISelectionFeedbackGenerator().selectionChanged()
                        withAnimation(.snappy(duration: 0.2)) { shelf = item }
                    } label: {
                        Text(item.rawValue)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(shelf == item ? DeskColor.night.color : DeskColor.nightText.color)
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                            .background(shelf == item ? DeskColor.nightText.color : Color.white.opacity(0.08), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            switch shelf {
            case .perps: perpRows(market.allMarkets)
            case .trending: trendingRows
            case .watchlist: watchlistRows
            }
        }
    }

    @ViewBuilder
    private func perpRows(_ markets: [Market]) -> some View {
        if markets.isEmpty {
            placeholderRows(3)
        } else {
            VStack(spacing: 0) {
                ForEach(markets, id: \.id) { item in
                    Button { open(item) } label: { PerpMarketRow(market: item, model: market) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var trendingRows: some View {
        if discovery.trending.isEmpty {
            placeholderRows(3)
        } else {
            VStack(spacing: 8) {
                ForEach(discovery.trending.prefix(8)) { token in
                    Button { openToken = .init(chainIndex: token.chainIndex, contract: token.contract, symbol: token.symbol) } label: {
                        TrendingSpotRow(token: token)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var watchlistRows: some View {
        let perps = market.allMarkets.filter { savedMarketIDs.contains($0.id) }
        let spot = SpotWatchlistStorage.decode(savedSpotData)
        if perps.isEmpty && spot.isEmpty {
            Text("Star a market to keep it here.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(DeskColor.nightMuted.color)
                .frame(maxWidth: .infinity, minHeight: 88)
        } else {
            VStack(spacing: 8) {
                if !perps.isEmpty { perpRows(perps) }
                ForEach(spot) { token in
                    Button { openToken = .init(chainIndex: token.chainIndex, contract: token.contract, symbol: token.symbol) } label: {
                        TrendingSpotRow(token: token)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func placeholderRows(_ count: Int) -> some View {
        VStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .frame(height: 54)
            }
        }
    }

    // MARK: Traders

    /// Each top trader's largest open position, in leaderboard order.
    private var liveRows: [(trader: TraderSnapshot, position: TraderPosition)] {
        directory.top.compactMap { trader in
            trader.positions.max { (Double($0.value) ?? 0) < (Double($1.value) ?? 0) }.map { (trader, $0) }
        }
        .prefix(5).map { $0 }
    }

    private var liveTrades: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLink("Live Trades", action: onOpenTraders)
            Text("Top traders' open positions")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(DeskColor.nightMuted.color)
            if liveRows.isEmpty {
                placeholderRows(3).padding(.top, 10)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(liveRows.enumerated()), id: \.element.trader.id) { index, row in
                        Button { selectedTrader = row.trader } label: {
                            LiveTradeRow(trader: row.trader, position: row.position,
                                         name: directory.name(for: row.trader.address),
                                         record: directory.records[row.trader.id],
                                         isLast: index == liveRows.count - 1)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private var topTraders: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLink("Top Traders", action: onOpenTraders)
            if directory.top.isEmpty {
                placeholderRows(3).padding(.top, 10)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(directory.top.prefix(5).enumerated()), id: \.element.id) { index, trader in
                        Button { selectedTrader = trader } label: {
                            TopTraderRow(trader: trader, rank: index + 1,
                                         name: directory.name(for: trader.address),
                                         record: directory.records[trader.id],
                                         isFollowed: directory.isFollowing(trader.address),
                                         isLast: index == min(directory.top.count, 5) - 1)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    // MARK: News

    private var newsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("News")
            if news.items.isEmpty {
                placeholderRows(news.loaded ? 0 : 3).padding(.top, 10)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(news.items.prefix(8).enumerated()), id: \.element.id) { index, item in
                        Button { article = item } label: {
                            NewsRow(item: item, market: market, isLast: index == min(news.items.count, 8) - 1)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: Pieces

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 18, weight: .bold, design: .rounded))
            .foregroundStyle(DeskColor.nightText.color)
    }

    private func sectionLink(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                sectionTitle(text)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func open(_ item: Market) {
        market.select(item)
        Task {
            await session.selectMarket(item)
            showsMarket = true
        }
    }

    private func open(symbol: String) {
        guard let found = market.allMarkets.first(where: { $0.symbol.caseInsensitiveCompare(symbol) == .orderedSame }) else { return }
        open(found)
    }
}

/// One market the crowd is in: what it costs, how many are in, which way they lean.
private struct HotMarketCard: View {
    let crowd: MarketCrowd
    let market: Market
    let model: MarketModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                MarketTokenLogo(symbol: market.symbol, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(market.symbol)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                    Text("\(TraderFormat.compact(crowd.total)) open")
                        .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(DeskColor.nightMuted.color)
                }
                Spacer(minLength: 8)
                if let change = model.changePercent(for: market) {
                    Text(String(format: "%+.2f%%", change))
                        .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(change >= 0 ? DeskColor.rise.color : DeskColor.fall.color)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background((change >= 0 ? DeskColor.rise : DeskColor.fall).color.opacity(0.14), in: Capsule())
                }
            }
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5).padding(.vertical, 10)
            HStack(spacing: 6) {
                Circle().fill(DeskColor.rise.color).frame(width: 5, height: 5)
                Text("**\(crowd.traders)** \(crowd.traders == 1 ? "trader" : "traders")")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
                if let share = crowd.longShare {
                    let percent = Int((max(share, 1 - share) * 100).rounded())
                    Text(percent == 50 ? "· split evenly" : "· \(percent)% \(share >= 0.5 ? "long" : "short")")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                }
                Spacer(minLength: 4)
                if let biggest = crowd.biggest?.address {
                    TraderAvatar(address: biggest, size: 22)
                }
            }
        }
        .padding(14)
        .frame(width: 250)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.07), lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// A perp in the list: leverage and the day's volume on the left, price and change on the right.
private struct PerpMarketRow: View {
    let market: Market
    let model: MarketModel

    private var volume: String {
        let value = Double(market.state.dailyVolumeRaw) / 1_000_000
        return value > 0 ? "\(TraderFormat.compact(value)) Vol" : "—"
    }

    var body: some View {
        HStack(spacing: 12) {
            MarketTokenLogo(symbol: market.symbol, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(market.symbol)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                    Text("\(market.config.maxLeverage)x")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                Text(volume)
                    .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                let price = model.markText(for: market)
                Text(price == "—" ? "—" : "$" + price)
                    .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(DeskColor.nightText.color)
                    .contentTransition(.numericText())
                let change = model.changePercent(for: market)
                Text(change.map { String(format: "%+.2f%%", $0) } ?? "—")
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle((change ?? 0) >= 0 ? DeskColor.rise.color : DeskColor.fall.color)
            }
        }
        .frame(height: 56)
        .contentShape(Rectangle())
    }
}

/// A top trader's largest position, with their record when history has one.
private struct LiveTradeRow: View {
    let trader: TraderSnapshot
    let position: TraderPosition
    let name: String
    let record: TraderRecord?
    let isLast: Bool

    var body: some View {
        HStack(spacing: 12) {
            TraderAvatar(address: trader.address, size: 36)
                .overlay(alignment: .bottomTrailing) {
                    MarketTokenLogo(symbol: position.market, size: 16)
                        .overlay(Circle().stroke(Color.black, lineWidth: 2))
                        .offset(x: 3, y: 3)
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(position.market)
                        .foregroundStyle(DeskColor.nightText.color.opacity(0.85))
                    Text("\(TraderFormat.leverage(position.leverage)) \(position.isLong ? "Long" : "Short") · \(TraderFormat.compact(Double(position.value)))")
                        .foregroundStyle(DeskColor.nightMuted.color)
                }
                .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if let rate = record?.winRate {
                    Text("\(Int((rate * 100).rounded()))%")
                        .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(rate >= 0.6 ? DeskColor.rise.color : DeskColor.nightText.color)
                    Text("Win rate")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                } else {
                    Text(TraderFormat.compact(Double(position.pnl), signed: true))
                        .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle((position.isProfit ? DeskColor.rise : DeskColor.fall).color)
                    Text("Open PnL")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                }
            }
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            if !isLast { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5).padding(.leading, 48) }
        }
        .contentShape(Rectangle())
    }
}

private struct TopTraderRow: View {
    let trader: TraderSnapshot
    let rank: Int
    let name: String
    let record: TraderRecord?
    let isFollowed: Bool
    let isLast: Bool

    private var detail: String {
        var parts: [String] = []
        if let score = record?.score { parts.append("Score \(score)") }
        let count = trader.positions.count
        parts.append("\(count) \(count == 1 ? "position" : "positions")")
        return parts.joined(separator: " · ")
    }

    /// Open PnL against what the trader has at stake.
    private var returnText: String? {
        guard let pnl = trader.pnl.flatMap(Double.init), let portfolio = trader.portfolio, portfolio - pnl > 0 else { return nil }
        return String(format: "%+.0f%%", pnl / (portfolio - pnl) * 100)
    }

    var body: some View {
        HStack(spacing: 12) {
            TraderAvatar(address: trader.address, size: 36)
                .overlay(alignment: .bottomTrailing) {
                    if rank <= 3 {
                        Text("\(rank)")
                            .font(.system(size: 9, weight: .heavy, design: .rounded))
                            .foregroundStyle(DeskColor.night.color)
                            .frame(width: 15, height: 15)
                            .background(DeskColor.action.color, in: Circle())
                            .overlay(Circle().stroke(Color.black, lineWidth: 2))
                            .offset(x: 3, y: 3)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                        .lineLimit(1)
                    if isFollowed {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(DeskColor.nightMuted.color)
                    }
                }
                Text(detail)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(TraderFormat.compact(trader.pnl.flatMap(Double.init), signed: true))
                    .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle((trader.isProfit ? DeskColor.rise : DeskColor.fall).color)
                if let returnText {
                    Text(returnText)
                        .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(DeskColor.nightMuted.color)
                }
            }
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            if !isLast { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5).padding(.leading, 48) }
        }
        .contentShape(Rectangle())
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
    @State private var chat = MarketChatModel()
    @State private var showsChat = false
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
                    MarketChatPreview(chat: chat) { showsChat = true }.padding(.top, 26)
                    tabs.padding(.top, 26)
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
        .task(id: market.symbol) { await chat.run(symbol: market.symbol) }
        .task { await directory.refreshFollowing() }
        .task {
            #if DEBUG
            // The ticket sits behind a floating bar that UI automation cannot hit, so it
            // gets the same way in that `-stage` gives every other screen.
            if ProcessInfo.processInfo.arguments.contains("-open-ticket") { ticket = .up }
            if ProcessInfo.processInfo.arguments.contains("-open-chat") { showsChat = true }
            #endif
        }
        .sheet(isPresented: $showsChat) {
            MarketChatSheet(chat: chat, market: market, holders: holders, model: model) { showsChat = false }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
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
        TradeAlerts.shared.watchlistChanged()
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
