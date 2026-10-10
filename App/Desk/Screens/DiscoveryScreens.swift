import DeskAuth
import DeskChain
import DeskMoney
import DeskPerpl
import DeskUI
import Combine
import Foundation
import SwiftUI

struct WatchlistSection: View {
    let market: MarketModel
    let onOpenMarket: (Market) -> Void
    let onOpenSpot: (TrendingSpotToken) -> Void
    @State private var isEditing = false
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

    private func refreshSpotFigures() async {
        let saved = spotRows
        guard !saved.isEmpty else { return }
        var components = URLComponents(string: "https://web-lovat-nine-49.vercel.app/api/token-details")!
        components.queryItems = [
            URLQueryItem(name: "view", value: "prices"),
            URLQueryItem(name: "tokens", value: saved.prefix(20).map { "\($0.chainIndex):\($0.contract)" }.joined(separator: ",")),
        ]
        guard let url = components.url,
              let (data, _) = try? await ResponseCache.shared.data(from: url, maxStale: 0),
              let body = try? JSONDecoder().decode(SpotFigures.Response.self, from: data) else { return }
        let refreshed = saved.map { token -> TrendingSpotToken in
            guard let figures = body.prices.first(where: { $0.chainIndex == token.chainIndex && $0.contract.caseInsensitiveCompare(token.contract) == .orderedSame }) else { return token }
            return token.with(figures)
        }
        if let encoded = try? JSONEncoder().encode(refreshed), let text = String(data: encoded, encoding: .utf8) { savedSpotData = text }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(rows.isEmpty && spotRows.isEmpty
                     ? "Nothing saved yet"
                     : "\(rows.count + spotRows.count) saved")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
                Spacer()
                if !(rows.isEmpty && spotRows.isEmpty) {
                    Button(isEditing ? "Done" : "Edit") {
                        withAnimation(.easeInOut(duration: 0.2)) { isEditing.toggle() }
                    }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
                    .frame(height: 30)
                    .padding(.horizontal, 12)
                    .background(Color.white.opacity(0.1), in: Capsule())
                    .buttonStyle(.plain)
                }
            }

            if rows.isEmpty && spotRows.isEmpty {
                empty.padding(.top, 30)
            } else {
                VStack(spacing: 10) {
                    ForEach(spotRows) { token in
                        ZStack(alignment: .trailing) {
                            Button { onOpenSpot(token) } label: {
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
                            onOpen: { onOpenMarket(entry) },
                            onToggle: { toggle(entry.id) })
                    }
                }
                .padding(.top, 14)
            }
        }
        .task(id: spotRows.map(\.id).joined(separator: ",")) {
            while !Task.isCancelled {
                await refreshSpotFigures()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "star")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(DeskColor.nightMuted.color)
            Text("Star a market to keep it here")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(DeskColor.nightText.color)
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
        TradeAlerts.shared.watchlistChanged()
    }

    private func remove(_ token: TrendingSpotToken) {
        savedSpotData = SpotWatchlistStorage.toggling(token, in: savedSpotData)
    }
}

struct MarketSearchScreen: View {
    let model: AppModel
    let market: MarketModel
    let session: TradingSession
    let onOrderFilled: (Direction, String) -> Void
    @State private var query = ""
    @State private var showsMarket = false
    @State private var selectedSpot: TrendingSpotToken?
    @State private var selectedPerson: SpotWallet?
    @State private var person: (address: String, identity: Identity?)?
    @State private var isLookingUpName = false
    @State private var nameWasNotFound = false
    @State private var nameLookupUnavailable = false
    @StateObject private var discovery = TokenDiscoveryModel()
    @Namespace private var navigationSpace

