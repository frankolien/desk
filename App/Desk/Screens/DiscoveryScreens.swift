import DeskMoney
import DeskPerpl
import DeskUI
import Combine
import Foundation
import SwiftUI

/// Watchlist and Search, over the markets the venue actually lists.
///
/// Both screens previously rendered a hard-coded table: five instruments with typed-in
/// prices, invented percentage changes, and a wallet list carrying figures like
/// "+$3.43M" and "186 trades" belonging to nobody. Two of the five markets do not exist
/// on Perpl at all, and the leverage cap shown for Bitcoin was 40× against a real ceiling
/// of 15×. In an app whose whole argument is that it never shows a number it cannot
/// stand behind, that was the most dishonest surface in it.
///
/// Nothing needed inventing. The context call the price already makes lists every open
/// market with its own mark and its own margin fractions, so these render seven real
/// instruments at real prices — and say plainly which of them can be traded here.
///
/// The wallet list is gone rather than rebuilt. It needed account identities, and Perpl's
/// public feed carries none; the same reason `SignalsScreen` reads the market rather than
/// the crowd.

// MARK: - Watchlist

struct WatchlistScreen: View {
    let model: AppModel
    let market: MarketModel
    let session: TradingSession
    @State private var showsMarket = false
    /// Saved locally. A watchlist is the user's own note about markets, it never needs to
    /// leave the phone, and the list is short enough that defaults are the right home.
    @AppStorage("desk.watchlist") private var savedIDs = ""

    private var saved: Set<UInt32> {
        Set(savedIDs.split(separator: ",").compactMap { UInt32($0) })
    }

    private var rows: [Market] {
        market.allMarkets.filter { saved.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                DeskBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Watchlist")
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                        .padding(.top, 10)

                    Text(rows.isEmpty
                         ? "Markets you save from Search appear here."
                         : "\(rows.count) market\(rows.count == 1 ? "" : "s") saved.")
                        .font(DeskType.caption)
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .padding(.top, 6)

                    if rows.isEmpty {
                        empty.padding(.top, 40)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(rows, id: \.id) { entry in
                                MarketRow(
                                    model: market,
                                    market: entry,
                                    isSaved: true,
                                    onOpen: { open(entry) },
                                    onToggle: { toggle(entry.id) })
                            }
                        }
                        .padding(.top, 20)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 190)
            }
            .deskSoftBottomEdge()
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showsMarket) {
                PerpDetailScreen(model: model, market: market, session: session)
                    .toolbar(.hidden, for: .tabBar)
            }
        }
    }

    /// Nothing saved is not an error, and it is not an empty void either — it names the
    /// one action that fills it.
    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "bookmark")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(DeskColor.nightMuted.color)
            Text("Nothing saved yet")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(DeskColor.nightText.color)
            Text("Open Search and tap the bookmark on any market.")
                .font(DeskType.caption)
                .foregroundStyle(DeskColor.nightMuted.color)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    private func toggle(_ id: UInt32) {
        var next = saved
        if next.contains(id) { next.remove(id) } else { next.insert(id) }
        // Sorted so the stored string is stable: an unordered set would rewrite the
        // defaults value on every toggle even when the membership had not changed.
        savedIDs = next.sorted().map(String.init).joined(separator: ",")
    }

    private func open(_ entry: Market) {
        market.select(entry)
        Task { await session.selectMarket(entry) }
        showsMarket = true
    }
}

// MARK: - Search

struct MarketSearchScreen: View {
    let model: AppModel
    let market: MarketModel
    let session: TradingSession
    @State private var query = ""
    @State private var showsMarket = false
    @State private var selectedSpot: TrendingSpotToken?
    @StateObject private var discovery = TokenDiscoveryModel()
    @AppStorage("desk.watchlist") private var savedIDs = ""

    private var saved: Set<UInt32> {
        Set(savedIDs.split(separator: ",").compactMap { UInt32($0) })
    }

    private var results: [Market] {
        guard !query.isEmpty else { return market.allMarkets }
        return market.allMarkets.filter {
            $0.symbol.localizedCaseInsensitiveContains(query)
        }
    }

    private var spotResults: [TrendingSpotToken] {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? discovery.trending : discovery.searchResults
    }

