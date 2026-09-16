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
    let onOrderFilled: (Direction, String) -> Void
    @State private var showsMarket = false
    @State private var selectedSpot: TrendingSpotToken?
    @State private var isEditing = false
    /// Saved locally. A watchlist is the user's own note about markets, it never needs to
    /// leave the phone, and the list is short enough that defaults are the right home.
    @AppStorage("desk.watchlist") private var savedIDs = ""
    @AppStorage("desk.spotWatchlist") private var savedSpotData = ""

    private var saved: Set<UInt32> {
        Set(savedIDs.split(separator: ",").compactMap { UInt32($0) })
    }

    private var rows: [Market] {
        market.allMarkets.filter { saved.contains($0.id) }
    }

    private var spotRows: [TrendingSpotToken] {
        SpotWatchlistStorage.decode(savedSpotData)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                DeskBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.title2)
                            .frame(width: 44, height: 44)
                            .perpSearchGlass(in: Circle())
                        Spacer()
                        Text("Watchlist").font(.title2.bold())
                        Spacer()
                        Button(isEditing ? "Done" : "Edit") {
                            withAnimation(.easeInOut(duration: 0.2)) { isEditing.toggle() }
                        }
                            .font(.body)
                            .frame(width: 64, height: 44)
                            .perpSearchGlass(in: Capsule())
                    }
                    .foregroundStyle(DeskColor.nightText.color)
                    .padding(.top, 10)

                    Text(rows.isEmpty && spotRows.isEmpty
                         ? "Markets you save from Search appear here."
                         : "\(rows.count + spotRows.count) market\(rows.count + spotRows.count == 1 ? "" : "s") saved.")
                        .font(DeskType.caption)
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .padding(.top, 6)

                    if rows.isEmpty && spotRows.isEmpty {
                        empty.padding(.top, 40)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(spotRows) { token in
                                ZStack(alignment: .trailing) {
                                    Button { selectedSpot = token } label: {
                                        SpotWatchlistCard(token: token)
                                    }
                                    .buttonStyle(.plain)
                                    if isEditing {
                                        Button { remove(token) } label: {
                                            Image(systemName: "minus")
                                                .font(.headline)
                                                .frame(width: 36, height: 36)
                                                .background(.red, in: Circle())
                                        }
                                        .foregroundStyle(.white)
                                        .padding(.trailing, 14)
                                        .transition(.scale.combined(with: .opacity))
                                    }
                                }
                            }
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
                PerpDetailScreen(
                    model: model, market: market, session: session,
                    onOrderFilled: onOrderFilled)
                    .toolbar(.hidden, for: .tabBar)
            }
            .navigationDestination(item: $selectedSpot) { token in
                SpotTokenDetailScreen(token: token)
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

    private func remove(_ token: TrendingSpotToken) {
        savedSpotData = SpotWatchlistStorage.toggling(token, in: savedSpotData)
    }

    private func open(_ entry: Market) {
        market.select(entry)
        Task {
            await session.selectMarket(entry)
            showsMarket = true
        }
    }
}

// MARK: - Search

struct MarketSearchScreen: View {
    let model: AppModel
    let market: MarketModel
    let session: TradingSession
    let onOrderFilled: (Direction, String) -> Void
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
                    // Full bleed, with the inset moved inside the scroller. Taking the
                    // parent's 20pt padding, the row was cropped 20pt short of the
                    // screen and the next card read as cut off rather than as waiting
                    // to be scrolled to.
                    .contentMargins(.horizontal, 20)
                    .padding(.horizontal, -20)
                    .padding(.top, 12)

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