    private var looksLikeAName: Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasPrefix("@") || text.hasPrefix("0x")
            || text.contains(".") && !text.contains(" ")
    }
    @AppStorage("desk.watchlist") private var savedIDs = ""

    private var saved: Set<UInt32> {
        Set(savedIDs.split(separator: ",").compactMap { UInt32($0) })
    }

    private static let marketNames: [String: String] = [
        "BTC": "Bitcoin", "ETH": "Ethereum", "SOL": "Solana", "MON": "Monad", "ZEC": "Zcash",
        "HYPE": "Hyperliquid", "LIT": "Lighter", "PUMP": "Pump", "VVV": "Venice", "NEAR": "NEAR Protocol", "DOGE": "Dogecoin", "XRP": "Ripple",
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

    private var peopleRows: [(address: String, identity: Identity?)] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var rows: [(address: String, identity: Identity?)] = []
        if let person { rows.append(person) }
        for match in IdentityDirectory.shared.matches(query) where !rows.contains(where: { $0.address.lowercased() == match.address.lowercased() }) {
            rows.append((match.address, match))
        }
        return rows
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

                    let people = peopleRows
                    if looksLikeAName && isLookingUpName {
                        ProgressView("Looking up name…")
                            .font(DeskType.caption)
                            .foregroundStyle(DeskColor.nightMuted.color)
                            .padding(.top, 18)
                    } else if looksLikeAName && nameWasNotFound && people.isEmpty {
                        Text(query.lowercased().hasSuffix(".solana")
                             ? "No .sol name found. .solana is not an SNS extension."
                             : "No blockchain name or wallet found for “\(query)”.")
                            .font(DeskType.caption)
                            .foregroundStyle(DeskColor.nightMuted.color)
                            .padding(.top, 18)
                    } else if looksLikeAName && nameLookupUnavailable && people.isEmpty {
                        Text("Name lookup is unavailable. Check your connection and try again.")
                            .font(DeskType.caption)
                            .foregroundStyle(DeskColor.nightMuted.color)
                            .padding(.top, 18)
                    }
                    if !people.isEmpty {
                        Text("Wallets")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(DeskColor.nightText.color)
                            .padding(.top, 26)
                        VStack(spacing: 10) {
                            ForEach(people, id: \.address) { entry in
                                Button { selectedPerson = SpotWallet(address: entry.address, emoji: "◉", portfolio: "—") } label: {
                                    HStack(spacing: 13) {
                                        if TrackedWallets.isSolana(entry.address) {
                                            Image(systemName: "circle.hexagongrid.fill")
                                                .font(.system(size: 19, weight: .medium))
                                                .foregroundStyle(DeskColor.action.color)
                                                .frame(width: 42, height: 42)
                                                .background(DeskColor.action.color.opacity(0.14), in: Circle())
                                        } else {
                                            TraderAvatar(address: entry.address, size: 42)
                                        }
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(entry.identity?.name ?? TraderSnapshot.short(entry.address))
                                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                                .foregroundStyle(DeskColor.nightText.color)
                                                .lineLimit(1)
                                            Text("\(entry.identity?.sourceLabel ?? (TrackedWallets.isSolana(entry.address) ? "Solana wallet" : "Wallet")) · \(TraderSnapshot.short(entry.address))")
                                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                                .foregroundStyle(DeskColor.nightMuted.color)
                                                .lineLimit(1)
                                        }
                                        Spacer(minLength: 8)
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(DeskColor.nightMuted.color)
                                    }
                                    .padding(.horizontal, 14)
                                    .frame(height: 64)
                                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(DeskPressStyle())
                            }
                        }
                        .padding(.top, 12)
                    }

                    if !looksLikeAName {
                    Text("Trade markets")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                        .padding(.top, 32)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(Array(market.allMarkets.prefix(4)), id: \.id) { entry in
                                Button { open(entry) } label: {
                                    SearchMarketCard(model: market, market: entry)
                                }
                                .buttonStyle(DeskPressStyle())
                            }
                        }
                    }
                    // Cards may draw past the page margin, but the strip itself stays the page's
                    // width: a negative padding widened the page and let it be dragged sideways.
                    .scrollClipDisabled()
                    .padding(.top, 12)

                    if Showcase.spotTrading && !spotResults.isEmpty {
                        HStack {
                            Text(query.isEmpty ? "Trending coins" : "Coins")
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                            Spacer()
                        }
                        .foregroundStyle(DeskColor.nightText.color)
                        .padding(.top, 26)

                        LazyVStack(spacing: 10) {
                            ForEach(spotResults) { token in
                                Button { selectedSpot = token } label: {
                                    TrendingSpotRow(token: token)
                                        .contentShape(Rectangle())
                                        .matchedTransitionSource(id: "spot-\(token.id)", in: navigationSpace)
                                }
                                .buttonStyle(DeskPressStyle())
                            }
                        }
                        .padding(.top, 12)
                    } else if Showcase.spotTrading, discovery.isLoading {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(query.isEmpty ? "Finding what’s moving…" : "Searching across networks…")
                        }
                        .font(DeskType.caption)
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                    } else if Showcase.spotTrading, let error = discovery.errorText {
                        ContentUnavailableView("Discovery unavailable", systemImage: "wifi.exclamationmark", description: Text(error))
                            .frame(minHeight: 150)
                    }

                    HStack {
                        Text("All perpetual markets")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                        Spacer()
                        Text("\(market.allMarkets.count) live")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(DeskColor.nightMuted.color)
                    }
                    .foregroundStyle(DeskColor.nightText.color)
                    .padding(.top, 30)

                    if market.allMarkets.isEmpty {
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
                        LazyVStack(spacing: 10) {
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

                    Text("Perpl \(model.network.shortName.lowercased()) lists these \(market.allMarkets.count) perpetual markets."
                         + (Showcase.spotTrading ? " Discovery tokens from other networks are separate from tradeable Perpl contracts." : ""))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 24)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .refreshable { if Showcase.spotTrading { await discovery.refresh() } }
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                field
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            .navigationDestination(isPresented: $showsMarket) {
                PerpDetailScreen(
                    model: model, market: market, session: session,
                    onOrderFilled: onOrderFilled)
                    .toolbar(.hidden, for: .tabBar)
            }
            #if DEBUG
            .task {
                let arguments = ProcessInfo.processInfo.arguments
                guard arguments.contains("-spot-buy") || arguments.contains("-wallet-demo") else { return }
                while discovery.trending.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
                if arguments.contains("-wallet-demo") {
                    var monad = discovery.trending.first { $0.chainIndex == (arguments.contains("-wallet-solana") ? "501" : "143") }
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
                    .navigationTransition(.zoom(sourceID: "spot-\(token.id)", in: navigationSpace))
                    .toolbar(.hidden, for: .tabBar)
            }
            .task { if Showcase.spotTrading { await discovery.run() } }
            .task(id: query) { if Showcase.spotTrading { await discovery.search(query) } }
            .task(id: query) {
                person = nil
                nameWasNotFound = false
                nameLookupUnavailable = false
                isLookingUpName = false
                guard looksLikeAName else { return }
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                isLookingUpName = true
                let found = await IdentityDirectory.shared.lookup(query)
                guard !Task.isCancelled else { return }
                isLookingUpName = false
                switch found {
                case .wallet(let address, let identity): person = (address, identity)
                case .solana(let name, let address):
                    let identity = name == address ? nil : IdentityDirectory.shared.rememberSolana(name: name, address: address)
                    person = (address, identity)
                case .notFound: nameWasNotFound = true
                case .unavailable: nameLookupUnavailable = true
                }
                #if DEBUG
                if let person, ProcessInfo.processInfo.arguments.contains("-open-person") {
                    try? await Task.sleep(for: .seconds(2))
                    selectedPerson = SpotWallet(address: person.address, emoji: "◉", portfolio: "—")
                }
                #endif
            }
            #if DEBUG
            .onAppear {
                let arguments = ProcessInfo.processInfo.arguments
                if let index = arguments.firstIndex(of: "-search-demo"), arguments.indices.contains(index + 1) { query = arguments[index + 1] }
            }
            #endif
            .fullScreenCover(item: $selectedPerson) { wallet in
                NavigationStack {
                    WalletProfileScreen(wallet: wallet, token: nil, model: model, onBack: { selectedPerson = nil })
                        .toolbar(.hidden, for: .navigationBar)
                }
            }
            .task(id: TokenOpenRequest.shared.pending) {
                guard let target = TokenOpenRequest.shared.take() else { return }
                selectedSpot = await discovery.find(target)
            }
        }
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DeskColor.nightMuted.color)
            TextField("", text: $query, prompt: Text("Search anything")
                .foregroundStyle(DeskColor.nightMuted.color))
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(DeskColor.nightText.color)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DeskColor.nightMuted.color)
                }
                .buttonStyle(DeskPressStyle())
                .accessibilityLabel("Clear search")
            } else {
                Button {
                    query = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                } label: {
                    Text("Paste")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .background(Color.white.opacity(0.12), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(DeskPressStyle())
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 52)
        .perpSearchGlass(in: Capsule())
    }

    private func toggle(_ id: UInt32) {
        var next = saved
        if next.contains(id) { next.remove(id) } else { next.insert(id) }
        savedIDs = next.sorted().map(String.init).joined(separator: ",")
        TradeAlerts.shared.watchlistChanged()
        Haptics.selection()
    }

    private func open(_ entry: Market) {
        market.select(entry)
        Task {
            await session.selectMarket(entry)
            showsMarket = true
        }
    }
}

struct TrendingSpotToken: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let chainIndex: String
    let chainName: String
    let symbol: String
    let name: String
    let logoURL: String
    let contract: String
    let decimals: Double?
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

    /// Only from hosts that serve token artwork: the upstream picks this URL, and fetching
    /// it anywhere would tell an arbitrary host this device's address and what it browses.
    var artworkURL: URL? { TokenArtwork.url(logoURL) }
}

@MainActor
final class TokenDiscoveryModel: ObservableObject {
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

    func refresh() async {
        await load(query: "", intoSearch: false)
        if !latestQuery.isEmpty { await load(query: latestQuery, intoSearch: true) }
    }