    var body: some View {
        NavigationStack {
            ZStack {
                DeskBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Search")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 10)

                    Text("Perp Cards")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                        .padding(.top, 32)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(Array(market.allMarkets.prefix(4)), id: \.id) { entry in
                                Button { open(entry) } label: {
                                    SearchMarketCard(model: market, market: entry)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .contentMargins(.horizontal, 0)
                    .padding(.top, 12)

                    HStack {
                        Text("All Perpl Markets")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                        Spacer()
                        Text("\(market.allMarkets.count) live")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(DeskColor.nightMuted.color)
                    }
                    .foregroundStyle(DeskColor.nightText.color)
                    .padding(.top, 30)

                    field.padding(.top, 12)

                    if !spotResults.isEmpty {
                        HStack {
                            Text(query.isEmpty ? "Trending coins" : "Coins")
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                            Spacer()
                            Text("SPOT PREVIEW")
                                .font(.system(size: 10, weight: .heavy, design: .rounded))
                                .foregroundStyle(DeskColor.nightMuted.color)
                                .tracking(1.2)
                        }
                        .foregroundStyle(DeskColor.nightText.color)
                        .padding(.top, 26)

                        VStack(spacing: 10) {
                            ForEach(spotResults) { token in
                                Button { selectedSpot = token } label: {
                                    TrendingSpotRow(token: token)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.top, 12)
                    } else if discovery.isLoading {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(query.isEmpty ? "Finding what’s moving…" : "Searching across networks…")
                        }
                        .font(DeskType.caption)
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                    } else if let error = discovery.errorText {
                        ContentUnavailableView("Discovery unavailable", systemImage: "wifi.exclamationmark", description: Text(error))
                            .frame(minHeight: 150)
                    }

                    if market.allMarkets.isEmpty {
                        // Still loading the context. Skeletons rather than "no results",
                        // which would be a claim about the venue.
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(0..<4, id: \.self) { SkeletonRow(widthFraction: 0.8 - Double($0) * 0.1) }
                        }
                        .padding(.top, 28)
                    } else if results.isEmpty {
                        Text("No market matches “\(query)”.")
                            .font(DeskType.caption)
                            .foregroundStyle(DeskColor.nightMuted.color)
                            .padding(.top, 28)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(results, id: \.id) { entry in
                                MarketRow(
                                    model: market,
                                    market: entry,
                                    isSaved: saved.contains(entry.id),
                                    onOpen: { open(entry) },
                                    onToggle: { toggle(entry.id) })
                            }
                        }
                        .padding(.top, 20)
                    }

                    Text("Perpl testnet currently exposes these seven perpetual markets. "
                         + "Discovery tokens from other networks are separate from tradeable Perpl contracts.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 24)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 130)
            }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showsMarket) {
                PerpDetailScreen(model: model, market: market, session: session)
                    .toolbar(.hidden, for: .tabBar)
            }
            .navigationDestination(item: $selectedSpot) { token in
                SpotTokenDetailScreen(token: token)
                    .toolbar(.hidden, for: .tabBar)
            }
            .task { await discovery.run() }
            .task(id: query) { await discovery.search(query) }
        }
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DeskColor.nightMuted.color)
            TextField("", text: $query, prompt: Text("Search markets")
                .foregroundStyle(DeskColor.nightMuted.color))
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(DeskColor.nightText.color)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DeskColor.nightMuted.color)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(DeskColor.nightChip.color.opacity(0.6), in: Capsule())
        .overlay(Capsule().stroke(DeskColor.nightLine.color, lineWidth: 0.5))
    }

    private func toggle(_ id: UInt32) {
        var next = saved
        if next.contains(id) { next.remove(id) } else { next.insert(id) }
        // Sorted so the stored string is stable: an unordered set would rewrite the
        // defaults value on every toggle even when the membership had not changed.
        savedIDs = next.sorted().map(String.init).joined(separator: ",")
    }

    private func open(_ entry: Market) {
        market.select(entry)
        Task { await session.selectMarket(entry) }
        showsMarket = true
    }
}

// MARK: - Spot discovery

private struct TrendingSpotToken: Identifiable, Hashable, Decodable {
    let id: String
    let chainIndex: String
    let chainName: String
    let symbol: String
    let name: String
    let logoURL: String
    let contract: String
    let explorerURL: String
    let price: Double?
    let change: Double?
    let marketCap: Double?
    let volume24H: Double?
    let liquidity: Double?
    let holders: Double?
    let communityRecognized: Bool?
    let riskLevel: String?

    var artworkURL: URL? { URL(string: logoURL) }
}

@MainActor
private final class TokenDiscoveryModel: ObservableObject {
    private struct Response: Decodable { let tokens: [TrendingSpotToken] }
    @Published private(set) var trending: [TrendingSpotToken] = []
    @Published private(set) var searchResults: [TrendingSpotToken] = []
    @Published private(set) var isLoading = true
    @Published private(set) var errorText: String?
    private var latestQuery = ""

    func run() async {
        while !Task.isCancelled {
            await load(query: "", intoSearch: false)
            try? await Task.sleep(for: .seconds(30))
        }
    }