                    // Directly above the rows it titles. This header used to sit above
                    // the trending-coins section, so the screen announced "All Perpl
                    // Markets · 7 live" and then listed spot tokens, while the seven
                    // markets themselves arrived further down under no heading at all.
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
                // Clears the floating search field as well as the tab bar. At 130 the
                // last trending row sat underneath "Search anything" and could not be
                // read or tapped.
                .padding(.bottom, 184)
            }
            }
            .toolbar(.hidden, for: .navigationBar)
            .searchable(text: $query, prompt: "Search anything")
            .navigationDestination(isPresented: $showsMarket) {
                PerpDetailScreen(
                    model: model, market: market, session: session,
                    onOrderFilled: onOrderFilled)
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
        Task {
            await session.selectMarket(entry)
            showsMarket = true
        }
    }
}

// MARK: - Spot discovery

private struct TrendingSpotToken: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let chainIndex: String
    let chainName: String
    let symbol: String
    let name: String
    let logoURL: String
    let contract: String
    let decimals: Double?
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
    private struct Response: Decodable, Sendable { let tokens: [TrendingSpotToken] }
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
            let tokens = try await Task.detached(priority: .utility) {
                try JSONDecoder().decode(Response.self, from: data).tokens
            }.value
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
                    .lineLimit(1)
                Text(token.symbol + " · " + token.chainName)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            // Price and change in one trailing column, the way every other row in Desk
            // reads. Sharing a line with the symbol and the chain, these wrapped
            // mid-word inside a 76pt row — "ARGU" above "S" — and once that was held to
            // one line the change became the part that truncated, to "+1130.9…". A
            // percentage with its digits cut off is worse than no percentage at all.
            VStack(alignment: .trailing, spacing: 3) {
                Text(token.price.map(spotPrice) ?? "$—")
                    .font(.system(size: 15, weight: .bold).monospacedDigit())
                    .foregroundStyle(DeskColor.nightText.color)
                    .lineLimit(1)
                if let change = token.change {
                    Text(String(format: "%+.2f%%", change))
                        .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(change >= 0 ? DeskColor.rise.color : DeskColor.fall.color)
                        .lineLimit(1)
                }
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(DeskColor.nightMuted.color)
        }
        .padding(.horizontal, 14)
        .frame(height: 76)
        .background { TokenAdaptiveCardBackground(symbol: token.symbol, cornerRadius: 18, artworkURL: token.artworkURL) }
    }
}

private enum SpotWatchlistStorage {
    static func decode(_ raw: String) -> [TrendingSpotToken] {
        guard let data = raw.data(using: .utf8),
              let tokens = try? JSONDecoder().decode([TrendingSpotToken].self, from: data)
        else { return [] }
        return tokens
    }

    static func contains(_ token: TrendingSpotToken, in raw: String) -> Bool {
        decode(raw).contains { $0.id == token.id }
    }

    static func toggling(_ token: TrendingSpotToken, in raw: String) -> String {
        var tokens = decode(raw)
        if let index = tokens.firstIndex(where: { $0.id == token.id }) {
            tokens.remove(at: index)
        } else {
            tokens.insert(token, at: 0)
        }
        guard let data = try? JSONEncoder().encode(tokens),
              let result = String(data: data, encoding: .utf8) else { return raw }
        return result
    }
}

