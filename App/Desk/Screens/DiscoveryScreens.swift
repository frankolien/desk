import DeskAuth
import DeskChain
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
                SpotTokenDetailScreen(token: token, model: model)
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

    /// "Solana" finds SOL: the market's common name counts as much as its ticker.
    private static let marketNames: [String: String] = [
        "BTC": "Bitcoin", "ETH": "Ethereum", "SOL": "Solana", "MON": "Monad", "ZEC": "Zcash",
        "HYPE": "Hyperliquid", "LIT": "Lighter", "PUMP": "Pump", "DOGE": "Dogecoin", "XRP": "Ripple",
        "BNB": "BNB", "AVAX": "Avalanche", "LINK": "Chainlink", "ARB": "Arbitrum", "OP": "Optimism", "SUI": "Sui",
    ]

    private var results: [Market] {
        let wanted = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return market.allMarkets }
        return market.allMarkets.filter {
            $0.symbol.localizedCaseInsensitiveContains(wanted)
                || (Self.marketNames[$0.symbol.uppercased()]?.localizedCaseInsensitiveContains(wanted) ?? false)
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
                    // Full bleed: the inset lives inside the scroller, so cards reach the
                    // screen edge instead of being cropped short of it.
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
                                    TrendingSpotRow(token: token).contentShape(Rectangle())
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

                    // Directly above the rows it titles.
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

                    Text("Perpl \(model.network.shortName.lowercased()) lists these \(market.allMarkets.count) perpetual markets. "
                         + "Discovery tokens from other networks are separate from tradeable Perpl contracts.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 24)
                }
                .padding(.horizontal, 20)
                // Clears the floating search field as well as the tab bar.
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
            #if DEBUG
            // `-spot-buy` opens the first buyable trending token with its Buy sheet up,
            // so the sheet can be captured on any simulator without tapping through.
            .task {
                let arguments = ProcessInfo.processInfo.arguments
                guard arguments.contains("-spot-buy") || arguments.contains("-wallet-demo") else { return }
                while discovery.trending.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
                if arguments.contains("-wallet-demo") {
                    // A Monad token, so the holder opened has a ledger to show.
                    var monad = discovery.trending.first { $0.chainIndex == "143" }
                    if monad == nil {
                        await discovery.search("0x5e49e1f85813f2b65858860a3fa231b4186f2e0e")
                        monad = discovery.searchResults.first { $0.chainIndex == "143" }
                    }
                    selectedSpot = monad ?? discovery.trending.first
                } else {
                    selectedSpot = discovery.trending.first { $0.buyable == true } ?? discovery.trending.first
                }
            }
            #endif
            .navigationDestination(item: $selectedSpot) { token in
                SpotTokenDetailScreen(token: token, model: model)
                    .toolbar(.hidden, for: .tabBar)
            }
            .task { await discovery.run() }
            .task(id: query) { await discovery.search(query) }
            .task(id: TokenOpenRequest.shared.pending) {
                guard let target = TokenOpenRequest.shared.take() else { return }
                query = target.contract
                for _ in 0..<12 {
                    if let match = (discovery.searchResults + discovery.trending).first(where: {
                        $0.chainIndex == target.chainIndex && $0.contract.caseInsensitiveCompare(target.contract) == .orderedSame
                    }) { selectedSpot = match; return }
                    try? await Task.sleep(for: .milliseconds(300))
                }
                // OKX's search skips most Monad tokens; the page still opens on what is known.
                selectedSpot = TrendingSpotToken(
                    id: "\(target.chainIndex):\(target.contract)", chainIndex: target.chainIndex,
                    chainName: target.chainIndex == "143" ? "Monad" : "Chain \(target.chainIndex)",
                    symbol: target.symbol ?? "TOKEN", name: target.symbol ?? "Token", logoURL: "", contract: target.contract,
                    decimals: nil, quotable: nil, buyable: nil, nativeSymbol: nil, explorerURL: "",
                    price: nil, change: nil, marketCap: nil, volume24H: nil, liquidity: nil, holders: nil,
                    communityRecognized: nil, riskLevel: nil)
            }
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
    /// Both optional: a build can meet a deployment that predates them.
    let quotable: Bool?
    let buyable: Bool?
    let nativeSymbol: String?
    let explorerURL: String
    let price: Double?
    let change: Double?
    let marketCap: Double?
    let volume24H: Double?
    let liquidity: Double?
    let holders: Double?
    let communityRecognized: Bool?
    let riskLevel: String?

    /// Only from hosts that serve token artwork.
    ///
    /// The address comes from the discovery feed, which forwards whatever the upstream
    /// listed. Following it anywhere told a host of someone else's choosing this device's
    /// address and which tokens are being looked at, on every browse.
    var artworkURL: URL? { TokenArtwork.url(logoURL) }
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
        var components = URLComponents(string: "https://web-lovat-nine-49.vercel.app/api/token-discovery")!
        if !query.isEmpty { components.queryItems = [URLQueryItem(name: "q", value: query)] }
        let url = components.url!
        // What this list showed last time, at once; the network's answer replaces it.
        if (intoSearch ? searchResults : trending).isEmpty,
           let cached = await ResponseCache.shared.cached(url),
           let tokens = try? JSONDecoder().decode(Response.self, from: cached).tokens {
            if intoSearch { searchResults = tokens } else { trending = tokens }
        }
        isLoading = (intoSearch ? searchResults : trending).isEmpty
        if isLoading { errorText = nil }
        do {
            let (data, _) = try await ResponseCache.shared.data(from: url)
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
                HStack(spacing: 6) {
                    Text(token.name)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                        .lineLimit(1)
                    let quick = TokenRisk.quick(riskLevel: token.riskLevel, liquidity: token.liquidity, communityRecognized: token.communityRecognized)
                    if quick.needsAttention { RiskChip(level: quick, compact: true) }
                }
                Text(token.symbol + " · " + token.chainName)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            // Price and change in one trailing column, as every other row in Desk reads.
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

/// Three shapes of the same formatter, built once.
///
/// A `NumberFormatter` was constructed per value, including once per decoded trade inside a
/// two-second poll — around thirty constructions a second while a spot screen is open, each
/// pulling locale and ICU state.
private let spotFormatters: [SpotPriceShape: NumberFormatter] = {
    var out: [SpotPriceShape: NumberFormatter] = [:]
    for shape in SpotPriceShape.allCases {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.currencySymbol = "$"
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = shape == .small ? 4 : 2
        formatter.maximumFractionDigits = switch shape {
        case .large: 2
        case .medium: 4
        case .small: 8
        }
        out[shape] = formatter
    }
    return out
}()

private enum SpotPriceShape: CaseIterable { case large, medium, small }

private func spotPrice(_ value: Double) -> String {
    let shape: SpotPriceShape = value >= 100 ? .large : (value >= 1 ? .medium : .small)
    return spotFormatters[shape]?.string(from: NSNumber(value: value)) ?? "$—"
}

// MARK: - One market

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
    /// The venue's own id for the trade. It used to include `age`, which changes on every
    /// two-second poll, so every row under a minute old took a new identity and the whole
    /// list was torn down and rebuilt rather than diffed.
    let id: String
}

private struct SpotTokenDetailScreen: View {
    let token: TrendingSpotToken
    let model: AppModel
    @StateObject private var feed: SpotLiveFeed
    @Environment(\.dismiss) private var dismiss
    @State private var tab: SpotDetailTab = .transactions
    @State private var range = "1H"
    @State private var selectedWallet: SpotWallet?
    @State private var risk = TokenRiskModel()
    @State private var showsRisk = false

    private var quickRisk: RiskLevel {
        TokenRisk.quick(riskLevel: token.riskLevel, liquidity: token.liquidity, communityRecognized: token.communityRecognized)
    }
    @State private var tradeSide: String?
    @AppStorage("desk.spotWatchlist") private var savedSpotData = ""

    private var isSaved: Bool {
        SpotWatchlistStorage.contains(token, in: savedSpotData)
    }

    init(token: TrendingSpotToken, model: AppModel) {
        self.token = token
        self.model = model
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
                    // Rows pass under this bar as they scroll; the fade keeps them behind.
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
        .task(id: feed.holders.map(\.id)) { await IdentityDirectory.shared.resolve(feed.holders.map(\.wallet.address)) }
        .task(id: feed.transactions.map(\.wallet.address)) { await IdentityDirectory.shared.resolve(feed.transactions.map(\.wallet.address)) }
        .navigationDestination(item: $selectedWallet) { wallet in
            WalletProfileScreen(wallet: wallet, token: token, feed: feed, model: model)
                .toolbar(.hidden, for: .tabBar)
        }
        .sheet(isPresented: Binding(
            get: { tradeSide != nil },
            set: { if !$0 { tradeSide = nil } }
        )) {
            SpotTradeTicket(token: token, side: tradeSide ?? "Buy", model: model)
                .fittedSheet()
                .presentationDragIndicator(.visible)
        }
        .task { await risk.load(chainIndex: token.chainIndex, contract: token.contract, riskLevel: token.riskLevel, communityRecognized: token.communityRecognized) }
        .sheet(isPresented: $showsRisk) {
            RiskSheet(symbol: token.symbol, risk: risk.risk, fallback: quickRisk, failed: risk.failed)
                .fittedSheet()
                .presentationDragIndicator(.visible)
        }
        #if DEBUG
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-spot-buy") else { return }
            try? await Task.sleep(for: .milliseconds(800))
            tradeSide = "Buy"
        }
        // `-wallet-demo` opens the first holder with a resolved name, so the profile
        // can be captured without waiting on a wallet that has one.
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-wallet-demo") else { return }
            while feed.holders.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            let first = feed.holders[0].wallet
            IdentityDirectory.shared.seedForReview(first.address, name: "salmo.nad", source: "nad",
                                                   avatar: "https://euc.li/vitalik.eth",
                                                   bio: "Building on Monad. Long everything purple.", x: "salmo")
            withAnimation { tab = .holders }
            try? await Task.sleep(for: .seconds(4))
            selectedWallet = first
        }
        #endif
    }

    private func walletLabel(_ wallet: SpotWallet) -> String {
        IdentityDirectory.shared.name(for: wallet.address) ?? wallet.displayAddress
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
                Button { showsRisk = true } label: { RiskChip(level: risk.risk?.level ?? quickRisk) }
                    .buttonStyle(.plain)
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
            CandlestickChart(candles: feed.candles.map {
                ChartCandle(open: $0.open, high: $0.high, low: $0.low, close: $0.close)
            })
                .frame(height: 286)
                .accessibilityLabel("Live candlestick chart for \(token.symbol)")
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
                        HStack(spacing: 6) { WalletMark(wallet: tx.wallet); Text(walletLabel(tx.wallet)).underline() }
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
                        HStack { WalletMark(wallet: holder.wallet); Text(walletLabel(holder.wallet)).underline() }
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
            Button { showsRisk = true } label: {
                HStack {
                    Label("Risk", systemImage: "shield.lefthalf.filled").foregroundStyle(.secondary)
                    Spacer()
                    RiskChip(level: risk.risk?.level ?? quickRisk)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
                }
                .font(.system(size: 14, design: .rounded)).frame(height: 58)
                .padding(.horizontal, 14)
                .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .padding(.bottom, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let first = risk.risk?.reasons.first {
                Text(first.text)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(first.severity == "high" ? DeskColor.fall.color : DeskColor.action.color)
                    .padding(.bottom, 4)
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
            let (data, _) = try await ResponseCache.shared.data(from: components.url!)
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
        let url = components.url!
        // The chart as it was last drawn, so the screen opens on a line rather than a
        // spinner; the read that follows replaces it.
        if candles.isEmpty, let cached = await ResponseCache.shared.cached(url, maxAge: 3_600) {
            let currentSymbol = symbol
            if let payload = try? await Task.detached(priority: .utility, operation: {
                try Self.decodeSnapshot(cached, symbol: currentSymbol)
            }).value {
                candles = payload.candles
                transactions = payload.transactions
                latestPrice = candles.last?.close
                isLoading = false
            }
        }
        do {
            let (data, _) = try await ResponseCache.shared.data(from: url, maxStale: 3_600)
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
        guard let identity = row["id"] as? String,
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
                               amount: "\(amount) \(symbol)", value: spotPrice(volume), wallet: wallet,
                               id: identity)
    }

    nonisolated private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    nonisolated fileprivate static func compactUSD(_ value: Double?) -> String {
        guard let value, value.isFinite, value != 0 else { return "—" }
        return "$" + compactNumber(value)
    }

    nonisolated private static func count(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    nonisolated fileprivate static func compactNumber(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return value.formatted(.number.notation(.compactName).precision(.fractionLength(0...2)))
    }
}

private struct SpotTradeTicket: View {
    let token: TrendingSpotToken
    let side: String
    let model: AppModel

    var body: some View {
        if side == "Buy" {
            SpotBuyTicket(token: token, model: model)
        } else {
            SpotSellQuote(token: token, side: side)
        }
    }
}

private struct SpotBuyTicket: View {
    let token: TrendingSpotToken
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var purchase = SpotPurchaseModel()
    @State private var amount = ""
    @State private var copiedAddress = false

    /// Covers `depositNative`'s gas, about 38,000 at mainnet's fee, several times over.
    private static let gasReserve = NativeAmount(decimalText: "0.01")!

    private var typed: NativeAmount? { NativeAmount(decimalText: amount).flatMap { $0.isZero ? nil : $0 } }
    private var balance: NativeAmount? { model.mainnetMON.value }
    private var lacksFunds: Bool {
        guard let typed, let balance else { return false }
        return balance.raw < typed.raw + Self.gasReserve.raw
    }
    private var isBuyable: Bool { token.buyable ?? false }
    @State private var risk = TokenRiskModel()
    @State private var acknowledged = false
    @State private var quoteAge = 0

    private var firstTimeHere: Bool {
        guard let address = model.address else { return false }
        return !SpotPurchases.load(for: address).contains { $0.contract.caseInsensitiveCompare(token.contract) == .orderedSame }
    }

    private var presignWarnings: [PreSignWarning] {
        var out: [PreSignWarning] = []
        if let impact = purchase.quoted?.impactPercent.flatMap(Double.init) {
            let loss = -impact
            if loss >= 5 { out.append(.init(text: String(format: "Impact %.1f%%. You'd get about %.0f%% less than mid.", loss, loss), level: .high)) }
            else if loss >= 3 { out.append(.init(text: String(format: "Impact %.1f%%. Larger pools lose less.", loss), level: .caution)) }
            else if loss >= 1 { out.append(.init(text: String(format: "Impact %.1f%%.", loss), level: .info)) }
        }
        if quoteAge > 15 { out.append(.init(text: "Quote is \(quoteAge)s old. It is refreshed before signing.", level: .info)) }
        if let level = risk.risk?.level, level == .high, let reason = risk.risk?.reasons.first {
            out.append(.init(text: "High risk: \(reason.text.lowercased()).", level: .high))
        }
        if firstTimeHere { out.append(.init(text: "First time you're trading \(token.symbol).", level: .info)) }
        return out
    }

    private var presignSentence: String? {
        guard let quoted = purchase.quoted, let typed else { return nil }
        var parts = ["Buy ≈ \(SpotFormat.amount(quoted.receive.amount)) \(quoted.receive.symbol ?? token.symbol) with \(typed.display()) MON"]
        parts.append("fee $\(quoted.feeUsd)")
        if let seconds = quoted.seconds { parts.append("~\(seconds)s") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            payCard
            if purchase.phase.isActive || purchase.phase.isFinished {
                progress
            } else {
                receipt
                notices
                if let sentence = presignSentence {
                    PreSignPreview(sentence: sentence, warnings: presignWarnings, acknowledged: $acknowledged)
                }
            }
            Spacer(minLength: 0)
            action
            Label("Monad mainnet · real funds", systemImage: "exclamationmark.shield.fill")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(DeskColor.action.color)
                .frame(maxWidth: .infinity)
        }
        .padding(24)
        .preferredColorScheme(.dark)
        .task { await model.refreshMainnetMON() }
        .task { await risk.load(chainIndex: token.chainIndex, contract: token.contract, riskLevel: token.riskLevel, communityRecognized: token.communityRecognized) }
        #if DEBUG
        .onAppear { if ProcessInfo.processInfo.arguments.contains("-spot-buy"), amount.isEmpty { amount = "5" } }
        #endif
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                quoteAge = purchase.quoted == nil ? 0 : Int(Date.now.timeIntervalSince(purchase.quotedAt))
            }
        }
        .task(id: amount) {
            guard isBuyable, !purchase.phase.isActive, let address = model.address else { return }
            await purchase.quote(token: token, amount: amount, user: address)
        }
        .interactiveDismissDisabled(purchase.phase.isActive)
    }

    private var header: some View {
        HStack(spacing: 12) {
            MarketTokenLogo(symbol: token.symbol, size: 42, remoteURL: token.artworkURL)
            VStack(alignment: .leading, spacing: 2) {
                Text("Buy \(token.symbol)").font(.system(size: 22, weight: .heavy, design: .rounded))
                Text("Delivered on \(token.chainName)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.title2).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(purchase.phase.isActive)
        }
    }

    private var payCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("YOU PAY").font(.system(size: 10, weight: .heavy, design: .rounded)).tracking(1.2).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                TextField("0", text: $amount)
                    .keyboardType(.decimalPad)
                    .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                    .disabled(purchase.phase.isActive || purchase.phase.isFinished)
                HStack(spacing: 6) {
                    MarketTokenLogo(symbol: "MON", size: 20)
                    Text("MON").font(.system(size: 16, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.secondary)
            }
            HStack {
                Text("Balance \(balance.map { $0.display() } ?? "—") MON")
                    .foregroundStyle(lacksFunds ? DeskColor.fall.color : .secondary)
                Spacer()
                Text("Monad mainnet").foregroundStyle(.secondary)
            }
            .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
        }
        .padding(16)
        .perpSearchGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var receipt: some View {
        VStack(spacing: 9) {
            row("You receive", value: purchase.quoted.map { "≈ \(SpotFormat.amount($0.receive.amount)) \($0.receive.symbol ?? token.symbol)" },
                emphasised: true)
            row("At least", value: purchase.quoted.map { "\(SpotFormat.amount($0.receive.minimum)) \($0.receive.symbol ?? token.symbol)" })
            row("Network and fill fees", value: purchase.quoted.map { "$\($0.feeUsd)" })
            row("Arrives in", value: purchase.quoted.map { $0.seconds.map { "~\($0) s" } ?? "—" })
        }
        .font(.system(size: 13, design: .rounded))
        .redacted(reason: purchase.isQuoting ? .placeholder : [])
    }

    private func row(_ title: String, value: String?, emphasised: Bool = false) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value ?? "—")
                .fontWeight(emphasised ? .bold : .semibold)
                .foregroundStyle(emphasised ? .primary : .secondary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    @ViewBuilder
    private var notices: some View {
        if let impact = purchase.quoted?.impactPercent.flatMap(Double.init), impact <= -5 {
            Label("Fees and price impact take \(String(format: "%.1f", -impact))% of this buy. Larger amounts lose less.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.yellow)
        }
        if let error = purchase.quoteError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.yellow)
        }
        if token.communityRecognized == false || (token.liquidity ?? .greatestFiniteMagnitude) < 10_000 {
            Text("Verify the contract and liquidity independently before trading.")
                .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.yellow)
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 12) {
            step("Signed with Face ID", state: purchase.phase.stepState(0))
            step("MON deposited on Monad · not filled yet", state: purchase.phase.stepState(1))
            step("Filled on \(token.chainName)", state: purchase.phase.stepState(2))
            switch purchase.phase {
            case .filled:
                Text("Bought ≈ \(SpotFormat.amount(purchase.quoted?.receive.amount)) \(token.symbol)")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.rise.color)
                    .padding(.top, 4)
            case .refunded:
                Text("Relay could not fill this and refunded your MON.")
                    .font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.yellow)
            case .failed(let sentence):
                Text(sentence)
                    .font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(DeskColor.fall.color)
            default:
                EmptyView()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .perpSearchGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func step(_ title: String, state: SpotPurchaseModel.StepState) -> some View {
        HStack(spacing: 10) {
            Group {
                switch state {
                case .waiting: Image(systemName: "circle").foregroundStyle(.secondary)
                case .running: ProgressView().controlSize(.small)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(DeskColor.rise.color)
                case .stopped: Image(systemName: "xmark.circle.fill").foregroundStyle(DeskColor.fall.color)
                }
            }
            .frame(width: 20)
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(state == .waiting ? .secondary : .primary)
        }
    }

    @ViewBuilder
    private var action: some View {
        if !isBuyable {
            statusCapsule(token.chainIndex == "501"
                ? "Buying Solana tokens is not available yet"
                : "Buying on \(token.chainName) is not available yet")
        } else if purchase.phase.isFinished {
            HStack(spacing: 10) {
                if let url = purchase.trackingURL {
                    Link(destination: url) {
                        Text("View on Relay").frame(maxWidth: .infinity).frame(height: 54).contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .background(Color.white.opacity(0.1), in: Capsule())
                }
                Button { dismiss() } label: {
                    Text("Done").frame(maxWidth: .infinity).frame(height: 54).contentShape(Capsule())
                }
                .buttonStyle(.plain).foregroundStyle(.black).background(.white, in: Capsule())
            }
            .font(.system(size: 16, weight: .bold, design: .rounded))
        } else if purchase.phase.isActive {
            statusCapsule(purchase.phase.sentence(chain: token.chainName), spinning: true)
        } else if lacksFunds {
            VStack(spacing: 8) {
                statusCapsule("Not enough MON on Monad mainnet")
                Button {
                    model.copyAddress()
                    copiedAddress = true
                } label: {
                    Label(copiedAddress ? "Address copied" : "Copy address to add MON",
                          systemImage: copiedAddress ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity).frame(height: 36).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        } else {
            HoldToConfirm(
                title: purchase.quoted == nil ? "Enter an amount" : "Hold to buy \(token.symbol)",
                tint: DeskColor.rise,
                isEnabled: purchase.quoted != nil && typed != nil && !purchase.isQuoting
                    && (!presignWarnings.contains { $0.level == .high } || acknowledged)
            ) {
                guard let typed else { return }
                Task { await purchase.buy(token: token, amount: amount, typed: typed, model: model) }
            }
        }
    }

    private func statusCapsule(_ text: String, spinning: Bool = false) -> some View {
        HStack(spacing: 8) {
            if spinning { ProgressView().controlSize(.small) }
            Text(text).lineLimit(1).minimumScaleFactor(0.8)
        }
        .font(.system(size: 14, weight: .semibold, design: .rounded))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity).frame(height: 54)
        .background(Color.white.opacity(0.06), in: Capsule())
    }
}

@MainActor
private enum SpotFormat {
    private static let significant: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesSignificantDigits = true
        formatter.maximumSignificantDigits = 6
        return formatter
    }()

    /// Quote amounts arrive with up to eighteen places; six significant digits is what a
    /// person compares.
    static func amount(_ text: String?) -> String {
        guard let text, let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else { return "—" }
        return significant.string(from: value as NSDecimalNumber) ?? text
    }
}

private struct RelayQuote: Decodable, Sendable {
    struct Side: Decodable, Sendable {
        let amount: String?
        let minimum: String?
        let usd: String?
        let symbol: String?
    }
    struct Transaction: Decodable, Sendable {
        let chainId: UInt64
        let to: String
        let data: String
        let value: String
    }
    let requestId: String
    let receive: Side
    let feeUsd: String
    let impactPercent: String?
    let seconds: Int?
    let transaction: Transaction
}

@MainActor
private final class SpotPurchaseModel: ObservableObject {
    enum Phase: Equatable {
        case idle, signing, filling, filled, refunded
        case failed(String)

        var isActive: Bool { self == .signing || self == .filling }
        var isFinished: Bool {
            switch self {
            case .filled, .refunded, .failed: true
            default: false
            }
        }

        func stepState(_ index: Int) -> StepState {
            switch (self, index) {
            case (.signing, 0), (.signing, 1): .running
            case (.filling, 0), (.filling, 1), (.filled, _), (.refunded, 0), (.refunded, 1): .done
            case (.filling, 2): .running
            case (.refunded, 2): .stopped
            case (.failed, _): .stopped
            default: .waiting
            }
        }

        func sentence(chain: String) -> String {
            self == .signing ? "Confirm with Face ID…" : "Filling on \(chain)…"
        }
    }

    enum StepState { case waiting, running, done, stopped }

    @Published private(set) var quoted: RelayQuote?
    @Published private(set) var quoteError: String?
    @Published private(set) var isQuoting = false
    @Published private(set) var phase: Phase = .idle
    private(set) var quotedAt = Date.distantPast
    private var requestId: String?

    private static let host = "https://web-lovat-nine-49.vercel.app"

    var trackingURL: URL? { requestId.flatMap { URL(string: "https://relay.link/transaction/\($0)") } }

    func quote(token: TrendingSpotToken, amount: String, user: EthereumAddress, debounce: Bool = true) async {
        quoteError = nil
        guard let typed = NativeAmount(decimalText: amount), !typed.isZero else {
            quoted = nil
            return
        }
        isQuoting = true
        defer { isQuoting = false }
        if debounce {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
        }
        var components = URLComponents(string: "\(Self.host)/api/relay-quote")!
        components.queryItems = [
            URLQueryItem(name: "user", value: user.checksummed),
            URLQueryItem(name: "chainIndex", value: token.chainIndex),
            URLQueryItem(name: "tokenAddress", value: token.contract),
            URLQueryItem(name: "amount", value: amount),
        ]
        do {
            let (data, response) = try await URLSession.shared.data(from: components.url!)
            guard !Task.isCancelled else { return }
            if (response as? HTTPURLResponse)?.statusCode == 200 {
                quoted = try JSONDecoder().decode(RelayQuote.self, from: data)
                quotedAt = .now
            } else {
                quoted = nil
                let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                quoteError = body?["error"] as? String ?? "A live quote is unavailable right now."
            }
        } catch {
            guard !Task.isCancelled else { return }
            quoted = nil
            quoteError = "The quote service could not be reached."
        }
    }

    func buy(token: TrendingSpotToken, amount: String, typed: NativeAmount, model: AppModel) async {
        guard let wallet = model.address, !phase.isActive else { return }
        // Relay prices hold for about thirty seconds; an older quote is refreshed rather
        // than filled at a rate that has already moved.
        if Date.now.timeIntervalSince(quotedAt) > 20 {
            await quote(token: token, amount: amount, user: wallet, debounce: false)
        }
        guard let quoted else { return }
        let deposit: RelayDeposit
        do {
            deposit = try RelayDeposit(
                chainID: quoted.transaction.chainId, to: quoted.transaction.to,
                data: quoted.transaction.data, value: quoted.transaction.value,
                wallet: wallet, amount: typed)
        } catch {
            phase = .failed("This quote did not pass Desk's safety check, so nothing was signed.")
            return
        }

        requestId = quoted.requestId
        phase = .signing
        do {
            try await model.buy(deposit)
        } catch PasskeyFailure.cancelledByUser {
            phase = .idle
            return
        } catch let failure as PasskeyFailure {
            phase = .failed(failure.sentence)
            return
        } catch TransactionSender.Failure.reverted {
            phase = .failed("The deposit was rejected on Monad. Only gas was spent.")
            return
        } catch TransactionSender.Failure.notMinedInTime {
            phase = .filling
            await track(quoted.requestId)
            remember(token, quoted, wallet: wallet)
            return
        } catch {
            phase = .failed("The deposit could not be sent. No MON was taken.")
            return
        }
        phase = .filling
        await track(quoted.requestId)
        remember(token, quoted, wallet: wallet)
    }

    /// A fill is a holding. Recorded on the device so Home can ask the chain about it.
    private func remember(_ token: TrendingSpotToken, _ quoted: RelayQuote, wallet: EthereumAddress) {
        guard phase == .filled else { return }
        SpotPurchases.record(SpotPurchase(
            chainIndex: token.chainIndex, chainName: token.chainName, contract: token.contract,
            symbol: token.symbol, name: token.name, logoURL: token.logoURL,
            paidUSD: quoted.receive.usd.flatMap(Double.init), boughtAt: .now), for: wallet)
    }

    private func track(_ requestId: String) async {
        let deadline = Date.now.addingTimeInterval(120)
        while Date.now < deadline, !Task.isCancelled {
            if let url = URL(string: "\(Self.host)/api/relay-status?requestId=\(requestId)"),
               let (data, _) = try? await URLSession.shared.data(from: url),
               let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                switch body["phase"] as? String {
                case "filled": phase = .filled; return
                case "refunded": phase = .refunded; return
                case "failed": phase = .failed("Relay could not fill this. Any MON not refunded shows on Relay."); return
                default: break
                }
            }
            try? await Task.sleep(for: .milliseconds(1500))
        }
        phase = .failed("Still filling. Check Relay for the latest status.")
    }
}

private struct SpotSellQuote: View {
    let token: TrendingSpotToken
    let side: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var quote = SpotQuoteModel()
    @State private var amount = ""

    /// From the feed, which reads one chain table. The switch that used to be here
    /// answered "ETH" for every chain it had not heard of, Arc included, whose gas token
    /// is USDC.
    private var nativeSymbol: String { token.nativeSymbol ?? "native token" }

    private var isQuotable: Bool { token.quotable ?? true }

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

            if isQuotable {
                Button { Task { await quote.fetch(token: token, side: side, amount: amount) } } label: {
                    HStack {
                        if quote.isLoading { ProgressView().tint(.black) }
                        Text(quote.output == nil ? "Get live quote" : "Refresh quote")
                        Spacer(); Image(systemName: "arrow.right")
                    }
                    .font(.system(size: 16, weight: .bold, design: .rounded)).padding(.horizontal, 18)
                    .frame(maxWidth: .infinity).frame(height: 54)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain).foregroundStyle(.black).background(.white, in: Capsule())
                .disabled(amount.isEmpty || quote.isLoading).opacity(amount.isEmpty ? 0.35 : 1)
            } else {
                // Said before an amount is typed rather than after a quote fails.
                Label("No quote provider covers \(token.chainName) yet.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.yellow)
                    .frame(maxWidth: .infinity).frame(height: 54)
                    .background(Color.white.opacity(0.06), in: Capsule())
            }

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
        // The discovery feed carries no decimal for any token it trends, so requiring one
        // here stopped every quote before it was sent. The server resolves it from the
        // chain; a hint is passed only when there is one.
        var components = URLComponents(string: "https://web-lovat-nine-49.vercel.app/api/swap-quote")!
        var items = [
            URLQueryItem(name: "chainIndex", value: token.chainIndex),
            URLQueryItem(name: "tokenAddress", value: token.contract),
            URLQueryItem(name: "side", value: side.lowercased()),
            URLQueryItem(name: "amount", value: amount)
        ]
        if let decimals = token.decimals.map(Int.init) {
            items.append(URLQueryItem(name: "tokenDecimals", value: String(decimals)))
        }
        components.queryItems = items
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

private struct WalletMark: View {
    let wallet: SpotWallet
    var size: CGFloat = 16

    var body: some View {
        if let url = IdentityDirectory.shared.identity(for: wallet.address)?.avatarURL {
            AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Text(wallet.emoji) }
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            Text(wallet.emoji)
        }
    }
}

private struct WalletResource: Decodable {
    struct Held: Decodable { let balance: Double; let value: Double? }
    struct Holding: Decodable, Identifiable {
        let chainIndex: String
        let chain: String?
        let contract: String
        let symbol: String
        let balance: Double
        let value: Double?
        var id: String { chainIndex + ":" + contract }
    }
    struct Window: Decodable { let realized: Double; let trades: Int; let winRate: Double? }
    struct Position: Decodable, Identifiable {
        let token: String
        let symbol: String
        let holding: Double
        let value: Double?
        let realized: Double
        let unrealized: Double?
        var id: String { token }
    }
    struct Trade: Decodable, Identifiable {
        let time: Double
        let hash: String
        let token: String
        let symbol: String
        let side: String
        let amount: Double
        let value: Double
        let gain: Double?
        var id: String { hash + symbol + side }
        var isBuy: Bool { side == "buy" }
    }
    struct Ledger: Decodable {
        let status: String
        let behind: Int?
        let realized: Double?
        let unrealized: Double?
        let winRate: Double?
        let last7d: Window?
        let last30d: Window?
        let tokens: [Position]?
        let trades: [Trade]?
    }
    let portfolio: Double?
    let chains: [WalletChain]
    let held: Held?
    let holdings: [Holding]
    let ledger: Ledger
    let labels: [WalletLabel]?
    let logos: [String: String]?
    struct WalletChain: Decodable { let chainIndex: String; let chain: String?; let value: Double }
    struct WalletLabel: Decodable, Identifiable { let code: String; let text: String; var id: String { code } }
}

private struct WalletProfileScreen: View {
    let wallet: SpotWallet
    let token: TrendingSpotToken
    @ObservedObject var feed: SpotLiveFeed
    let model: AppModel
    @StateObject private var lookup = TokenDiscoveryModel()
    @State private var opened: TrendingSpotToken?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var resource: WalletResource?
    @State private var resourceFailed = false
    @State private var perplDirectory = TraderDirectory()
    @State private var showsPerpl = false
    @State private var tab: Tab = .positions
    @State private var naming = false
    @State private var draftName = ""
    @State private var copied = false

    private enum Tab: String, CaseIterable { case positions = "Positions", closed = "Closed", activity = "Activity" }

    private struct Row: Identifiable {
        let id: String
        let symbol: String
        let title: String
        let subtitle: String
        let value: String
        let detail: String?
        let tint: Color
        let badge: String?
        let day: String
        var chainIndex = "143"
        var contract = ""
        var chainName: String? = nil
    }

    private func logo(_ chainIndex: String, _ contract: String) -> URL? {
        if chainIndex == token.chainIndex, contract.caseInsensitiveCompare(token.contract) == .orderedSame, let own = token.artworkURL { return own }
        return (resource?.logos?["\(chainIndex):\(contract.lowercased())"]).flatMap(TokenArtwork.url)
    }

    private var identity: Identity? { IdentityDirectory.shared.identity(for: wallet.address) }
    private var tracked: TrackedWallet? { TrackedWallets.shared.wallet(for: wallet.address) }
    private var isEVM: Bool { wallet.address.hasPrefix("0x") && wallet.address.count == 42 }
    private var ledger: WalletResource.Ledger? { resource.map(\.ledger).flatMap { $0.status == "unavailable" ? nil : $0 } }
    private var name: String {
        if let name = identity?.name { return name }
        if let tracked, !tracked.name.isEmpty { return tracked.name }
        return wallet.displayAddress
    }
    private var portfolioText: String {
        if let value = resource?.portfolio { return SpotLiveFeed.compactUSD(value) }
        return resource == nil && !resourceFailed ? "—" : wallet.portfolio
    }
    private var portfolioLabel: String {
        guard let resource, resource.portfolio != nil, resource.chains.count > 1 else { return "Portfolio" }
        return "Across \(resource.chains.count) chains"
    }
    private var totalPnL: Double? {
        guard let ledger, ledger.realized != nil || ledger.unrealized != nil else { return nil }
        return (ledger.realized ?? 0) + (ledger.unrealized ?? 0)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Button { dismiss() } label: { Image(systemName: "chevron.left").frame(width: 50, height: 50) }.perpSearchGlass(in: Circle())
                        Spacer()
                        ShareLink(item: wallet.address) { Image(systemName: "square.and.arrow.up").frame(width: 50, height: 50) }.perpSearchGlass(in: Circle())
                    }.font(.system(size: 18, weight: .bold)).foregroundStyle(.white)

                    HStack(spacing: 0) {
                        avatar
                        Spacer(minLength: 14)
                        stat(portfolioText, label: portfolioLabel, tint: .white)
                        Divider().frame(height: 38).overlay(Color.white.opacity(0.12)).padding(.horizontal, 18)
                        stat(totalPnL.map(signed) ?? "—", label: "Total PnL", tint: totalPnL.map(tint) ?? .white)
                        Spacer(minLength: 0)
                    }.padding(.top, 30)

                    HStack(spacing: 10) {
                        Button {
                            UIPasteboard.general.string = wallet.address
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation(.snappy(duration: 0.2)) { copied = true }
                            Task { try? await Task.sleep(for: .seconds(1.4)); withAnimation { copied = false } }
                        } label: {
                            Text(copied ? "Copied" : name)
                                .font(.system(size: 21, weight: .bold, design: .rounded))
                                .lineLimit(1).minimumScaleFactor(0.6)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Spacer(minLength: 8)
                        if isEVM {
                            action(tracked == nil ? "Follow" : "Following", symbol: nil) {
                                if identity?.perplAccount != nil, perplDirectory.isFollowing(wallet.address) == (tracked != nil) {
                                    perplDirectory.toggle(wallet.address)
                                } else if tracked == nil {
                                    TrackedWallets.shared.track(wallet.address, name: identity?.name ?? "")
                                } else {
                                    TrackedWallets.shared.untrack(wallet.address)
                                }
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            }
                            action("Set Name", symbol: "pencil") {
                                draftName = tracked?.name ?? ""
                                naming = true
                            }
                        }
                    }.padding(.top, 20)

                    if let status = statusLine {
                        Button { statusAction() } label: {
                            HStack(spacing: 7) {
                                Circle().fill(statusTint).frame(width: 7, height: 7)
                                Text(status).font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.8))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 10)
                    }

                    tabs.padding(.top, 18)
                    content.padding(.top, 4)
                }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 40)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $showsPerpl) {
            if let copier = CopyTrader.current {
                TraderProfileScreen(
                    initial: TraderSnapshot(accountId: identity?.perplAccount, address: wallet.address,
                                            pnl: nil, balance: nil, positions: []),
                    directory: perplDirectory, copier: copier, onCopy: { _ in })
            }
        }
        .alert("Name this wallet", isPresented: $naming) {
            TextField("Name", text: $draftName)
            Button("Save") {
                let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                if let tracked { TrackedWallets.shared.update(TrackedWallet(address: tracked.address, name: String(trimmed.prefix(24)), minUsd: tracked.minUsd, firstBuysOnly: tracked.firstBuysOnly)) }
                else { TrackedWallets.shared.track(wallet.address, name: trimmed) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Shown wherever this wallet appears on your phone.")
        }
        .task { await IdentityDirectory.shared.resolve([wallet.address]) }
        .task { await loadResource() }
        .navigationDestination(item: $opened) { token in
            SpotTokenDetailScreen(token: token, model: model)
        }
        #if DEBUG
        .onAppear { if ProcessInfo.processInfo.arguments.contains("-wallet-activity") { tab = .activity } }
        #endif
    }

    /// The real listing when the discovery feed knows the token, so the page has its
    /// chart and figures; the wallet's own facts when it does not.
    private func open(_ row: Row) {
        guard !row.contract.isEmpty else { return }
        if row.chainIndex == token.chainIndex, row.contract.caseInsensitiveCompare(token.contract) == .orderedSame {
            dismiss()
            return
        }
        Task {
            await lookup.search(row.contract)
            let match = (lookup.searchResults + lookup.trending).first {
                $0.chainIndex == row.chainIndex && $0.contract.caseInsensitiveCompare(row.contract) == .orderedSame
            }
            opened = match ?? TrendingSpotToken(
                id: "\(row.chainIndex):\(row.contract)", chainIndex: row.chainIndex, chainName: row.chainName ?? token.chainName,
                symbol: row.symbol, name: row.symbol, logoURL: resource?.logos?["\(row.chainIndex):\(row.contract.lowercased())"] ?? "",
                contract: row.contract, decimals: nil, quotable: nil, buyable: nil, nativeSymbol: nil, explorerURL: "",
                price: nil, change: nil, marketCap: nil, volume24H: nil, liquidity: nil, holders: nil,
                communityRecognized: nil, riskLevel: nil)
        }
    }

    // MARK: Header pieces

    private var avatar: some View {
        Group {
            if let url = identity?.avatarURL {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Text(wallet.emoji).font(.system(size: 50)) }
            } else {
                Text(wallet.emoji).font(.system(size: 50))
            }
        }
        .frame(width: 68, height: 68)
        .clipShape(Circle())
        .perpSearchGlass(in: Circle())
    }

    private func stat(_ value: String, label: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.system(size: 17, weight: .bold, design: .rounded).monospacedDigit()).foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
    }

    private func action(_ title: String, symbol: String?, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .frame(height: 34)
            .background(Color.black, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var statusLine: String? {
        var parts: [String] = []
        if let label = identity?.sourceLabel { parts.append(label) }
        if let account = identity?.perplAccount { parts.append("Perpl #\(account)") }
        if parts.isEmpty, let first = resource?.labels?.first { parts.append(first.text) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var statusTint: Color {
        if identity?.sourceLabel != nil || identity?.perplAccount != nil { return DeskColor.rise.color }
        return DeskColor.nightMuted.color
    }

    private func statusAction() {
        if identity?.perplAccount != nil, CopyTrader.current != nil { showsPerpl = true }
        else if let url = identity?.profileURL { openURL(url) }
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { item in
                Button { withAnimation(.snappy(duration: 0.22)) { tab = item } } label: {
                    VStack(spacing: 10) {
                        Text(item.rawValue)
                            .font(.system(size: 14, weight: tab == item ? .bold : .medium, design: .rounded))
                            .foregroundStyle(tab == item ? .white : Color.white.opacity(0.45))
                        Rectangle().fill(tab == item ? Color.white : .clear).frame(height: 2)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.1)).frame(height: 0.5) }
        .padding(.horizontal, -20)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let rows = rows(for: tab)
        if resource == nil, !resourceFailed, isEVM, rows.isEmpty {
            VStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { _ in
                    HStack(spacing: 14) {
                        Circle().fill(Color.white.opacity(0.08)).frame(width: 46, height: 46)
                        VStack(alignment: .leading, spacing: 8) { SkeletonRow(widthFraction: 0.5); SkeletonRow(widthFraction: 0.3) }
                    }
                    .frame(height: 78)
                }
            }
        } else {
            let days = Array(NSOrderedSet(array: rows.map(\.day))) as? [String] ?? []
            ForEach(days, id: \.self) { day in
                if tab != .positions {
                    Text(day)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.top, 16)
                        .padding(.bottom, 2)
                }
                ForEach(rows.filter { $0.day == day }) { row in
                    Button { open(row) } label: { tokenRow(row) }.buttonStyle(.plain)
                }
            }
        }
    }

    private func tokenRow(_ row: Row) -> some View {
        HStack(spacing: 12) {
            MarketTokenLogo(symbol: row.symbol, size: 38, remoteURL: logo(row.chainIndex, row.contract))
                .overlay(alignment: .bottomTrailing) {
                    if let badge = row.badge {
                        Image(systemName: badge == "+" ? "plus.circle.fill" : "minus.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(.white, badge == "+" ? DeskColor.rise.color : DeskColor.fall.color)
                            .background(Circle().fill(.black).padding(1))
                            .offset(x: 3, y: 3)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(.white).lineLimit(1)
                Text(row.subtitle).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(row.value).font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit()).foregroundStyle(.white).lineLimit(1)
                if let detail = row.detail {
                    Text(detail).font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(row.tint).lineLimit(1)
                }
            }
        }
        .frame(height: 62)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5).padding(.leading, 50) }
    }

    private func rows(for tab: Tab) -> [Row] {
        switch tab {
        case .positions:
            let unrealized = Dictionary((ledger?.tokens ?? []).map { ($0.token.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
            return (resource?.holdings ?? []).map { holding in
                let position = holding.chainIndex == "143" ? unrealized[holding.contract.lowercased()] : nil
                return Row(id: holding.id, symbol: holding.symbol, title: holding.symbol,
                           subtitle: SpotLiveFeed.compactNumber(holding.balance),
                           value: holding.value.map { SpotLiveFeed.compactUSD($0) } ?? "—",
                           detail: position?.unrealized.map(signed) ?? holding.chain,
                           tint: position?.unrealized.map(tint) ?? Color.white.opacity(0.45), badge: nil, day: "",
                           chainIndex: holding.chainIndex, contract: holding.contract, chainName: holding.chain)
            }
        case .closed:
            return (ledger?.trades ?? []).filter { $0.side == "sell" && $0.gain != nil }.map { trade in
                let gain = trade.gain ?? 0
                let cost = trade.value - gain
                let percent = cost > 0 ? gain / cost * 100 : nil
                return Row(id: trade.id, symbol: trade.symbol, title: trade.symbol, subtitle: Self.age(trade.time),
                           value: signed(gain), detail: percent.map { String(format: "%@%.1f%%", $0 >= 0 ? "+" : "−", abs($0)) },
                           tint: tint(gain), badge: nil, day: Self.day(trade.time), contract: trade.token)
            }
        case .activity:
            if let trades = ledger?.trades, !trades.isEmpty {
                return trades.map { trade in
                    Row(id: trade.id, symbol: trade.symbol, title: "\(trade.isBuy ? "Bought" : "Sold") \(trade.symbol)", subtitle: Self.age(trade.time),
                        value: SpotLiveFeed.compactUSD(trade.value),
                        detail: "\(trade.isBuy ? "+" : "−")\(SpotLiveFeed.compactNumber(trade.amount)) \(trade.symbol)",
                        tint: Color.white.opacity(0.55), badge: trade.isBuy ? "+" : "−", day: Self.day(trade.time), contract: trade.token)
                }
            }
            return feed.transactions.filter { $0.wallet.address.caseInsensitiveCompare(wallet.address) == .orderedSame }.map { tx in
                Row(id: tx.id, symbol: token.symbol, title: "\(tx.isBuy ? "Bought" : "Sold") \(token.symbol)", subtitle: "\(tx.age) ago",
                    value: tx.value, detail: "\(tx.isBuy ? "+" : "−")\(tx.amount)", tint: Color.white.opacity(0.55),
                    badge: tx.isBuy ? "+" : "−", day: "Today", chainIndex: token.chainIndex, contract: token.contract, chainName: token.chainName)
            }
        }
    }

    private func signed(_ value: Double) -> String {
        let body = SpotLiveFeed.compactUSD(abs(value))
        return value < 0 ? "−" + body : (value > 0 ? "+" + body : body)
    }

    private func tint(_ value: Double) -> Color {
        value > 0 ? DeskColor.rise.color : (value < 0 ? DeskColor.fall.color : .white)
    }

    private static func age(_ time: Double) -> String {
        let seconds = Date.now.timeIntervalSince(Date(timeIntervalSince1970: time / 1000))
        if seconds < 60 { return "\(max(1, Int(seconds)))s ago" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }

    private static func day(_ time: Double) -> String {
        let date = Date(timeIntervalSince1970: time / 1000)
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    private func loadResource() async {
        guard isEVM else { resourceFailed = true; return }
        var components = URLComponents(string: "https://web-lovat-nine-49.vercel.app/api/activity")!
        components.queryItems = [
            URLQueryItem(name: "view", value: "wallet"),
            URLQueryItem(name: "address", value: wallet.address),
            URLQueryItem(name: "chainIndex", value: token.chainIndex),
            URLQueryItem(name: "contract", value: token.contract),
        ]
        guard let url = components.url else { return }
        do {
            let (data, _) = try await ResponseCache.shared.data(from: url, maxStale: 300)
            resource = try JSONDecoder().decode(WalletResource.self, from: data)
            if resource?.ledger.status == "indexing" {
                try? await Task.sleep(for: .seconds(8))
                if let (fresh, _) = try? await ResponseCache.shared.data(from: url, maxStale: 0),
                   let again = try? JSONDecoder().decode(WalletResource.self, from: fresh) { resource = again }
            }
        } catch {
            resourceFailed = true
        }
    }
}