    func search(_ raw: String) async {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        latestQuery = query
        guard !query.isEmpty else { searchResults = []; return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled, latestQuery == query else { return }
        await load(query: query, intoSearch: true)
    }

    private func load(query: String, intoSearch: Bool) async {
        isLoading = (intoSearch ? searchResults : trending).isEmpty
        if isLoading { errorText = nil }
        var components = URLComponents(string: "https://web-lovat-nine-49.vercel.app/api/token-discovery")!
        if !query.isEmpty { components.queryItems = [URLQueryItem(name: "q", value: query)] }
        do {
            let (data, response) = try await URLSession.shared.data(from: components.url!)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let tokens = try JSONDecoder().decode(Response.self, from: data).tokens
            guard !intoSearch || latestQuery == query else { return }
            if intoSearch { searchResults = tokens } else { trending = tokens }
            errorText = nil
        } catch {
            if (intoSearch ? searchResults : trending).isEmpty {
                errorText = "Live token data could not be loaded. Pull back and try again."
            }
        }
        isLoading = false
    }
}

private struct TrendingSpotRow: View {
    let token: TrendingSpotToken

    var body: some View {
        HStack(spacing: 13) {
            MarketTokenLogo(symbol: token.symbol, size: 42, remoteURL: token.artworkURL)
            VStack(alignment: .leading, spacing: 3) {
                Text(token.name)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
                HStack(spacing: 7) {
                    Text(token.symbol)
                    Text(token.chainName)
                    if let change = token.change {
                        Text(String(format: "%+.2f%%", change))
                            .foregroundStyle(change >= 0 ? DeskColor.rise.color : DeskColor.fall.color)
                    }
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(DeskColor.nightMuted.color)
            }
            Spacer()
            Text(token.price.map(spotPrice) ?? "$—")
                .font(.system(size: 15, weight: .bold).monospacedDigit())
                .foregroundStyle(DeskColor.nightText.color)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(DeskColor.nightMuted.color)
        }
        .padding(.horizontal, 14)
        .frame(height: 76)
        .background { TokenAdaptiveCardBackground(symbol: token.symbol, cornerRadius: 18, artworkURL: token.artworkURL) }
    }
}

private func spotPrice(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "USD"
    formatter.currencySymbol = "$"
    formatter.usesGroupingSeparator = true
    formatter.minimumFractionDigits = value >= 1 ? 2 : 4
    formatter.maximumFractionDigits = value >= 100 ? 2 : (value >= 1 ? 4 : 8)
    return formatter.string(from: NSNumber(value: value)) ?? "$—"
}

// MARK: - One market

/// A market as the venue reports it: its own price, its own leverage ceiling.
///
/// The leverage figure comes from `initialMarginFraction`, which the venue encodes as a
/// divisor in hundredths — 1500 is 15×, not 15%. The hard-coded version of this screen
/// claimed 40× for Bitcoin, which is not a number Perpl would accept.
private struct MarketRow: View {
    let model: MarketModel
    let market: Market
    let isSaved: Bool
    let onOpen: () -> Void
    let onToggle: () -> Void

    private var price: String {
        let value = model.markText(for: market)
        return value == "—" ? value : "$" + value
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onOpen) {
                HStack(spacing: 13) {
                    MarketTokenLogo(symbol: market.symbol, size: 38)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(market.symbol)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)

                    Text("MAX \(market.config.maxLeverage)×")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(Capsule().stroke(DeskColor.nightLine.color, lineWidth: 0.7))
                }

                Text("Tradeable on Perpl")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(DeskColor.rise.color)
            }

                    Spacer(minLength: 8)

                    Text(price)
                        .font(.system(size: 15, weight: .bold).monospacedDigit())
                        .foregroundStyle(DeskColor.nightText.color)
                        .contentTransition(.numericText())
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onToggle) {
                Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isSaved ? DeskColor.action.color : DeskColor.nightMuted.color)
                    .frame(width: 34, height: 34)
            }
            .accessibilityLabel(isSaved ? "Remove \(market.symbol) from watchlist"
                                        : "Save \(market.symbol) to watchlist")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(DeskColor.nightChip.color.opacity(0.5),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(DeskColor.nightLine.color, lineWidth: 0.5))
    }

    /// A colour per symbol so rows are told apart before they are read. Derived from the
    /// symbol rather than kept in a table, so a market the venue adds still gets one.
    static func tint(for symbol: String) -> Color {
        let seed = AddressAvatar.seed(for: symbol)
        return Color(hue: seed.primary / 360, saturation: 0.55, brightness: 0.85)
    }
}