private struct SpotWatchlistCard: View {
    let token: TrendingSpotToken

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                MarketTokenLogo(symbol: token.symbol, size: 42, remoteURL: token.artworkURL)
                VStack(alignment: .leading, spacing: 2) {
                    Text(token.symbol).font(.headline)
                    Text(token.name).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(token.price.map(spotPrice) ?? "$—")
                        .font(.headline.monospacedDigit())
                    if let change = token.change {
                        Text(String(format: "24H %+.1f%%", change))
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(change >= 0 ? DeskColor.rise.color : DeskColor.fall.color)
                    }
                }
            }
            HStack(spacing: 8) {
                metric("VOL", token.volume24H)
                metric("MCAP", token.marketCap)
                metric("LIQUIDITY", token.liquidity)
            }
        }
        .foregroundStyle(DeskColor.nightText.color)
        .padding(14)
        .background { TokenAdaptiveCardBackground(symbol: token.symbol, cornerRadius: 22, artworkURL: token.artworkURL) }
    }

    private func metric(_ label: String, _ value: Double?) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            Text(value.map(Self.compactUSD) ?? "$—").font(.subheadline.weight(.bold).monospacedDigit())
        }
        .frame(maxWidth: .infinity).frame(height: 44)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private static func compactUSD(_ value: Double) -> String {
        "$" + value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
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

private struct SpotWallet: Identifiable, Hashable, Sendable {
    let address: String
    let emoji: String
    let portfolio: String
    var id: String { address }
    var displayAddress: String {
        guard address.count > 13 else { return address }
        return "\(address.prefix(6))…\(address.suffix(5))"
    }
}

private struct SpotTransaction: Identifiable, Sendable {
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
    @AppStorage("desk.spotWatchlist") private var savedSpotData = ""

    private var isSaved: Bool {
        SpotWatchlistStorage.contains(token, in: savedSpotData)
    }

    init(token: TrendingSpotToken) {
        self.token = token
        _feed = StateObject(wrappedValue: SpotLiveFeed(
            symbol: token.symbol, chainIndex: token.chainIndex, contract: token.contract
        ))
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
            tradeBar
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)
                .background {
                    // The transaction rows pass under this bar as they scroll. Without
                    // a fade they show through the glass and read as colliding with Buy
                    // and Sell rather than sitting behind them.
                    LinearGradient(
                        colors: [.black.opacity(0), .black.opacity(0.9), .black],
                        startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea(edges: .bottom)
                        .allowsHitTesting(false)
                }
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
            SpotTradeTicket(token: token, side: tradeSide ?? "Buy")
                .presentationDetents([.height(560)])
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
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                        savedSpotData = SpotWatchlistStorage.toggling(token, in: savedSpotData)
                    }
                } label: {
                    Image(systemName: isSaved ? "star.fill" : "star")
                        .font(.system(size: 20, weight: .semibold)).frame(width: 48, height: 48)
                }
                .perpSearchGlass(in: Circle())
                .foregroundStyle(isSaved ? Color.yellow : Color.white)
                .accessibilityLabel(isSaved ? "Remove from watchlist" : "Add to watchlist")
            }

            HStack(spacing: 12) {
                MarketTokenLogo(symbol: token.symbol, size: 46, remoteURL: token.artworkURL)
                VStack(alignment: .leading, spacing: 2) {
                    Text(token.name).font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("\(token.symbol) · \(token.chainName)").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .firstTextBaseline) {
                AmountText((feed.latestPrice ?? token.price).map(spotPrice) ?? "$—", size: 36)
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
        VStack(alignment: .leading, spacing: 8) {
            SpotCandlestickChart(isUp: feed.isUp, seed: token.symbol, values: feed.candles)
                .frame(height: 286)
            if !feed.candles.isEmpty && feed.candles.count < 12 {
                Text("Sparse market · only \(feed.candles.count) real candles in this range")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
            }
        }
        .padding(.top, 14)
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
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(tx.age).foregroundStyle(.secondary)
                        Text(tx.isBuy ? "BUY" : "SELL")
                            .font(.caption2.weight(.heavy)).foregroundStyle(.white)
                            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(tx.isBuy ? DeskColor.rise.color : DeskColor.fall.color, in: Capsule())
                    }
                    .font(.caption.weight(.semibold))
                    .frame(width: 58, alignment: .leading)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(tx.amount)
                            .lineLimit(1).minimumScaleFactor(0.75)
                            .foregroundStyle(tx.isBuy ? DeskColor.rise.color : DeskColor.fall.color)
                        Text(tx.value).font(.caption).foregroundStyle(.secondary)
                    }
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    Button { selectedWallet = tx.wallet } label: {
                        HStack(spacing: 6) { Text(tx.wallet.emoji); Text(tx.wallet.displayAddress).underline() }
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                    }.foregroundStyle(.secondary).frame(width: 104, alignment: .trailing)
                }
                .padding(.horizontal, 20).frame(height: 64)
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
            infoRow("Network", token.chainName, "network")
            if token.communityRecognized == false {
                Label("Community recognition is not verified. Confirm the contract before trading.", systemImage: "exclamationmark.shield.fill")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.yellow)
                    .padding(14)
                    .background(Color.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            if let liquidity = token.liquidity, liquidity < 10_000 {
                Label(liquidity < 1_000 ? "Extremely low liquidity" : "Low liquidity", systemImage: "drop.triangle.fill")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(liquidity < 1_000 ? .red : .yellow)
                    .padding(.top, 8)
            }
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
        HStack(spacing: 10) {
            ShareLink(item: "\(token.name) (\(token.symbol))") {
                Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44)
            }.perpSearchGlass(in: Circle())
            Spacer()
            Button { tradeSide = "Buy" } label: { Text("Buy").frame(width: 78, height: 44) }.perpSearchGlass(in: Capsule())
            Button { tradeSide = "Sell" } label: { Text("Sell").frame(width: 78, height: 44) }.perpSearchGlass(in: Capsule())
        }.font(.headline).foregroundStyle(.white)
    }
}