    func find(_ target: TokenOpenRequest.Target) async -> TrendingSpotToken {
        let match = { (list: [TrendingSpotToken]) in
            list.first { $0.chainIndex == target.chainIndex && $0.contract.caseInsensitiveCompare(target.contract) == .orderedSame }
        }
        if let known = match(trending) { return known }
        await load(query: target.contract, intoSearch: true)
        if let found = match(searchResults) { return found }
        return TrendingSpotToken(
            id: "\(target.chainIndex):\(target.contract)", chainIndex: target.chainIndex,
            chainName: ChainTable.name(target.chainIndex),
            symbol: target.symbol ?? "TOKEN", name: target.symbol ?? "Token", logoURL: "", contract: target.contract,
            decimals: nil, quotable: nil, buyable: nil, nativeSymbol: nil, explorerURL: "",
            price: nil, change: nil, marketCap: nil, volume24H: nil, liquidity: nil, holders: nil,
            communityRecognized: nil, riskLevel: nil)
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
        if (intoSearch ? searchResults : trending).isEmpty,
           let cached = await ResponseCache.shared.cached(url) {
            let tokens = try? await Task.detached(priority: .utility) {
                try JSONDecoder().decode(Response.self, from: cached).tokens.filter { $0.chainIndex != "501" }
            }.value
            if let tokens {
                if intoSearch { searchResults = tokens } else { trending = tokens }
            }
        }
        isLoading = (intoSearch ? searchResults : trending).isEmpty
        if isLoading { errorText = nil }
        do {
            let (data, _) = try await ResponseCache.shared.data(from: url)
            let tokens = try await Task.detached(priority: .utility) {
                try JSONDecoder().decode(Response.self, from: data).tokens.filter { $0.chainIndex != "501" }
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

struct TrendingSpotRow: View {
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

struct SpotFigures: Decodable {
    struct Response: Decodable { let prices: [SpotFigures] }
    let chainIndex: String
    let contract: String
    let price: Double?
    let change24h: Double?
    let volume24H: Double?
    let marketCap: Double?
    let liquidity: Double?
    let holders: Double?
}

extension TrendingSpotToken {
    /// Monad tokens buy through 0x in the app; elsewhere Relay delivers, so the feed's flag
    /// stands when it is there and the chain table answers when a token arrived without it.
    var isBuyable: Bool { chainIndex == ChainTable.monad || (buyable ?? ChainTable.buys(on: chainIndex)) }
    var displayChainName: String { ChainTable.displayName(chainName, chainIndex: chainIndex) }
    var isOnMonad: Bool { chainIndex == ChainTable.monad }

    func with(_ figures: SpotFigures) -> TrendingSpotToken {
        TrendingSpotToken(
            id: id, chainIndex: chainIndex, chainName: chainName, symbol: symbol, name: name, logoURL: logoURL, contract: contract,
            decimals: decimals, quotable: quotable, buyable: buyable, nativeSymbol: nativeSymbol, explorerURL: explorerURL,
            price: figures.price ?? price, change: figures.change24h ?? change, marketCap: figures.marketCap ?? marketCap,
            volume24H: figures.volume24H ?? volume24H, liquidity: figures.liquidity ?? liquidity, holders: figures.holders ?? holders,
            communityRecognized: communityRecognized, riskLevel: riskLevel)
    }
}

enum SpotWatchlistStorage {
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

func spotPrice(_ value: Double) -> String {
    let shape: SpotPriceShape = value >= 100 ? .large : (value >= 1 ? .medium : .small)
    return spotFormatters[shape]?.string(from: NSNumber(value: value)) ?? "$—"
}

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
                    MarketTokenLogo(symbol: market.symbol, size: 38, venue: true)

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
                MarketTokenLogo(symbol: market.symbol, size: 44, venue: true)
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
    /// The venue's own id for the trade. Never include `age`: it changes every poll, so
    /// rows would take new identities and the list would rebuild rather than diff.
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
            .refreshable { await feed.refreshNow() }
            tradeBar
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)
                .background {
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
            CandlestickChart(candles: feed.candles.map(\.chartCandle))
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
            if Showcase.spotTrading {
                Button { tradeSide = "Buy" } label: { Text("Buy").frame(width: 78, height: 44) }.perpSearchGlass(in: Capsule())
                Button { tradeSide = "Sell" } label: { Text("Sell").frame(width: 78, height: 44) }.perpSearchGlass(in: Capsule())
            } else {
                Text("View only").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
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

    func refreshNow() async {
        await refreshDetails()
        await refresh()
    }

    func run(period initialPeriod: String) async {
        changePeriod(initialPeriod)
        await refreshDetails()
        var ticks = 0
        while !Task.isCancelled {
            await refresh()
            ticks += 1
            if ticks.isMultiple(of: 30) { await refreshDetails() }
            try? await Task.sleep(for: .seconds(1))
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
        } else if token.isOnMonad {
            SpotSellTicket(token: token, model: model)
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
    @State private var showsSwap = false

    /// Covers `depositNative`'s gas, about 38,000 at mainnet's fee, several times over.
    private static let gasReserve = NativeAmount(decimalText: "0.01")!

    private var typed: NativeAmount? { NativeAmount(decimalText: amount).flatMap { $0.isZero ? nil : $0 } }
    private var balance: NativeAmount? { model.mainnetMON.value }
    private var lacksFunds: Bool {
        guard let typed, let balance else { return false }
        return balance.raw < typed.raw + Self.gasReserve.raw
    }
    private var isBuyable: Bool { token.isBuyable }
    @State private var risk = TokenRiskModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            payCard
            if purchase.phase.isActive || purchase.phase.isFinished {
                progress
            } else {
                receipt
                notices
            }
            Spacer(minLength: 0)
            action
        }
        .padding(24)
        .preferredColorScheme(.dark)
        .task { await model.refreshMainnetMON() }
        .task { await risk.load(chainIndex: token.chainIndex, contract: token.contract, riskLevel: token.riskLevel, communityRecognized: token.communityRecognized) }
        #if DEBUG
        .onAppear { if ProcessInfo.processInfo.arguments.contains("-spot-buy"), amount.isEmpty { amount = "5" } }
        #endif
        .task(id: amount) {
            guard isBuyable, !purchase.phase.isActive, let address = model.address else { return }
            await purchase.quote(token: token, amount: amount, user: address)
        }
        .interactiveDismissDisabled(purchase.phase.isActive)
        .sheet(isPresented: $showsSwap, onDismiss: { Task { await model.refreshMainnetMON() } }) {
            SwapSheet(model: model, direction: .toMON) { showsSwap = false }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            MarketTokenLogo(symbol: token.symbol, size: 42, remoteURL: token.artworkURL)
            VStack(alignment: .leading, spacing: 2) {
                Text("Buy \(token.symbol)").font(.system(size: 22, weight: .heavy, design: .rounded))
                Text(token.isOnMonad ? "Swapped on Monad through 0x" : "Delivered on \(token.displayChainName)")
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
            row(token.isOnMonad ? "Network fee" : "Network and fill fees",
                value: purchase.quoted.map { $0.feeMON.map { "\(SpotFormat.amount($0)) MON gas" } ?? "$\($0.feeUsd ?? "—")" })
            if let impact = purchase.quoted?.impactPercent.flatMap(Double.init) {
                row("Price impact", value: String(format: "%.1f%%", -impact), tint: impact <= -5 ? .yellow : nil)
            }
            row("Arrives in", value: purchase.quoted.map { token.isOnMonad ? "This block" : ($0.seconds.map { "~\($0) s" } ?? "—") })
        }
        .font(.system(size: 13, design: .rounded))
        .redacted(reason: purchase.isQuoting ? .placeholder : [])
    }

    private func row(_ title: String, value: String?, emphasised: Bool = false, tint: Color? = nil) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value ?? "—")
                .fontWeight(emphasised ? .bold : .semibold)
                .foregroundStyle(tint ?? (emphasised ? .primary : .secondary))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    @ViewBuilder
    private var notices: some View {
        if let error = purchase.quoteError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.yellow)
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 12) {
            step("Signed with Face ID", state: purchase.phase.stepState(0))
            step(token.isOnMonad ? "Swapped through 0x on Monad" : "MON deposited on Monad · not filled yet", state: purchase.phase.stepState(1))
            step(token.isOnMonad ? "\(token.symbol) in your wallet" : "Filled on \(token.displayChainName)", state: purchase.phase.stepState(2))
            switch purchase.phase {
            case .filled:
                TradeReceiptCard(
                    title: "Bought ≈ \(SpotFormat.amount(purchase.quoted?.receive.amount)) \(token.symbol)",
                    rows: [
                        ("Paid", "\(SpotFormat.amount(amount)) MON"),
                        ("Delivered on", token.displayChainName),
                        (token.isOnMonad ? "Network fee" : "Network and fill fees",
                         purchase.quoted.map { $0.feeMON.map { "\(SpotFormat.amount($0)) MON" } ?? "$\($0.feeUsd ?? "—")" } ?? "—"),
                    ],
                    hash: purchase.txHash, link: purchase.trackingURL)
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
                : "Buying on \(token.displayChainName) is not available yet")
        } else if purchase.phase.isFinished {
            Button { dismiss() } label: {
                Text("Done").frame(maxWidth: .infinity).frame(height: 54).contentShape(Capsule())
            }
            .buttonStyle(.plain).foregroundStyle(.black).background(.white, in: Capsule())
            .font(.system(size: 16, weight: .bold, design: .rounded))
        } else if purchase.phase.isActive {
            statusCapsule(purchase.phase.sentence(chain: token.displayChainName), spinning: true)
        } else if lacksFunds {
            VStack(spacing: 8) {
                statusCapsule("Not enough MON on Monad mainnet")
                if model.swappableAUSD != nil {
                    Button { showsSwap = true } label: {
                        Label("Swap AUSD for MON", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .frame(maxWidth: .infinity).frame(height: 36).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(.primary)
                }
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


/// A receipt that stays in the app: what happened, the figures, and the transaction, which
/// opens in a sheet over Desk rather than in Safari.
struct TradeReceiptCard: View {
    let title: String
    let rows: [(String, String)]
    let hash: String?
    let link: URL?
    @State private var showsLink = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(DeskColor.rise.color)
                Text(title).font(.system(size: 16, weight: .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.8)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            ForEach(rows, id: \.0) { row in
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
                HStack {
                    Text(row.0).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                    Spacer()
                    Text(row.1).font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
                }
                .padding(.horizontal, 14)
                .frame(height: 42)
            }
            if let link {
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
                Button { showsLink = true } label: {
                    HStack(spacing: 12) {
                        Text(hash == nil ? "Fill on Relay" : "Transaction")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                        Spacer(minLength: 8)
                        Text(hash ?? "relay.link")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 150)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(DeskColor.action.color)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 46)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showsLink) { InAppSafari(url: link).ignoresSafeArea() }
            }
        }
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 0.6))
    }
}

/// Selling a Monad token for MON: the buy ticket's shape, with the amount in the token and
/// the usual shares of the balance to pick from.
private struct SpotSellTicket: View {
    let token: TrendingSpotToken
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var sale = SpotSaleModel()
    @State private var amount = ""
    @State private var balance: (raw: Int128, decimals: Int)?
    @State private var picked: Double?

    private static let shares: [(String, Double)] = [("10%", 0.1), ("25%", 0.25), ("50%", 0.5), ("Max", 1)]

    private var heldText: String? { balance.map { SpotSaleModel.readable($0.raw, decimals: $0.decimals) } }
    private var typed: Decimal? { Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")).flatMap { $0 > 0 ? $0 : nil } }
    private var overBalance: Bool {
        guard let typed, let heldText, let held = Decimal(string: heldText, locale: Locale(identifier: "en_US_POSIX")) else { return false }
        return typed > held
    }
    private var soldFraction: Double {
        guard let balance, balance.raw > 0, let raw = sale.quoted?.pay?.raw.flatMap(Int128.init) else { return 0 }
        return min(1, Double(raw) / Double(balance.raw))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            payCard
            if sale.phase.isActive || sale.phase.isFinished {
                progress
            } else {
                receipt
                if let error = sale.quoteError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.yellow)
                }
            }
            Spacer(minLength: 0)
            action
        }
        .padding(24)
        .preferredColorScheme(.dark)
        .task { await loadBalance() }
        .task(id: amount) {
            guard !sale.phase.isActive, let address = model.address else { return }
            await sale.quote(token: token, amount: amount, user: address)
        }
        .interactiveDismissDisabled(sale.phase.isActive)
    }

    private func loadBalance() async {
        let digits = token.contract.hasPrefix("0x") ? String(token.contract.dropFirst(2)) : token.contract
        guard let contract = try? AppModel.ethereumAddress(digits) else { return }
        balance = try? await model.tokenBalance(contract)
    }

    private var header: some View {
        HStack(spacing: 12) {
            MarketTokenLogo(symbol: token.symbol, size: 42, remoteURL: token.artworkURL)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sell \(token.symbol)").font(.system(size: 22, weight: .heavy, design: .rounded))
                Text("Swapped for MON on Monad through 0x")
                    .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.title2).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(sale.phase.isActive)
        }
    }

    private var payCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("YOU SELL").font(.system(size: 10, weight: .heavy, design: .rounded)).tracking(1.2).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                TextField("0", text: $amount)
                    .keyboardType(.decimalPad)
                    .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                    .disabled(sale.phase.isActive || sale.phase.isFinished)
                    .onChange(of: amount) { _, _ in if picked != nil, amount != pickedAmount { picked = nil } }
                HStack(spacing: 6) {
                    MarketTokenLogo(symbol: token.symbol, size: 20, remoteURL: token.artworkURL)
                    Text(token.symbol).font(.system(size: 16, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.secondary)
            }
            HStack {
                Text("Balance \(heldText.map { SpotFormat.amount($0) } ?? "—") \(token.symbol)")
                    .foregroundStyle(overBalance ? DeskColor.fall.color : .secondary)
                Spacer()
                Text("Monad mainnet").foregroundStyle(.secondary)
            }
            .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
            HStack(spacing: 8) {
                ForEach(Self.shares, id: \.0) { share in
                    Button {
                        pick(share.1)
                    } label: {
                        Text(share.0)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .frame(maxWidth: .infinity).frame(height: 34)
                            .background(picked == share.1 ? Color.white : Color.white.opacity(0.1), in: Capsule())
                            .foregroundStyle(picked == share.1 ? .black : .primary)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(balance == nil || balance?.raw == 0 || sale.phase.isActive || sale.phase.isFinished)
                }
            }
        }
        .padding(16)
        .perpSearchGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var pickedAmount: String? {
        guard let picked, let balance else { return nil }
        return SpotSaleModel.share(of: balance.raw, decimals: balance.decimals, fraction: picked)
    }

    private func pick(_ fraction: Double) {
        picked = fraction
        if let text = SpotSaleModel.share(of: balance?.raw ?? 0, decimals: balance?.decimals ?? 18, fraction: fraction) { amount = text }
    }

    private var receipt: some View {
        VStack(spacing: 9) {
            row("You receive", value: sale.quoted.map { "≈ \(SpotFormat.amount($0.receive.amount)) MON" }, emphasised: true)
            row("At least", value: sale.quoted.map { "\(SpotFormat.amount($0.receive.minimum)) MON" })
            row("Network fee", value: sale.quoted.map { $0.feeMON.map { "\(SpotFormat.amount($0)) MON" } ?? "—" })
            row("Arrives in", value: sale.quoted.map { _ in "This block" })
        }
        .font(.system(size: 13, design: .rounded))
        .redacted(reason: sale.isQuoting ? .placeholder : [])
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

    private var progress: some View {
        VStack(alignment: .leading, spacing: 12) {
            step("Signed with Face ID", state: sale.phase.stepState(0))
            step("Approved \(token.symbol) for exactly this swap", state: sale.phase.stepState(1))
            step("Swapped for MON on Monad", state: sale.phase.stepState(2))
            switch sale.phase {
            case .sold(let receipt):
                TradeReceiptCard(
                    title: "Sold \(SpotFormat.amount(amount)) \(token.symbol)",
                    rows: [
                        ("Received", "\(receipt.received.display()) MON"),
                        ("On", "Monad mainnet"),
                        ("Network fee", sale.quoted.map { $0.feeMON.map { "\(SpotFormat.amount($0)) MON" } ?? "—" } ?? "—"),
                    ],
                    hash: receipt.hash, link: URL(string: "https://monadvision.com/tx/\(receipt.hash)"))
                    .padding(.top, 4)
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
        if sale.phase.isFinished {
            Button { dismiss() } label: {
                Text("Done").frame(maxWidth: .infinity).frame(height: 54).contentShape(Capsule())
            }
            .buttonStyle(.plain).foregroundStyle(.black).background(.white, in: Capsule())
            .font(.system(size: 16, weight: .bold, design: .rounded))
        } else if sale.phase.isActive {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(sale.phase.sentence).lineLimit(1).minimumScaleFactor(0.8)
            }
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity).frame(height: 54)
            .background(Color.white.opacity(0.06), in: Capsule())
        } else if balance?.raw == 0 {
            Text("No \(token.symbol) in this wallet")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).frame(height: 54)
                .background(Color.white.opacity(0.06), in: Capsule())
        } else {
            HoldToConfirm(
                title: overBalance ? "More than you hold" : (sale.quoted == nil ? "Enter an amount" : "Hold to sell \(token.symbol)"),
                tint: DeskColor.fall,
                isEnabled: sale.quoted != nil && typed != nil && !sale.isQuoting && !overBalance
            ) {
                Task {
                    await sale.sell(token: token, model: model, soldFraction: soldFraction)
                }
            }
        }
    }
}

@MainActor
private final class SpotSaleModel: ObservableObject {
    enum Phase: Equatable {
        case idle, signing, approving, swapping
        case sold(AppModel.MONSwapReceipt)
        case failed(String)

        var isActive: Bool { self == .signing || self == .approving || self == .swapping }
        var isFinished: Bool {
            switch self {
            case .sold, .failed: true
            default: false
            }
        }
        var sentence: String {
            switch self {
            case .signing: "Confirm with Face ID…"
            case .approving: "Approving on Monad…"
            case .swapping: "Swapping on Monad…"
            default: ""
            }
        }
        func stepState(_ index: Int) -> SpotPurchaseModel.StepState {
            switch (self, index) {
            case (.signing, 0): .running
            case (.approving, 0): .done
            case (.approving, 1): .running
            case (.swapping, 0), (.swapping, 1): .done
            case (.swapping, 2): .running
            case (.sold, _): .done
            case (.failed, _): .stopped
            default: .waiting
            }
        }
    }

    @Published private(set) var quoted: RelayQuote?
    @Published private(set) var quoteError: String?
    @Published private(set) var isQuoting = false
    @Published private(set) var phase: Phase = .idle
    private(set) var quotedAt = Date.distantPast

    private static let host = "https://web-lovat-nine-49.vercel.app"

    /// A raw count as decimal text at the token's decimals, with no trailing zeros.
    nonisolated static func readable(_ raw: Int128, decimals: Int) -> String {
        guard decimals > 0 else { return String(raw) }
        var digits = String(raw)
        if digits.count <= decimals { digits = String(repeating: "0", count: decimals - digits.count + 1) + digits }
        let whole = String(digits.prefix(digits.count - decimals))
        var fraction = String(digits.suffix(decimals))
        while fraction.hasSuffix("0") { fraction.removeLast() }
        return fraction.isEmpty ? whole : "\(whole).\(fraction)"
    }

    /// A share of a balance as decimal text; the whole balance is exact, a part is rounded
    /// down to the token's units so it never asks for more than is held.
    nonisolated static func share(of raw: Int128, decimals: Int, fraction: Double) -> String? {
        guard raw > 0 else { return nil }
        if fraction >= 1 { return readable(raw, decimals: decimals) }
        let part = Int128(Double(raw) * fraction)
        return part > 0 ? readable(part, decimals: decimals) : nil
    }

    func quote(token: TrendingSpotToken, amount: String, user: EthereumAddress) async {
        quoteError = nil
        let text = amount.trimmingCharacters(in: .whitespaces)
        guard let typed = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), typed > 0 else {
            quoted = nil
            return
        }
        isQuoting = true
        defer { isQuoting = false }
        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled else { return }
        var components = URLComponents(string: "\(Self.host)/api/swap-quote")!
        components.queryItems = [
            URLQueryItem(name: "view", value: "swap"),
            URLQueryItem(name: "user", value: user.checksummed),
            URLQueryItem(name: "amount", value: text),
            URLQueryItem(name: "sell", value: "TOKEN"),
            URLQueryItem(name: "token", value: token.contract),
            URLQueryItem(name: "symbol", value: String(token.symbol.prefix(12))),
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

    func sell(token: TrendingSpotToken, model: AppModel, soldFraction: Double) async {
        guard let wallet = model.address, !phase.isActive, let quoted else { return }
        let sale: TokenSale
        do {
            sale = try TokenSale(
                chainID: quoted.transaction.chainId, to: quoted.transaction.to, data: quoted.transaction.data,
                value: quoted.transaction.value, token: token.contract,
                amountRaw: quoted.pay?.raw ?? "", minimumOutRaw: quoted.receive.minimumRaw ?? "")
        } catch {
            phase = .failed("This quote did not pass Desk's safety check, so nothing was signed.")
            return
        }
        phase = .signing
        do {
            let receipt = try await model.sellToken(sale) { [weak self] step in
                guard let self else { return }
                switch step {
                case .approving: self.phase = .approving
                case .sending: self.phase = .swapping
                default: break
                }
            }
            phase = .sold(receipt)
            SpotPurchases.reduce("\(token.chainIndex):\(token.contract.lowercased())", keeping: 1 - soldFraction, for: wallet)
        } catch PasskeyFailure.cancelledByUser {
            phase = .idle
        } catch let failure as PasskeyFailure {
            phase = .failed(failure.sentence)
        } catch AppModel.SwapFailure.routeReverts {
            phase = .failed("This route reverts right now. Nothing was signed.")
        } catch TransactionSender.Failure.reverted {
            phase = .failed("The swap was rejected on Monad. Only gas was spent.")
        } catch {
            phase = .failed("The swap could not be sent. Nothing left the wallet.")
        }
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

    static func amount(_ text: String?) -> String {
        guard let text, let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else { return "—" }
        return significant.string(from: value as NSDecimalNumber) ?? text
    }
}

private struct RelayQuote: Decodable, Sendable {
    struct Side: Decodable, Sendable {
        let amount: String?
        let raw: String?
        let minimum: String?
        let minimumRaw: String?
        let usd: String?
        let symbol: String?
    }
    struct Transaction: Decodable, Sendable {
        let chainId: UInt64
        let to: String
        let data: String
        let value: String
    }
    let requestId: String?
    let pay: Side?
    let receive: Side
    let feeUsd: String?
    let feeMON: String?
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
    private(set) var txHash: String?

    private static let host = "https://web-lovat-nine-49.vercel.app"

    var trackingURL: URL? {
        if let txHash { return URL(string: "https://monadvision.com/tx/\(txHash)") }
        return requestId.flatMap { URL(string: "https://relay.link/transaction/\($0)") }
    }

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
        // On Monad the quote is 0x's one call through the allowance holder; elsewhere it is
        // Relay's deposit. Both answer in the same shape.
        var components = URLComponents(string: "\(Self.host)/api/\(token.isOnMonad ? "swap-quote" : "relay-quote")")!
        components.queryItems = token.isOnMonad
            ? [
                URLQueryItem(name: "view", value: "swap"),
                URLQueryItem(name: "user", value: user.checksummed),
                URLQueryItem(name: "amount", value: amount),
                URLQueryItem(name: "sell", value: "MON"),
                URLQueryItem(name: "token", value: token.contract),
                URLQueryItem(name: "symbol", value: String(token.symbol.prefix(12))),
            ]
            : [
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
        if token.isOnMonad {
            await swap(token: token, quoted: quoted, typed: typed, wallet: wallet, model: model)
            return
        }
        guard let requestId = quoted.requestId else {
            phase = .failed("This quote did not pass Desk's safety check, so nothing was signed.")
            return
        }
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

        self.requestId = requestId
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
            await track(requestId)
            remember(token, quoted, wallet: wallet)
            return
        } catch {
            phase = .failed("The deposit could not be sent. No MON was taken.")
            return
        }
        phase = .filling
        await track(requestId)
        remember(token, quoted, wallet: wallet)
    }

    /// A Monad token: one swap, checked against the quote before Face ID, mined in a block.
    private func swap(token: TrendingSpotToken, quoted: RelayQuote, typed: NativeAmount, wallet: EthereumAddress, model: AppModel) async {
        let swap: TokenSwap
        do {
            swap = try TokenSwap(
                chainID: quoted.transaction.chainId, to: quoted.transaction.to, data: quoted.transaction.data,
                value: quoted.transaction.value, amount: typed, token: token.contract,
                minimumOutRaw: quoted.receive.minimumRaw ?? "")
        } catch {
            phase = .failed("This quote did not pass Desk's safety check, so nothing was signed.")
            return
        }
        phase = .signing
        do {
            txHash = try await model.buyToken(swap) { _ in }
        } catch PasskeyFailure.cancelledByUser {
            phase = .idle
            return
        } catch let failure as PasskeyFailure {
            phase = .failed(failure.sentence)
            return
        } catch AppModel.SwapFailure.routeReverts {
            phase = .failed("This route reverts right now. Nothing was signed.")
            return
        } catch AppModel.SwapFailure.underdelivers {
            phase = .failed("The route would hand back less than the quote. Nothing was signed.")
            return
        } catch TransactionSender.Failure.reverted {
            phase = .failed("The swap was rejected on Monad. Only gas was spent.")
            return
        } catch {
            phase = .failed("The swap could not be sent. No MON was taken.")
            return
        }
        phase = .filled
        remember(token, quoted, wallet: wallet)
    }

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

    /// From the feed's chain table, never assumed to be ETH: Arc's gas token is USDC.
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
        // The discovery feed carries no decimals, so none is required here: the server
        // resolves it from the chain, and a hint is passed only when there is one.
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
            RemoteImage(url: url, fill: true) { Text(wallet.emoji) }
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

struct SpotTokenPage: View {
    let target: TokenOpenRequest.Target
    let model: AppModel
    @StateObject private var lookup = TokenDiscoveryModel()
    @State private var token: TrendingSpotToken?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let token { SpotTokenDetailScreen(token: token, model: model) }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task { token = await lookup.find(target) }
    }
}

struct TrackedWalletProfile: View {
    let address: String
    let model: AppModel

    var body: some View {
        WalletProfileScreen(wallet: SpotWallet(address: address, emoji: "◉", portfolio: "—"), token: nil, model: model)
    }
}

private struct WalletProfileScreen: View {
    let wallet: SpotWallet
    let token: TrendingSpotToken?
    var feed: SpotLiveFeed? = nil
    let model: AppModel
    var onBack: (() -> Void)? = nil
    @StateObject private var lookup = TokenDiscoveryModel()
    @State private var opened: TrendingSpotToken?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var resource: WalletResource?
    @State private var resourceFailed = false
    @State private var profileReady = false
    @State private var preparedArtwork: [URL: UIImage] = [:]
    @State private var perplDirectory = TraderDirectory()
    @State private var showsPerpl = false
    @State private var tab: Tab = .positions
    @State private var naming = false
    @State private var draftName = ""
    @State private var copied = false
    @State private var editsAlerts = false

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
        if contract.isEmpty { return nil }
        if let token, chainIndex == token.chainIndex, contract.caseInsensitiveCompare(token.contract) == .orderedSame, let own = token.artworkURL { return own }
        let key = chainIndex == "501" ? contract : contract.lowercased()
        return (resource?.logos?["\(chainIndex):\(key)"]).flatMap(TokenArtwork.url)
    }

    private var identity: Identity? { IdentityDirectory.shared.identity(for: wallet.address) }
    private var tracked: TrackedWallet? { TrackedWallets.shared.wallet(for: wallet.address) }
    private var isEVM: Bool { wallet.address.hasPrefix("0x") && wallet.address.count == 42 }
    private var isSolana: Bool { !wallet.address.hasPrefix("0x") && (32...44).contains(wallet.address.count) }
    private var ledgerChain: String { isSolana ? "501" : "143" }
    private func tokenKey(_ token: String) -> String { isSolana ? token : token.lowercased() }
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
            VStack(spacing: 0) {
                HStack {
                    Button {
                        if let onBack { onBack() } else { dismiss() }
                    } label: { Image(systemName: "chevron.left").frame(width: 50, height: 50) }.perpSearchGlass(in: Circle())
                    Spacer()
                    ShareLink(item: wallet.address) { Image(systemName: "square.and.arrow.up").frame(width: 50, height: 50) }.perpSearchGlass(in: Circle())
                }
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.top, 8)

            if !profileReady {
                ProgressView("Preparing wallet profile…")
                    .tint(DeskColor.action.color)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if resourceFailed && resource == nil {
                ContentUnavailableView {
                    Label("Wallet unavailable", systemImage: "wifi.exclamationmark")
                } description: {
                    Text("The wallet data couldn't be loaded right now.")
                } actions: {
                    Button("Try again") { Task { await loadResource() } }
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        avatar
                        Spacer(minLength: 14)
                        stat(portfolioText, label: portfolioLabel, tint: .white)
                        Divider().frame(height: 38).overlay(Color.white.opacity(0.12)).padding(.horizontal, 18)
                        stat(totalPnL.map(signed) ?? "—", label: "Total PnL", tint: totalPnL.map(tint) ?? .white)
                        Spacer(minLength: 0)
                    }.padding(.top, 22)

                    HStack(spacing: 10) {
                        if identity?.source == "sns" {
                            Text(name)
                                .font(.system(size: 21, weight: .bold, design: .rounded))
                                .lineLimit(1).minimumScaleFactor(0.6)
                        } else {
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
                        }
                        Spacer(minLength: 8)
                        if isEVM || isSolana {
                            action(tracked == nil ? "Follow" : "Following", symbol: nil) {
                                if tracked == nil {
                                    TrackedWallets.shared.track(wallet.address, name: identity?.name ?? "")
                                    if isEVM { Task { await perplDirectory.follow(wallet.address) } }
                                } else if isEVM {
                                    if perplDirectory.isFollowing(wallet.address) {
                                        perplDirectory.unfollow(wallet.address)
                                    } else {
                                        perplDirectory.unfollowWallet(wallet.address)
                                    }
                                } else {
                                    TrackedWallets.shared.untrack(wallet.address)
                                }
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            }
                            if identity?.source != "sns" {
                                action("Set Name", symbol: "pencil") {
                                    draftName = tracked?.name ?? ""
                                    naming = true
                                }
                            }
                        }
                    }.padding(.top, 20)

                    if let tracked, TradeAlerts.shared.permission == .denied {
                        NotificationsOffLine().padding(.top, 10)
                    } else if let tracked {
                        Button {
                            if TradeAlerts.shared.isOn(for: wallet.address) {
                                editsAlerts = true
                            } else {
                                Task { await perplDirectory.follow(wallet.address, name: tracked.name) }
                            }
                        } label: { alertsLine(tracked) }
                            .buttonStyle(.plain)
                            .padding(.top, 10)
                    }

                    if identity?.source != "sns", let status = statusLine {
                        Button { statusAction() } label: { statusLabel(status) }
                            .buttonStyle(.plain)
                            .padding(.top, 10)
                    }

                    tabs.padding(.top, 18)
                    content.padding(.top, 4)
                }.padding(.horizontal, 20).padding(.bottom, 40)
            }
            .refreshable { await IdentityDirectory.shared.resolve([wallet.address]); await loadResource() }
            }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showsPerpl) {
            if let copier = CopyTrader.current {
                TraderProfileScreen(
                    initial: TraderSnapshot(accountId: identity?.perplAccount, address: wallet.address,
                                            pnl: nil, balance: nil, positions: []),
                    directory: perplDirectory, copier: copier, asSheet: true, onCopy: { _ in })
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $editsAlerts) {
            TrackWalletSheet(existing: tracked, directory: perplDirectory)
                .fittedSheet()
                .presentationDragIndicator(.visible)
        }
        .alert("Name this wallet", isPresented: $naming) {
            TextField("Name", text: $draftName)
            Button("Save") {
                let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                if let tracked { TrackedWallets.shared.update(TrackedWallet(address: tracked.address, name: String(trimmed.prefix(24)), minUsd: tracked.minUsd, firstBuysOnly: tracked.firstBuysOnly)) }
                else {
                    TrackedWallets.shared.track(wallet.address, name: trimmed)
                    if isEVM { Task { await perplDirectory.follow(wallet.address, name: trimmed) } }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Shown wherever this wallet appears on your phone.")
        }
        .task {
            await IdentityDirectory.shared.resolve([wallet.address])
            await loadResource()
        }
        .task { await TradeAlerts.shared.refreshPermission() }
        .task(id: profileReady) {
            guard profileReady, resource?.ledger.status == "indexing" else { return }
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            await loadResource()
        }
        .navigationDestination(item: $opened) { token in
            SpotTokenDetailScreen(token: token, model: model)
        }
        #if DEBUG
        .onAppear { if ProcessInfo.processInfo.arguments.contains("-wallet-activity") { tab = .activity } }
        #endif
    }

    private func open(_ row: Row) {
        guard !row.contract.isEmpty else { return }
        if let token, row.chainIndex == token.chainIndex, row.contract.caseInsensitiveCompare(token.contract) == .orderedSame {
            dismiss()
            return
        }
        Task {
            await lookup.search(row.contract)
            let match = (lookup.searchResults + lookup.trending).first {
                $0.chainIndex == row.chainIndex && $0.contract.caseInsensitiveCompare(row.contract) == .orderedSame
            }
            opened = match ?? TrendingSpotToken(
                id: "\(row.chainIndex):\(row.contract)", chainIndex: row.chainIndex, chainName: ChainTable.displayName(row.chainName ?? "", chainIndex: row.chainIndex),
                symbol: row.symbol, name: row.symbol, logoURL: logo(row.chainIndex, row.contract)?.absoluteString ?? "",
                contract: row.contract, decimals: nil, quotable: nil, buyable: nil, nativeSymbol: nil, explorerURL: "",
                price: nil, change: nil, marketCap: nil, volume24H: nil, liquidity: nil, holders: nil,
                communityRecognized: nil, riskLevel: nil)
        }
    }

    private var avatar: some View {
        Group {
            if let url = identity?.avatarURL, let image = preparedArtwork[url] {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                AddressAvatar(address: wallet.address, size: 68)
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

    /// What following this wallet alerts on. Following tracks it and turns alerts on in one go;
    /// this line says so, and opens the threshold when tapped.
    private func alertsLine(_ tracked: TrackedWallet) -> some View {
        let on = TradeAlerts.shared.isOn(for: wallet.address)
        return HStack(spacing: 7) {
            Image(systemName: on ? "bell.fill" : "bell.slash")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? DeskColor.rise.color : DeskColor.nightMuted.color)
            Text(alertsText(tracked, on: on))
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1).minimumScaleFactor(0.8)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.4))
        }
        .contentShape(Rectangle())
    }

    private func alertsText(_ tracked: TrackedWallet, on: Bool) -> String {
        guard on else { return "Alerts off · tap to hear when they trade" }
        let swaps = tracked.firstBuysOnly ? "first buys over $\(Int(tracked.minUsd))" : "swaps over $\(Int(tracked.minUsd))"
        return isEVM ? "Alerts on · \(swaps), every Perpl move" : "Alerts on · \(swaps)"
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

    private func statusLabel(_ status: String) -> some View {
        HStack(spacing: 7) {
            Circle().fill(statusTint).frame(width: 7, height: 7)
            Text(status).font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.8))
        }
        .contentShape(Rectangle())
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
                        Text(isSolana && item == .positions ? "Holdings" : item.rawValue)
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
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.1)).frame(height: 0.5).padding(.horizontal, -20) }
    }

    @ViewBuilder
    private var content: some View {
        let rows = rows(for: tab)
        if resource == nil, !resourceFailed, isEVM || isSolana, rows.isEmpty {
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
            if rows.isEmpty {
                Text(ledger?.status == "indexing" ? "Analyzing this wallet’s on-chain history…"
                     : ledger == nil && resource != nil && tab != .positions ? "Trade history is unavailable right now."
                     : tab == .positions ? "No holdings found for this wallet."
                     : tab == .closed ? "No closed trades on record." : "No trades on record.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.4))
                    .padding(.top, 22)
            }
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

    @ViewBuilder
    private func profileLogo(_ row: Row) -> some View {
        if let url = logo(row.chainIndex, row.contract), let image = preparedArtwork[url] {
            Image(uiImage: image).resizable().scaledToFit()
                .frame(width: 38, height: 38).clipShape(Circle())
                .accessibilityLabel(row.symbol)
        } else if UIImage(named: row.symbol.uppercased()) != nil {
            Image(row.symbol.uppercased()).resizable().scaledToFit()
                .frame(width: 38, height: 38).clipShape(Circle())
                .accessibilityLabel(row.symbol)
        } else {
            RemoteImage(url: logo(row.chainIndex, row.contract)) {
                TokenSymbolBadge(symbol: row.symbol, seed: row.contract.isEmpty ? row.symbol : row.contract, size: 38)
            }
            .frame(width: 38, height: 38).clipShape(Circle())
            .accessibilityLabel(row.symbol)
        }
    }

    private func tokenRow(_ row: Row) -> some View {
        HStack(spacing: 12) {
            profileLogo(row)
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
            let unrealized = Dictionary((ledger?.tokens ?? []).map { (tokenKey($0.token), $0) }, uniquingKeysWith: { a, _ in a })
            return (resource?.holdings ?? []).map { holding in
                let position = holding.chainIndex == ledgerChain ? unrealized[tokenKey(holding.contract)] : nil
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
                           tint: tint(gain), badge: nil, day: Self.day(trade.time), chainIndex: ledgerChain, contract: trade.token)
            }
        case .activity:
            if let trades = ledger?.trades, !trades.isEmpty {
                return trades.map { trade in
                    Row(id: trade.id, symbol: trade.symbol, title: "\(trade.isBuy ? "Bought" : "Sold") \(trade.symbol)", subtitle: Self.age(trade.time),
                        value: SpotLiveFeed.compactUSD(trade.value),
                        detail: "\(trade.isBuy ? "+" : "−")\(SpotLiveFeed.compactNumber(trade.amount)) \(trade.symbol)",
                        tint: Color.white.opacity(0.55), badge: trade.isBuy ? "+" : "−", day: Self.day(trade.time), chainIndex: ledgerChain, contract: trade.token)
                }
            }
            guard let token, let feed else { return [] }
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
        guard isEVM || isSolana else { resourceFailed = true; profileReady = true; return }
        var components = URLComponents(string: "https://web-lovat-nine-49.vercel.app/api/activity")!
        components.queryItems = [
            URLQueryItem(name: "view", value: "wallet"),
            URLQueryItem(name: "address", value: wallet.address),
            URLQueryItem(name: "chainIndex", value: token?.chainIndex ?? ledgerChain),
            URLQueryItem(name: "contract", value: token?.contract ?? ""),
        ]
        guard let url = components.url else { resourceFailed = true; profileReady = true; return }
        do {
            let (data, _) = try await ResponseCache.shared.data(from: url, maxStale: 300)
            let snapshot = try JSONDecoder().decode(WalletResource.self, from: data)
            let artwork = await prepareArtwork(for: snapshot)
            guard !Task.isCancelled else { return }
            preparedArtwork = artwork
            resource = snapshot
            resourceFailed = false
        } catch {
            guard !Task.isCancelled else { return }
            resourceFailed = true
        }
        profileReady = true
    }

    private func prepareArtwork(for snapshot: WalletResource) async -> [URL: UIImage] {
        var urls = Set((snapshot.logos ?? [:]).values.compactMap(TokenArtwork.url))
        if let url = token?.artworkURL { urls.insert(url) }
        if let url = identity?.avatarURL { urls.insert(url) }
        return await withTaskGroup(of: (URL, UIImage?).self, returning: [URL: UIImage].self) { group in
            for url in urls.prefix(32) {
                group.addTask {
                    if let cached = await ResponseCache.shared.cached(url, maxAge: 7 * 86_400),
                       let image = UIImage(data: cached) { return (url, image) }
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 3
                    guard let (data, response) = try? await URLSession.shared.data(for: request),
                          (response as? HTTPURLResponse)?.statusCode == 200,
                          let image = UIImage(data: data) else { return (url, nil) }
                    await ResponseCache.shared.store(data, for: url)
                    return (url, image)
                }
            }
            var ready: [URL: UIImage] = [:]
            for await (url, image) in group {
                if let image { ready[url] = image }
            }
            return ready
        }
    }
}

extension SpotLiveFeed.Candle {
    /// OKX stamps candles in milliseconds; the chart wants seconds.
    var chartCandle: ChartCandle {
        ChartCandle(open: open, high: high, low: low, close: close, volume: nil,
                    time: timestamp > 100_000_000_000 ? Double(timestamp) / 1_000 : Double(timestamp))
    }
}

/// A token you hold, as a sheet over Profile: the live chart with your entry drawn on it and
/// the buy marked, the position, the buy itself, and Buy more or Sell. The symbol opens the
/// whole token page.
struct TokenPositionSheet: View {
    let holding: SpotHolding
    let model: AppModel
    let onOpenPage: (TokenOpenRequest.Target) -> Void
    @StateObject private var lookup = TokenDiscoveryModel()
    @State private var token: TrendingSpotToken?

    private var target: TokenOpenRequest.Target {
        .init(chainIndex: holding.purchase.chainIndex, contract: holding.purchase.contract, symbol: holding.purchase.symbol)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let token {
                TokenPositionContent(token: token, holding: holding, model: model) { onOpenPage(target) }
            } else {
                ProgressView().tint(.white)
            }
        }
        .preferredColorScheme(.dark)
        .task { token = await lookup.find(target) }
    }
}

private struct TokenPositionContent: View {
    let token: TrendingSpotToken
    let holding: SpotHolding
    let model: AppModel
    let onOpenPage: () -> Void
    @StateObject private var feed: SpotLiveFeed
    @State private var holdings = SpotHoldingsModel()
    @State private var range = "1H"
    @State private var tradeSide: String?
    @Environment(\.dismiss) private var dismiss

    init(token: TrendingSpotToken, holding: SpotHolding, model: AppModel, onOpenPage: @escaping () -> Void) {
        self.token = token
        self.holding = holding
        self.model = model
        self.onOpenPage = onOpenPage
        _feed = StateObject(wrappedValue: SpotLiveFeed(symbol: token.symbol, chainIndex: token.chainIndex, contract: token.contract))
    }

    private var current: SpotHolding {
        holdings.holdings.first { $0.id == holding.id } ?? holding
    }
    private var entryPrice: Double? {
        guard let paid = current.purchase.paidUSD, let amount = current.balance.flatMap({ Double($0.replacingOccurrences(of: ",", with: "")) }), amount > 0 else { return nil }
        return paid / amount
    }

    private var amountHeld: Double? { current.balance.flatMap { Double($0.replacingOccurrences(of: ",", with: "")) } }
    private var pnl: Double? { current.value.flatMap { value in current.purchase.paidUSD.map { value - $0 } } }

    var body: some View {
        NavigationStack {
            GlassPage {
                GlassSection {
                    HStack(spacing: 14) {
                        MarketTokenLogo(symbol: token.symbol, size: 38, remoteURL: token.artworkURL)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(token.name.isEmpty ? token.symbol : token.name).font(.headline).lineLimit(1)
                            Text("\(token.symbol) · \(token.displayChainName)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(feed.latestPrice.map(spotPrice) ?? "$—").font(.headline.monospacedDigit())
                            if let change = feed.changePercent {
                                Text(String(format: "%@%.2f%%", change >= 0 ? "+" : "", change))
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                    .foregroundStyle((change >= 0 ? DeskColor.rise : DeskColor.fall).color)
                            }
                        }
                    }
                }

                GlassSection("Since your entry") {
                    VStack(spacing: 10) {
                        CandlestickChart(
                            candles: feed.candles.map(\.chartCandle),
                            guides: entryPrice.map { [PriceGuide(label: "Entry", value: $0, text: PriceAxis.label($0), tint: .white.opacity(0.9))] } ?? [],
                            marks: [ChartMark(time: current.purchase.boughtAt.timeIntervalSince1970, label: "Bought", tint: DeskColor.rise.color)])
                            .frame(height: 220)
                            .accessibilityLabel("Chart for \(token.symbol) with your entry")
                        Picker("Range", selection: $range) {
                            ForEach(["LIVE", "1m", "5m", "15m", "1H", "4H"], id: \.self) { Text($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                GlassSection("Your position") {
                    GlassRow("Value", value: current.value.map { DisplayCurrency.shared.format($0) } ?? Unavailable.text)
                    GlassRow("Since buy") {
                        if let pnl, let change = current.changeSincePaid {
                            Text(String(format: "%@%@ (%@%.2f%%)", pnl < 0 ? "−" : "+", DisplayCurrency.shared.format(abs(pnl)), change < 0 ? "▼ " : "▲ ", abs(change * 100)))
                                .fontWeight(.semibold)
                                .foregroundStyle((pnl < 0 ? DeskColor.fall : DeskColor.rise).color)
                                .monospacedDigit()
                        } else {
                            Text("—").foregroundStyle(.secondary)
                        }
                    }
                    GlassRow("Holding", value: current.balance.map { "\(SpotFormat.amount($0)) \(token.symbol)" } ?? "—")
                    GlassRow("Invested", value: current.purchase.paidUSD.map { DisplayCurrency.shared.format($0) } ?? "—")
                    GlassRow("Average entry", value: entryPrice.map { "$" + SpotFormat.amount(String($0)) } ?? "—")
                }

                GlassSection("Transactions") {
                    GlassRow("Bought", subtitle: current.purchase.boughtAt.formatted(date: .abbreviated, time: .shortened)) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(current.purchase.paidUSD.map { "+" + DisplayCurrency.shared.format($0) } ?? "—")
                                .fontWeight(.semibold).monospacedDigit()
                            Text(current.balance.map { "\(SpotFormat.amount($0)) \(token.symbol)" } ?? "")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
            .navigationTitle(token.symbol)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Token page") {
                        dismiss()
                        onOpenPage()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 10) {
                    Button { tradeSide = "Buy" } label: {
                        Text("Buy more")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 2)
                    }
                    .controlSize(.large)
                    .deskProminentButton()
                    Button { tradeSide = "Sell" } label: {
                        Text("Sell")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 2)
                    }
                    .controlSize(.large)
                    .deskSecondaryButton()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }
        }
        .task { await feed.run(period: range) }
        .task(id: model.address) { await holdings.run(for: model.address) }
        .onChange(of: range) { _, newValue in feed.changePeriod(newValue) }
        .sheet(isPresented: Binding(get: { tradeSide != nil }, set: { if !$0 { tradeSide = nil } }),
               onDismiss: { Task { await holdings.refresh() } }) {
            SpotTradeTicket(token: token, side: tradeSide ?? "Buy", model: model)
                .fittedSheet()
                .presentationDragIndicator(.visible)
        }
    }
}