private struct SearchMarketCard: View {
    let model: MarketModel
    let market: Market

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                MarketTokenLogo(symbol: market.symbol, size: 44)
                Spacer()
                if let change = model.changePercent(for: market) {
                    Text(String(format: "%+.2f%%", change))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(change >= 0 ? DeskColor.rise.color : DeskColor.fall.color)
                }
            }
            Spacer()
            Text(market.symbol)
                .font(.system(size: 21, weight: .bold, design: .rounded))
            HStack {
                let price = model.markText(for: market)
                Text(price == "—" ? price : "$" + price)
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .lineLimit(1).minimumScaleFactor(0.72)
                Spacer()
                Text("MAX \(market.config.maxLeverage)×")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .overlay(Capsule().stroke(Color.white.opacity(0.16)))
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(DeskColor.nightText.color)
        .padding(16)
        .frame(width: 188, height: 190)
        .background { TokenAdaptiveCardBackground(symbol: market.symbol, cornerRadius: 25) }
        .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
    }
}

private extension View {
    @ViewBuilder
    func perpSearchGlass<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) { glassEffect(.regular, in: shape) }
        else { background(.ultraThinMaterial, in: shape) }
    }

    @ViewBuilder
    func deskSoftBottomEdge() -> some View {
        if #available(iOS 26.0, *) { scrollEdgeEffectStyle(.soft, for: .bottom) }
        else { self }
    }
}

private enum SpotDetailTab: String, CaseIterable, Identifiable {
    case transactions = "Transactions", holders = "Holders", orders = "Order Book", info = "Info"
    var id: Self { self }
}

private struct SpotWallet: Identifiable, Hashable {
    let address: String
    let emoji: String
    let portfolio: String
    var id: String { address }
    var displayAddress: String {
        guard address.count > 13 else { return address }
        return "\(address.prefix(6))…\(address.suffix(5))"
    }
}

private struct SpotTransaction: Identifiable {
    let age: String
    let isBuy: Bool
    let amount: String
    let value: String
    let wallet: SpotWallet
    var id: String { age + amount + wallet.address }
}

private struct SpotTokenDetailScreen: View {
    let token: TrendingSpotToken
    @StateObject private var feed: SpotLiveFeed
    @Environment(\.dismiss) private var dismiss
    @State private var tab: SpotDetailTab = .transactions
    @State private var range = "1H"
    @State private var selectedWallet: SpotWallet?
    @State private var tradeSide: String?