@MainActor
private final class SpotLiveFeed: ObservableObject {
    struct Candle: Identifiable, Sendable {
        let timestamp: Int64
        let open: Double
        let high: Double
        let low: Double
        let close: Double
        var id: Int64 { timestamp }
    }

    struct Details: Sendable {
        let marketCap: String
        let liquidity: String
        let volume24H: String
        let holderCount: String
    }

    struct Holder: Identifiable, Sendable {
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

    private struct SnapshotPayload: Sendable {
        let candles: [Candle]
        let transactions: [SpotTransaction]
    }

    private struct DetailsPayload: Sendable {
        let details: Details
        let holders: [Holder]
    }

    let symbol: String
    let chainIndex: String
    let contract: String
    private var period = "1H"

    init(symbol: String, chainIndex: String, contract: String) {
        self.symbol = symbol
        self.chainIndex = chainIndex
        self.contract = contract
    }

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
        var components = URLComponents(string: "https://web-lovat-nine-49.vercel.app/api/token-details")!
        components.queryItems = [
            URLQueryItem(name: "symbol", value: symbol),
            URLQueryItem(name: "chainIndex", value: chainIndex),
            URLQueryItem(name: "address", value: contract)
        ]
        do {
            let (data, response) = try await URLSession.shared.data(from: components.url!)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let payload = try await Task.detached(priority: .utility) {
                try Self.decodeDetails(data)
            }.value
            details = payload.details
            holders = payload.holders
            detailsError = nil
        } catch {
            detailsError = "Token details are temporarily unavailable."
        }
    }

    private func refresh() async {
        var components = URLComponents(string: "https://web-lovat-nine-49.vercel.app/api/market-snapshot")!
        components.queryItems = [
            URLQueryItem(name: "symbol", value: symbol),
            URLQueryItem(name: "chainIndex", value: chainIndex),
            URLQueryItem(name: "address", value: contract),
            URLQueryItem(name: "period", value: period)
        ]
        do {
            let (data, response) = try await URLSession.shared.data(from: components.url!)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let currentSymbol = symbol
            let payload = try await Task.detached(priority: .utility) {
                try Self.decodeSnapshot(data, symbol: currentSymbol)
            }.value
            candles = payload.candles
            transactions = payload.transactions
            latestPrice = candles.last?.close
            observedAt = Date()
            errorText = nil
            isLoading = false
        } catch {
            isLoading = false
            errorText = "Live market data is reconnecting…"
        }
    }

    nonisolated private static func decodeSnapshot(_ data: Data, symbol: String) throws -> SnapshotPayload {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        let candles = Array((root["candles"] as? [[String]] ?? []).compactMap(candle).reversed())
        let transactions = Array((root["trades"] as? [[String: Any]] ?? [])
            .compactMap { trade($0, symbol: symbol) }.prefix(60))
        return SnapshotPayload(candles: candles, transactions: transactions)
    }