    init(token: TrendingSpotToken) {
        self.token = token
        _feed = StateObject(wrappedValue: SpotLiveFeed(symbol: token.symbol))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    chart
                    ranges
                    Divider().overlay(Color.white.opacity(0.12)).padding(.top, 10)
                    tabs
                    tabContent.padding(.top, 16)
                }
                .padding(.bottom, 120)
            }
            tradeBar.padding(.horizontal, 20).padding(.bottom, 12)
        }
        .toolbar(.hidden, for: .navigationBar)
        .task { await feed.run(period: range) }
        .onChange(of: range) { _, newValue in feed.changePeriod(newValue) }
        .navigationDestination(item: $selectedWallet) { wallet in
            WalletProfileScreen(wallet: wallet)
                .toolbar(.hidden, for: .tabBar)
        }
        .sheet(isPresented: Binding(
            get: { tradeSide != nil },
            set: { if !$0 { tradeSide = nil } }
        )) {
            SpotTradePreview(token: token, side: tradeSide ?? "Buy")
                .presentationDetents([.height(330)])
                .presentationDragIndicator(.visible)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .bold)).frame(width: 48, height: 48)
                }
                .perpSearchGlass(in: Circle())
                Spacer()
                ShareLink(item: "\(token.name) (\(token.symbol))") {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 17, weight: .semibold)).frame(width: 48, height: 48)
                }
                .perpSearchGlass(in: Circle())
            }
            .foregroundStyle(.white)

            HStack(spacing: 12) {
                MarketTokenLogo(symbol: token.symbol, size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(token.name).font(.system(size: 18, weight: .bold, design: .rounded))
                    Text(token.symbol).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .firstTextBaseline) {
                Text(spotPrice(feed.latestPrice ?? token.price))
                    .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                    .minimumScaleFactor(0.7)
                Spacer()
                Text("SPOT")
                    .font(.system(size: 11, weight: .heavy, design: .rounded)).tracking(1)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .perpSearchGlass(in: Capsule())
            }
            Text(changeStatusText)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(feed.changePercent == nil ? Color.secondary : (feed.isUp ? DeskColor.rise.color : DeskColor.fall.color))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private var chart: some View {
        SpotCandlestickChart(isUp: feed.isUp, seed: token.symbol, values: feed.candles)
            .frame(height: 330)
            .padding(.top, 18)
    }

    private var changeStatusText: String {
        guard let change = feed.changePercent else { return "—  ·  \(feed.stateText)" }
        return String(format: "%@ %.2f%%  ·  %@", change >= 0 ? "↑" : "↓", abs(change), feed.stateText)
    }

    private var ranges: some View {
        HStack(spacing: 0) {
            ForEach(["LIVE", "1m", "5m", "15m", "1H", "4H"], id: \.self) { item in
                Button { withAnimation(.easeOut(duration: 0.18)) { range = item } } label: {
                    Text(item).font(.system(size: 14, weight: .heavy, design: .rounded))
                        .foregroundStyle(range == item ? .white : .secondary)
                        .frame(maxWidth: .infinity).frame(height: 42)
                        .background(range == item ? Color.white.opacity(0.12) : .clear, in: Capsule())
                }.buttonStyle(.plain)
            }
        }.padding(.horizontal, 14)
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(SpotDetailTab.allCases) { item in
                Button { withAnimation(.easeOut(duration: 0.18)) { tab = item } } label: {
                    Text(item.rawValue).font(.system(size: 13, weight: tab == item ? .bold : .medium, design: .rounded))
                        .foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 36)
                        .background(tab == item ? Color.white.opacity(0.24) : .clear, in: Capsule())
                }.buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.11), in: Capsule())
        .padding(.horizontal, 16).padding(.top, 10)
    }

    @ViewBuilder private var tabContent: some View {
        switch tab {
        case .transactions: transactionList
        case .holders: holderList
        case .orders: orderBook
        case .info: info
        }
    }

    private var transactionList: some View {
        VStack(spacing: 0) {
            HStack { Text("TX"); Spacer(); Text("Amount"); Spacer(); Text("Wallet") }
                .font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.bottom, 8)
            if feed.transactions.isEmpty {
                HStack(spacing: 10) {
                    if feed.isLoading { ProgressView() }
                    Text(feed.errorText ?? "Waiting for the next on-chain trade…")
                }
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 34)
            }
            ForEach(feed.transactions) { tx in
                HStack {
                    Text(tx.age).frame(width: 42, alignment: .leading)
                    Text(tx.isBuy ? "BUY" : "SELL")
                        .font(.system(size: 11, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(tx.isBuy ? DeskColor.rise.color : DeskColor.fall.color, in: Capsule())
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(tx.amount).foregroundStyle(tx.isBuy ? DeskColor.rise.color : DeskColor.fall.color)
                        Text(tx.value).font(.caption).foregroundStyle(.secondary)
                    }
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .frame(width: 115, alignment: .trailing)
                    Button { selectedWallet = tx.wallet } label: {
                        HStack(spacing: 6) { Text(tx.wallet.emoji); Text(tx.wallet.displayAddress).underline() }
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }.foregroundStyle(.secondary).frame(width: 130, alignment: .trailing)
                }
                .padding(.horizontal, 20).frame(height: 66)
                Divider().overlay(Color.white.opacity(0.1)).padding(.leading, 20)
            }
            Text("Real on-chain trades · refreshes every 2 seconds while open")
                .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 16)
        }
    }

    private var holderList: some View {
        VStack(spacing: 0) {
            HStack { Text("#   Wallet"); Spacer(); Text(token.symbol); Text("Value").frame(width: 92, alignment: .trailing); Text("%").frame(width: 48, alignment: .trailing) }
                .font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.secondary).padding(.horizontal, 20)
            if feed.holders.isEmpty {
                ContentUnavailableView(
                    "Holder data unavailable",
                    systemImage: "person.2.slash",
                    description: Text(feed.detailsError ?? "OKX returned no holder distribution for this token contract.")
                )
                .frame(minHeight: 220)
            }
            ForEach(Array(feed.holders.enumerated()), id: \.element.id) { index, holder in
                HStack {
                    Text("\(index + 1)").foregroundStyle(.secondary).frame(width: 20)
                    Button { selectedWallet = holder.wallet } label: {
                        HStack { Text(holder.wallet.emoji); Text(holder.wallet.displayAddress).underline() }
                    }.foregroundStyle(.secondary)
                    Spacer()
                    Text(holder.amount)
                    Text(holder.value).foregroundStyle(.secondary).frame(width: 92, alignment: .trailing)
                    Text(holder.percent).foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
                }.font(.system(size: 13, weight: .semibold, design: .rounded)).padding(.horizontal, 20).frame(height: 68)
                Divider().overlay(Color.white.opacity(0.1)).padding(.leading, 20)
            }
            if !feed.holders.isEmpty { liveCaption("OKX holder snapshot · refreshed every 30 seconds") }
        }
    }

    private var orderBook: some View {
        ContentUnavailableView(
            "No verified orders",
            systemImage: "list.bullet.rectangle",
            description: Text("This token’s active DCA order feed is not connected yet.")
        )
        .frame(minHeight: 260)
    }

    private var info: some View {
        VStack(spacing: 0) {
            infoRow("Contract Address", token.contract, "number")
            infoRow("Market Cap", feed.details?.marketCap ?? "—", "chart.pie.fill")
            infoRow("24h Volume", feed.details?.volume24H ?? "—", "chart.bar.fill")
            infoRow("Liquidity", feed.details?.liquidity ?? "—", "drop.fill")
            infoRow("Holders", feed.details?.holderCount ?? "—", "person.2.fill")
            infoRow("Network", token.symbol == "SOL" ? "Solana" : "Multi-chain", "network")
            liveCaption("OKX token snapshot · refreshed every 30 seconds")
        }.padding(.horizontal, 20)
    }

    private func infoRow(_ label: String, _ value: String, _ icon: String) -> some View {
        HStack { Label(label, systemImage: icon).foregroundStyle(.secondary); Spacer(); Text(value).fontWeight(.bold) }
            .font(.system(size: 14, design: .rounded)).frame(height: 58)
            .padding(.horizontal, 14)
            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .padding(.bottom, 7)
    }

    private func liveCaption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity).padding(.vertical, 16)
    }

    private var tradeBar: some View {
        HStack(spacing: 12) {
            ShareLink(item: "\(token.name) (\(token.symbol))") {
                Image(systemName: "square.and.arrow.up").frame(width: 52, height: 52)
            }.perpSearchGlass(in: Circle())
            Spacer()
            Button { tradeSide = "Buy" } label: { Text("Buy").frame(width: 92, height: 52) }.perpSearchGlass(in: Capsule())
            Button { tradeSide = "Sell" } label: { Text("Sell").frame(width: 92, height: 52) }.perpSearchGlass(in: Capsule())
        }.font(.system(size: 18, weight: .semibold, design: .rounded)).foregroundStyle(.white)
    }
}

@MainActor
private final class SpotLiveFeed: ObservableObject {
    struct Candle: Identifiable {
        let timestamp: Int64
        let open: Double
        let high: Double
        let low: Double
        let close: Double
        var id: Int64 { timestamp }
    }

    struct Details {
        let marketCap: String
        let liquidity: String
        let volume24H: String
        let holderCount: String
    }

    struct Holder: Identifiable {
        let wallet: SpotWallet
        let amount: String
        let value: String
        let percent: String
        var id: String { wallet.id }
    }

    @Published private(set) var candles: [Candle] = []
    @Published private(set) var transactions: [SpotTransaction] = []
    @Published private(set) var latestPrice: Double?
    @Published private(set) var errorText: String?
    @Published private(set) var isLoading = true
    @Published private(set) var observedAt: Date?
    @Published private(set) var details: Details?
    @Published private(set) var holders: [Holder] = []
    @Published private(set) var detailsError: String?

    let symbol: String
    private var period = "1H"

    init(symbol: String) { self.symbol = symbol }

    var stateText: String {
        if isLoading { return "CONNECTING" }
        if errorText != nil { return "UNAVAILABLE" }
        return "LIVE"
    }

    var changePercent: Double? {
        guard let first = candles.first?.open, let last = candles.last?.close, first != 0 else { return nil }
        return ((last - first) / first) * 100
    }

    var isUp: Bool { (changePercent ?? 0) >= 0 }

    func changePeriod(_ value: String) {
        period = value == "LIVE" ? "1s" : value
        isLoading = true
    }