    nonisolated private static func decodeDetails(_ data: Data) throws -> DetailsPayload {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        let info = root["priceInfo"] as? [String: Any]
        let price = number(info?["price"])
        let details = Details(
            marketCap: compactUSD(number(info?["marketCap"])),
            liquidity: compactUSD(number(info?["liquidity"])),
            volume24H: compactUSD(number(info?["volume24H"])),
            holderCount: count(number(info?["holders"]))
        )
        let holders = (root["holders"] as? [[String: Any]] ?? []).compactMap { row -> Holder? in
            guard let address = row["holderWalletAddress"] as? String, !address.isEmpty else { return nil }
            let rawAmount = number(row["holdAmount"])
            let rawPercent = number(row["holdPercent"])
            let rawValue = rawAmount.flatMap { amount in price.map { amount * $0 } }
            return Holder(
                wallet: SpotWallet(address: address, emoji: "◉", portfolio: compactUSD(rawValue)),
                amount: compactNumber(rawAmount),
                value: compactUSD(rawValue),
                percent: rawPercent.map { String(format: "%.2f%%", $0) } ?? "—"
            )
        }
        return DetailsPayload(details: details, holders: holders)
    }

    nonisolated private static func candle(_ row: [String]) -> Candle? {
        guard row.count >= 5, let timestamp = Int64(row[0]), let open = Double(row[1]),
              let high = Double(row[2]), let low = Double(row[3]), let close = Double(row[4]) else { return nil }
        return Candle(timestamp: timestamp, open: open, high: high, low: low, close: close)
    }

    nonisolated private static func trade(_ row: [String: Any], symbol: String) -> SpotTransaction? {
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

    nonisolated private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    nonisolated private static func compactUSD(_ value: Double?) -> String {
        guard let value, value.isFinite, value != 0 else { return "—" }
        return "$" + compactNumber(value)
    }

    nonisolated private static func count(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    nonisolated private static func compactNumber(_ value: Double?) -> String {
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
            // An illiquid token may truthfully return only one or two buckets. Reserve a
            // normal chart density so those candles stay candle-sized instead of each
            // expanding to half the phone.
            let visibleSlots = max(values.count, 24)
            let step = width / CGFloat(visibleSlots)
            let leadingSlots = visibleSlots - values.count
            let low = values.map(\.low).min() ?? 0
            let high = values.map(\.high).max() ?? 1
            let rawSpan = max(high - low, max(abs(high) * 0.002, 0.00000001))
            let lowerBound = low - rawSpan * 0.08
            let span = rawSpan * 1.16
            let y: (Double) -> CGFloat = { value in
                height * CGFloat(1 - ((value - lowerBound) / span))
            }
            ZStack {
                VStack(spacing: 0) {
                    ForEach(0..<4) { _ in Spacer(); Divider().overlay(Color.white.opacity(0.07)) }
                }
                ForEach(Array(values.enumerated()), id: \.element.id) { index, item in
                    let x = CGFloat(leadingSlots + index) * step + step / 2
                    let color = item.close >= item.open ? DeskColor.rise.color : DeskColor.fall.color
                    Path { path in
                        path.move(to: CGPoint(x: x, y: y(item.high)))
                        path.addLine(to: CGPoint(x: x, y: y(item.low)))
                    }.stroke(color, lineWidth: 1.2)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: min(9, max(3, step * 0.58)), height: max(2, abs(y(item.open) - y(item.close))))
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

private struct SpotTradeTicket: View {
    let token: TrendingSpotToken
    let side: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var quote = SpotQuoteModel()
    @State private var amount = ""

    private var nativeSymbol: String {
        switch token.chainIndex {
        case "501": "SOL"
        case "56": "BNB"
        case "137": "POL"
        case "196": "OKB"
        default: "ETH"
        }
    }

    private var sourceSymbol: String { side == "Buy" ? nativeSymbol : token.symbol }
    private var destinationSymbol: String { side == "Buy" ? token.symbol : nativeSymbol }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                MarketTokenLogo(symbol: token.symbol, size: 42, remoteURL: token.artworkURL)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(side) \(token.symbol)").font(.system(size: 22, weight: .heavy, design: .rounded))
                    Text(token.chainName).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title2) }.foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("YOU PAY").font(.system(size: 10, weight: .heavy, design: .rounded)).tracking(1.2).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline) {
                    TextField("0", text: $amount)
                        .keyboardType(.decimalPad)
                        .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                    Text(sourceSymbol).font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
                }
                Text("Wallet balance unavailable · not Monad testnet AUSD")
                    .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
            }
            .padding(16)
            .perpSearchGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))

            HStack {
                Text("You receive")
                Spacer()
                Text(quote.output.map { "\($0) \(destinationSymbol)" } ?? "— \(destinationSymbol)")
                    .fontWeight(.bold).monospacedDigit()
            }
            .font(.system(size: 14, design: .rounded))

            if let impact = quote.priceImpact {
                HStack { Text("Price impact"); Spacer(); Text(impact).fontWeight(.bold) }
                    .font(.system(size: 13, design: .rounded)).foregroundStyle(.secondary)
            }
            if let error = quote.errorText {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.yellow)
            }
            if token.communityRecognized == false || (token.liquidity ?? .greatestFiniteMagnitude) < 10_000 {
                Text("Verify the contract and liquidity independently before trading.")
                    .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.yellow)
            }

            Button { Task { await quote.fetch(token: token, side: side, amount: amount) } } label: {
                HStack {
                    if quote.isLoading { ProgressView().tint(.black) }
                    Text(quote.output == nil ? "Get live quote" : "Refresh quote")
                    Spacer(); Image(systemName: "arrow.right")
                }
                .font(.system(size: 16, weight: .bold, design: .rounded)).padding(.horizontal, 18)
                .frame(maxWidth: .infinity).frame(height: 54)
            }
            .buttonStyle(.plain).foregroundStyle(.black).background(.white, in: Capsule())
            .disabled(amount.isEmpty || quote.isLoading).opacity(amount.isEmpty ? 0.35 : 1)

            Text("Quote only · no approval, signature or transaction is sent")
                .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
        .padding(24).preferredColorScheme(.dark)
        .onChange(of: amount) { _, _ in quote.clear() }
    }
}