    func run(period initialPeriod: String) async {
        changePeriod(initialPeriod)
        await refreshDetails()
        var ticks = 0
        while !Task.isCancelled {
            await refresh()
            ticks += 1
            if ticks.isMultiple(of: 15) { await refreshDetails() }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func refreshDetails() async {
        guard ["BTC", "ETH", "SOL", "PUMP"].contains(symbol) else {
            detailsError = "Verified token details are not available for \(symbol) yet."
            return
        }
        var components = URLComponents(string: "https://web-lovat-nine-49.vercel.app/api/token-details")!
        components.queryItems = [URLQueryItem(name: "symbol", value: symbol)]
        do {
            let (data, response) = try await URLSession.shared.data(from: components.url!)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw URLError(.badServerResponse)
            }
            let info = root["priceInfo"] as? [String: Any]
            let price = Self.number(info?["price"])
            details = Details(
                marketCap: Self.compactUSD(Self.number(info?["marketCap"])),
                liquidity: Self.compactUSD(Self.number(info?["liquidity"])),
                volume24H: Self.compactUSD(Self.number(info?["volume24H"])),
                holderCount: Self.count(Self.number(info?["holders"]))
            )
            let rows = root["holders"] as? [[String: Any]] ?? []
            holders = rows.compactMap { row in
                guard let address = row["holderWalletAddress"] as? String, !address.isEmpty else { return nil }
                let rawAmount = Self.number(row["holdAmount"])
                let rawPercent = Self.number(row["holdPercent"])
                let rawValue = rawAmount.flatMap { amount in price.map { amount * $0 } }
                return Holder(
                    wallet: SpotWallet(address: address, emoji: "◉", portfolio: Self.compactUSD(rawValue)),
                    amount: Self.compactNumber(rawAmount),
                    value: Self.compactUSD(rawValue),
                    percent: rawPercent.map { String(format: "%.2f%%", $0) } ?? "—"
                )
            }
            detailsError = nil
        } catch {
            detailsError = "Token details are temporarily unavailable."
        }
    }

    private func refresh() async {
        guard ["BTC", "ETH", "SOL", "PUMP"].contains(symbol) else {
            isLoading = false
            errorText = "Live on-chain coverage is not available for \(symbol) yet."
            return
        }
        var components = URLComponents(string: "https://web-lovat-nine-49.vercel.app/api/market-snapshot")!
        components.queryItems = [URLQueryItem(name: "symbol", value: symbol), URLQueryItem(name: "period", value: period)]
        do {
            let (data, response) = try await URLSession.shared.data(from: components.url!)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw URLError(.cannotParseResponse)
            }
            let nextCandles = (root["candles"] as? [[String]] ?? []).compactMap(Self.candle).reversed()
            let nextTrades = (root["trades"] as? [[String: Any]] ?? []).compactMap { Self.trade($0, symbol: symbol) }
            candles = Array(nextCandles)
            transactions = Array(nextTrades.prefix(60))
            latestPrice = candles.last?.close
            observedAt = Date()
            errorText = nil
            isLoading = false
        } catch {
            isLoading = false
            errorText = "Live market data is reconnecting…"
        }
    }

    private static func candle(_ row: [String]) -> Candle? {
        guard row.count >= 5, let timestamp = Int64(row[0]), let open = Double(row[1]),
              let high = Double(row[2]), let low = Double(row[3]), let close = Double(row[4]) else { return nil }
        return Candle(timestamp: timestamp, open: open, high: high, low: low, close: close)
    }

    private static func trade(_ row: [String: Any], symbol: String) -> SpotTransaction? {
        guard row["id"] as? String != nil,
              let address = row["userAddress"] as? String,
              let kind = row["type"] as? String else { return nil }
        let milliseconds = (row["time"] as? String).flatMap(Int64.init) ?? 0
        let age = max(0, Int(Date().timeIntervalSince1970 - Double(milliseconds) / 1_000))
        let changed = row["changedTokenInfo"] as? [[String: Any]] ?? []
        let token = changed.first(where: {
            (($0["tokenSymbol"] as? String) ?? "").uppercased().contains(symbol)
        }) ?? changed.first
        let rawAmount = Double((token?["amount"] as? String) ?? "") ?? 0
        let amount = rawAmount.formatted(.number.precision(.fractionLength(0...8)))
        let volume = Double((row["volume"] as? String) ?? "") ?? 0
        let wallet = SpotWallet(address: address, emoji: "◉", portfolio: "—")
        return SpotTransaction(age: age < 60 ? "\(age)s" : "\(age / 60)m", isBuy: kind == "buy",
                               amount: "\(amount) \(symbol)", value: spotPrice(volume), wallet: wallet)
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func compactUSD(_ value: Double?) -> String {
        guard let value, value.isFinite, value != 0 else { return "—" }
        return "$" + compactNumber(value)
    }

    private static func count(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    private static func compactNumber(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return value.formatted(.number.notation(.compactName).precision(.fractionLength(0...2)))
    }
}

private struct SpotCandlestickChart: View {
    let isUp: Bool
    let seed: String
    let values: [SpotLiveFeed.Candle]

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let step = width / CGFloat(max(values.count, 1))
            let low = values.map(\.low).min() ?? 0
            let high = values.map(\.high).max() ?? 1
            let span = max(high - low, 0.00000001)
            let y: (Double) -> CGFloat = { value in
                height * CGFloat(1 - ((value - low) / span))
            }
            ZStack {
                VStack(spacing: 0) {
                    ForEach(0..<4) { _ in Spacer(); Divider().overlay(Color.white.opacity(0.07)) }
                }
                ForEach(Array(values.enumerated()), id: \.element.id) { index, item in
                    let x = CGFloat(index) * step + step / 2
                    let color = item.close >= item.open ? DeskColor.rise.color : DeskColor.fall.color
                    Path { path in
                        path.move(to: CGPoint(x: x, y: y(item.high)))
                        path.addLine(to: CGPoint(x: x, y: y(item.low)))
                    }.stroke(color, lineWidth: 1.2)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: max(2, step * 0.56), height: max(2, abs(y(item.open) - y(item.close))))
                        .position(x: x, y: (y(item.open) + y(item.close)) / 2)
                }
                Rectangle().fill(isUp ? DeskColor.rise.color.opacity(0.4) : DeskColor.fall.color.opacity(0.4)).frame(height: 1)
            }
        }
        .padding(.horizontal, 10)
        .background(Color.white.opacity(0.025))
        .accessibilityLabel("Live candlestick chart for \(seed)")
    }
}

private struct SpotTradePreview: View {
    let token: TrendingSpotToken
    let side: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { MarketTokenLogo(symbol: token.symbol, size: 42); Text("\(side) \(token.symbol)").font(.system(size: 24, weight: .heavy, design: .rounded)); Spacer() }
            Text("Spot execution is not connected yet")
                .font(.system(size: 18, weight: .bold, design: .rounded))
            Text("This is a preview of the spot ticket. No quote has been requested and nothing will leave your wallet.")
                .font(.system(size: 14, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
            Button("Done") { dismiss() }
                .font(.system(size: 16, weight: .bold, design: .rounded)).frame(maxWidth: .infinity).frame(height: 52)
                .foregroundStyle(.black).background(.white, in: Capsule())
        }.padding(24).preferredColorScheme(.dark)
    }
}

private struct WalletProfileScreen: View {
    let wallet: SpotWallet
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "chevron.left").frame(width: 50, height: 50) }.perpSearchGlass(in: Circle())
                    Spacer()
                    ShareLink(item: wallet.address) { Image(systemName: "square.and.arrow.up").frame(width: 50, height: 50) }.perpSearchGlass(in: Circle())
                }.font(.system(size: 18, weight: .bold)).foregroundStyle(.white)

                HStack(spacing: 18) {
                    Text(wallet.emoji).font(.system(size: 50)).frame(width: 84, height: 84).perpSearchGlass(in: Circle())
                    VStack(alignment: .leading, spacing: 3) { Text(wallet.portfolio).font(.system(size: 18, weight: .bold)); Text("Portfolio").foregroundStyle(.secondary) }
                    Divider().frame(height: 46).overlay(Color.white.opacity(0.12))
                    VStack(alignment: .leading, spacing: 3) { Text("—").font(.system(size: 18, weight: .bold)); Text("Total PnL").foregroundStyle(.secondary) }
                }.padding(.top, 42)

                Text(wallet.displayAddress).font(.system(size: 20, weight: .bold, design: .rounded)).padding(.top, 22)
                Label("Online", systemImage: "circle.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(DeskColor.rise.color).padding(.top, 8)

                HStack(spacing: 10) {
                    Button("Follow") {}.frame(maxWidth: .infinity).frame(height: 42).perpSearchGlass(in: RoundedRectangle(cornerRadius: 12))
                    Button("Set Name") {}.frame(maxWidth: .infinity).frame(height: 42).perpSearchGlass(in: RoundedRectangle(cornerRadius: 12))
                }.font(.system(size: 14, weight: .bold, design: .rounded)).padding(.top, 18)

                HStack { Text("Positions").foregroundStyle(.white); Spacer(); Text("Closed"); Spacer(); Text("Activity") }
                    .font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.top, 34).padding(.bottom, 14)
                Divider().overlay(Color.white.opacity(0.12))
                VStack(spacing: 0) {
                    profileRow("Bitcoin", "BTC", "$42.18")
                    profileRow("Ethereum", "ETH", "$18.75")
                    profileRow("Solana", "SOL", "$10.45")
                }
                Text("Preview profile · indexed wallet history is not connected")
                    .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 20)
                Spacer()
            }.padding(.horizontal, 20).padding(.top, 8)
        }.toolbar(.hidden, for: .navigationBar)
    }

    private func profileRow(_ name: String, _ symbol: String, _ value: String) -> some View {
        HStack { MarketTokenLogo(symbol: symbol, size: 42); VStack(alignment: .leading) { Text(name).fontWeight(.bold); Text(symbol).foregroundStyle(.secondary) }; Spacer(); Text(value).fontWeight(.bold) }
            .font(.system(size: 15, design: .rounded)).frame(height: 72)
            .overlay(alignment: .bottom) { Divider().overlay(Color.white.opacity(0.1)).padding(.leading, 54) }
    }
}