@MainActor
private final class SpotQuoteModel: ObservableObject {
    @Published private(set) var output: String?
    @Published private(set) var priceImpact: String?
    @Published private(set) var errorText: String?
    @Published private(set) var isLoading = false

    func clear() { output = nil; priceImpact = nil; errorText = nil }

    func fetch(token: TrendingSpotToken, side: String, amount: String) async {
        clear(); isLoading = true; defer { isLoading = false }
        guard let decimals = token.decimals.map(Int.init) else {
            errorText = "This token’s decimal precision is unavailable, so it cannot be quoted safely."
            return
        }
        var components = URLComponents(string: "https://web-lovat-nine-49.vercel.app/api/swap-quote")!
        components.queryItems = [
            URLQueryItem(name: "chainIndex", value: token.chainIndex),
            URLQueryItem(name: "tokenAddress", value: token.contract),
            URLQueryItem(name: "tokenDecimals", value: String(decimals)),
            URLQueryItem(name: "side", value: side.lowercased()),
            URLQueryItem(name: "amount", value: amount)
        ]
        do {
            let (data, response) = try await URLSession.shared.data(from: components.url!)
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let quote = root?["quote"] as? [String: Any] else {
                errorText = root?["error"] as? String ?? "A live quote is unavailable right now."
                return
            }
            output = Self.read(quote["toAmountReadable"])
            if let raw = Self.read(quote["priceImpactPercentage"]), let value = Double(raw) {
                priceImpact = String(format: "%.2f%%", value)
            }
            if output == nil { errorText = "OKX returned a quote without a verifiable output amount." }
        } catch {
            errorText = "The quote service could not be reached."
        }
    }

    private static func read(_ value: Any?) -> String? {
        if let value = value as? String, !value.isEmpty { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
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
