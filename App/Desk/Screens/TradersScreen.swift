import DeskUI
import Observation
import SwiftUI
import UIKit

struct TraderPosition: Decodable, Hashable, Identifiable, Sendable {
    let market: String
    let marketId: Int
    let side: String
    let entry: String
    let mark: String
    let size: String
    let collateral: String
    let value: String
    let pnl: String
    let pnlPercent: Double?
    let leverage: Double?

    var id: String { "\(marketId)-\(side)" }
    var isLong: Bool { side == "long" }
    var isProfit: Bool { !pnl.hasPrefix("-") }
}

struct TraderSnapshot: Decodable, Hashable, Identifiable, Sendable {
    let accountId: String?
    let address: String
    let pnl: String?
    let balance: String?
    let positions: [TraderPosition]
    /// True when the server could not read this trader's book at all. Distinct from an
    /// empty book, which means they hold nothing — auto-copy must never confuse the two.
    var unreadable: Bool?

    var id: String { address.lowercased() }
    var isProfit: Bool { !(pnl ?? "").hasPrefix("-") }
    var shortAddress: String { TraderSnapshot.short(address) }

    /// Free balance plus what every open position is worth to its owner: collateral and PnL.
    var portfolio: Double? {
        guard let balance = balance.flatMap(Double.init) else { return nil }
        return positions.reduce(balance) { $0 + (Double($1.collateral) ?? 0) + (Double($1.pnl) ?? 0) }
    }

    var positionValue: Double { positions.reduce(0) { $0 + (Double($1.value) ?? 0) } }

    static func short(_ address: String) -> String {
        address.count > 12 ? "\(address.prefix(6))…\(address.suffix(4))" : address
    }
}

struct MarketCrowd: Decodable, Identifiable, Hashable {
    struct Biggest: Decodable, Hashable {
        let address: String?
        let side: String
        let value: String
        let leverage: Double?

        var isLong: Bool { side == "long" }
    }

    let market: String
    let marketId: Int
    let complete: Bool
    let traders: Int
    let longTraders: Int
    let shortTraders: Int
    let longValue: String
    let shortValue: String
    /// `nil` when nothing is open: a market with no positions has no side to report, and
    /// drawing it as an even split would be a claim about a book that is not there.
    let longShareBps: Int?
    let biggest: Biggest?

    var id: Int { marketId }
    var total: Double { (Double(longValue) ?? 0) + (Double(shortValue) ?? 0) }
    var longShare: Double? { longShareBps.map { Double($0) / 10_000 } }
    var crowdedSide: String? {
        guard let longShareBps else { return nil }
        return longShareBps >= 5_000 ? "long" : "short"
    }
}

/// Traders on Perpl mainnet, read live from the exchange contract through Desk's server.
/// Who you follow stays on this phone; the server only ever sees the addresses asked about.
@MainActor
@Observable
final class TraderDirectory {
    private(set) var top: [TraderSnapshot] = []
    private(set) var topProblem: String?
    private(set) var following: [TraderSnapshot] = []
    private(set) var followed: [String]
    /// Names given on this phone. Perpl accounts have no public profile to read one from.
    private(set) var nicknames: [String: String]

    private static let storageKey = "desk.followedTraders"
    private static let nicknameKey = "desk.traderNicknames"
    private static let endpoint = "https://web-lovat-nine-49.vercel.app/api/traders"

    init() {
        followed = UserDefaults.standard.stringArray(forKey: Self.storageKey) ?? []
        nicknames = UserDefaults.standard.dictionary(forKey: Self.nicknameKey) as? [String: String] ?? [:]
    }

    func name(for address: String) -> String {
        nicknames[address.lowercased()] ?? IdentityDirectory.shared.name(for: address) ?? TraderSnapshot.short(address)
    }

    func hasNickname(_ address: String) -> Bool { nicknames[address.lowercased()] != nil }

    func setNickname(_ name: String, for address: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        nicknames[address.lowercased()] = trimmed.isEmpty ? nil : String(trimmed.prefix(24))
        UserDefaults.standard.set(nicknames, forKey: Self.nicknameKey)
        if TradeAlerts.shared.isOn(for: address) { TradeAlerts.shared.namesChanged() }
    }

    func isFollowing(_ address: String) -> Bool {
        followed.contains { $0.caseInsensitiveCompare(address) == .orderedSame }
    }

    /// Following is one idea: a followed trader's wallet is tracked as well, so their
    /// Monad swaps arrive alongside their perps.
    func toggle(_ address: String) {
        if isFollowing(address) {
            followed.removeAll { $0.caseInsensitiveCompare(address) == .orderedSame }
            following.removeAll { $0.id == address.lowercased() }
            TradeAlerts.shared.turnOff(for: address)
            TrackedWallets.shared.untrack(address)
        } else {
            guard followed.count < 20 else { return }
            guard TrackedWallets.shared.isTracking(address) || !TrackedWallets.shared.isFull else { return }
            followed.append(address)
            if let known = top.first(where: { $0.id == address.lowercased() }) { following.append(known) }
            TrackedWallets.shared.track(address, name: nicknames[address.lowercased()] ?? "")
            // Following a Perpl trader includes their position movements. Wallet tracking
            // above covers spot swaps; this opt-in covers opened, changed and closed perps.
            Task {
                if await TradeAlerts.shared.turnOn(for: address), !isFollowing(address) {
                    TradeAlerts.shared.turnOff(for: address)
                }
            }
        }
        UserDefaults.standard.set(followed, forKey: Self.storageKey)
        Task { await refreshFollowing() }
    }

    func run() async {
        // The board as it was last seen, before the first read comes back.
        if top.isEmpty, let url = Self.url(["view": "top"]),
           let cached = await ResponseCache.shared.cached(url),
           let body = try? JSONDecoder().decode(TradersResponse.self, from: cached) {
            top = body.traders
            Task { await IdentityDirectory.shared.resolve(body.traders.map(\.address)) }
        }
        while !Task.isCancelled {
            async let top: Void = refreshTop()
            async let following: Void = refreshFollowing()
            async let scores: Void = refreshScores()
            async let crowd: Void = refreshCrowd()
            _ = await (top, following, scores, crowd)
            try? await Task.sleep(for: .seconds(20))
        }
    }

    func refreshTop() async {
        guard let traders = await fetch(["view": "top"]) else {
            if top.isEmpty { topProblem = "Perpl mainnet could not be read right now." }
            return
        }
        topProblem = nil
        top = traders
        Task { await IdentityDirectory.shared.resolve(traders.map(\.address)) }
    }

    func refreshFollowing() async {
        // Another screen may have followed someone through its own directory.
        followed = UserDefaults.standard.stringArray(forKey: Self.storageKey) ?? followed
        guard !followed.isEmpty else { following = []; return }
        guard let traders = await fetch(["view": "following", "addresses": followed.joined(separator: ",")]) else { return }
        following = traders.filter { isFollowing($0.address) }
        Task { await IdentityDirectory.shared.resolve(traders.map(\.address)) }
    }

    func trader(_ address: String) async -> TraderSnapshot? {
        await fetch(["view": "trader", "address": address])?.first
    }

    /// Every open position on Perpl, added up per market.
    ///
    /// Read on its own clock rather than with the leaderboard: it costs the server the
    /// same full sweep of the contract, and the room's positioning does not turn over
    /// fast enough to be worth asking three times a minute.
    private(set) var crowd: [MarketCrowd] = []
    private var crowdFetchedAt: Date?

    func refreshCrowd() async {
        if let crowdFetchedAt, Date.now.timeIntervalSince(crowdFetchedAt) < 60 { return }
        var components = URLComponents(string: Self.endpoint)!
        components.queryItems = [URLQueryItem(name: "view", value: "crowd")]
        guard let url = components.url,
              let fetched = try? await ResponseCache.shared.data(from: url),
              let body = try? JSONDecoder().decode(CrowdResponse.self, from: fetched.0) else { return }
        crowd = body.markets
        crowdFetchedAt = .now
        Task { await IdentityDirectory.shared.resolve(body.markets.compactMap { $0.biggest?.address }) }
    }

    private struct CrowdResponse: Decodable { let markets: [MarketCrowd] }

    #if DEBUG
    /// The book as it looked on mainnet on 19 September, so the screen can be reviewed
    /// and recorded without waiting for a market to be interesting. Debug only.
    func seedCrowdForReview() {
        crowd = [
            MarketCrowd(market: "BTC", marketId: 1, complete: true, traders: 19, longTraders: 13,
                        shortTraders: 6, longValue: "1624380.44", shortValue: "764120.10",
                        longShareBps: 6800,
                        biggest: .init(address: "0xc8D7f4C1b0F0aE5C9d7a1c0f2B6e8A4d3C5e1DC",
                                       side: "long", value: "137420.00", leverage: 15)),
            MarketCrowd(market: "ETH", marketId: 20, complete: true, traders: 11, longTraders: 3,
                        shortTraders: 8, longValue: "176400.00", shortValue: "663600.00",
                        longShareBps: 2100,
                        biggest: .init(address: "0x92E0b5A3c7D1e4F6a8B2c0D9e3F5a7B1c4D638d2",
                                       side: "short", value: "94180.00", leverage: 8)),
            MarketCrowd(market: "SOL", marketId: 21, complete: false, traders: 7, longTraders: 4,
                        shortTraders: 3, longValue: "48200.00", shortValue: "41800.00",
                        longShareBps: 5356,
                        biggest: .init(address: "0xA77Fd2b4C6e8A0c2D4f6B8a0C2e4D6f8A0b28F57",
                                       side: "long", value: "21600.00", leverage: 4)),
            MarketCrowd(market: "MON", marketId: 30, complete: true, traders: 2, longTraders: 2,
                        shortTraders: 0, longValue: "9120.00", shortValue: "0",
                        longShareBps: 10_000,
                        biggest: .init(address: "0xcCdD1f3a5B7c9E1d3F5a7C9e1B3d5F7a9C1e2406",
                                       side: "long", value: "6400.00", leverage: 3)),
        ]
        crowdFetchedAt = .now
    }
    #endif

    /// Scores from indexed history, by lowercased address.
    private(set) var scores: [String: Int] = [:]
    private(set) var records: [String: TraderRecord] = [:]
    private var scoresFetchedAt: Date?

    func refreshScores() async {
        if let scoresFetchedAt, Date.now.timeIntervalSince(scoresFetchedAt) < 300 { return }
        var components = URLComponents(string: Self.endpoint)!
        components.queryItems = [URLQueryItem(name: "view", value: "scores")]
        guard let url = components.url,
              let fetched = try? await ResponseCache.shared.data(from: url),
              let body = try? JSONDecoder().decode(ScoresResponse.self, from: fetched.0) else { return }
        scores = Dictionary(body.traders.map { ($0.address.lowercased(), $0.score) }, uniquingKeysWith: max)
        records = Dictionary(body.traders.map { ($0.address.lowercased(), TraderRecord(score: $0.score, trades: $0.trades, winRate: $0.winRate, realised: $0.realised)) }, uniquingKeysWith: { a, _ in a })
        scoresFetchedAt = .now
    }

    func history(_ address: String) async -> TraderHistory? {
        var components = URLComponents(string: Self.endpoint)!
        components.queryItems = [URLQueryItem(name: "view", value: "history"), URLQueryItem(name: "address", value: address)]
        guard let url = components.url,
              let fetched = try? await ResponseCache.shared.data(from: url) else { return nil }
        return try? JSONDecoder().decode(TraderHistory.self, from: fetched.0)
    }

    private struct ScoresResponse: Decodable {
        struct Row: Decodable {
            let address: String
            let score: Int
            let trades: Int?
            let winRate: Double?
            let realised: Double?

            init(from decoder: Decoder) throws {
                let box = try decoder.container(keyedBy: Keys.self)
                address = try box.decode(String.self, forKey: .address)
                score = try box.decode(Int.self, forKey: .score)
                trades = try? box.decode(Int.self, forKey: .trades)
                winRate = try? box.decode(Double.self, forKey: .winRate)
                // Realised comes as a number or a fixed-point string depending on the path that wrote it.
                realised = (try? box.decode(Double.self, forKey: .realised)) ?? (try? box.decode(String.self, forKey: .realised)).flatMap(Double.init)
            }
            private enum Keys: String, CodingKey { case address, score, trades, winRate, realised }
        }
        let traders: [Row]
    }

    /// Sorted, so the same question is always the same URL — which is what the
    /// response cache keys on.
    private static func url(_ query: [String: String]) -> URL? {
        var components = URLComponents(string: endpoint)!
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url
    }

    private func fetch(_ query: [String: String]) async -> [TraderSnapshot]? {
        guard let url = Self.url(query),
              let fetched = try? await ResponseCache.shared.data(from: url),
              let body = try? JSONDecoder().decode(TradersResponse.self, from: fetched.0) else { return nil }
        return body.traders
    }

    private struct TradersResponse: Decodable { let traders: [TraderSnapshot] }
}

@MainActor
enum TraderFormat {
    private static func decimal(fractionDigits: ClosedRange<Int>) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = fractionDigits.lowerBound
        formatter.maximumFractionDigits = fractionDigits.upperBound
        return formatter
    }

    private static let prices = [decimal(fractionDigits: 0...2), decimal(fractionDigits: 0...4), decimal(fractionDigits: 0...6)]

    static func dollars(_ text: String?, signed: Bool = true) -> String {
        guard let text, let value = Double(text) else { return Unavailable.text }
        return DisplayCurrency.shared.format(value, signed: signed)
    }

    static func price(_ text: String) -> String {
        guard let value = Double(text) else { return text }
        let formatter = value >= 100 ? prices[0] : (value >= 1 ? prices[1] : prices[2])
        return formatter.string(from: NSNumber(value: value)) ?? text
    }

    /// $14.9K, $326K, $1.2M: the compact form for headline figures.
    static func compact(_ value: Double?, signed: Bool = false) -> String {
        guard let value else { return Unavailable.text }
        return DisplayCurrency.shared.format(value, signed: signed, compact: true)
    }

    static func assetName(_ symbol: String) -> String {
        switch symbol.uppercased() {
        case "BTC": "Bitcoin"
        case "ETH": "Ethereum"
        case "SOL": "Solana"
        case "MON": "Monad"
        case "HYPE": "Hyperliquid"
        case "ZEC": "Zcash"
        case "LIT": "Lighter"
        case "PUMP": "Pump.fun"
        default: symbol
        }
    }

    static func leverage(_ value: Double?) -> String {
        guard let value else { return "" }
        return value.rounded() == value ? "\(Int(value))×" : String(format: "%.1f×", value)
    }
}

/// A blocky mark drawn from the address, the convention wallets already use, so a trader is
/// recognisable without a picture or a name anyone invented.
struct TraderAvatar: View {
    let address: String
    var size: CGFloat = 42

    /// Built once per draw rather than per cell.
    ///
    /// This was a computed property read by `filled` three times per cell and by `tint`
    /// inside the innermost loop — around a hundred and forty rebuilds and several thousand
    /// single-character Strings for one avatar, on a screen that draws twenty of them and
    /// replaces them every twenty seconds.
    private static func seed(of address: String) -> [UInt8] {
        if !address.hasPrefix("0x") { return Array(address.utf8) }
        var out: [UInt8] = []
        out.reserveCapacity(40)
        for character in address.lowercased().dropFirst(2) {
            guard let digit = character.hexDigitValue else { continue }
            out.append(UInt8(digit))
        }
        return out
    }

    /// One bit per cell from the address's own nibbles, so the pattern is as varied as the
    /// address and never repeats a row.
    private func filled(_ seed: [UInt8], row: Int, column: Int) -> Bool {
        guard !seed.isEmpty else { return false }
        let bit = row * 4 + column
        let nibble = seed[(6 + bit / 4 * 3 + column) % seed.count]
        return (nibble >> UInt8(bit % 4)) & 1 == 1
    }

    private func tint(_ seed: [UInt8]) -> Color {
        let hue = Double(seed.prefix(6).reduce(0) { ($0 * 16 + Int($1)) % 360 }) / 360
        return Color(hue: hue, saturation: 0.42, brightness: 0.82)
    }

    var body: some View {
        if let url = IdentityDirectory.shared.identity(for: address)?.avatarURL {
            RemoteImage(url: url, fill: true) { generated }
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.08), lineWidth: 0.5))
                .accessibilityHidden(true)
        } else {
            generated
        }
    }

    private var generated: some View {
        let seed = Self.seed(of: address)
        let tint = tint(seed)
        return Canvas { context, canvas in
            let cells = 7
            let cell = canvas.width / CGFloat(cells + 3)
            let inset = cell * 1.5
            for row in 0..<cells {
                for column in 0..<4 where filled(seed, row: row, column: column) {
                    for mirrored in Set([column, cells - 1 - column]) {
                        let rect = CGRect(x: inset + cell * CGFloat(mirrored), y: inset + cell * CGFloat(row),
                                          width: cell + 0.5, height: cell + 0.5)
                        context.fill(Path(rect), with: .color(tint))
                    }
                }
            }
        }
        .background(tint.opacity(0.16))
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.08), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

struct TraderRecord: Sendable {
    let score: Int
    let trades: Int?
    let winRate: Double?
    let realised: Double?
}

enum LeaderSort: String, CaseIterable, Identifiable {
    case openPnL = "Open PnL", score = "Score", winRate = "Win rate", realised = "Realized"
    var id: String { rawValue }
}

struct TradersFeed: View {
    let directory: TraderDirectory
    let copier: CopyTrader
    let onOpenCopying: () -> Void
    let onSelect: (TraderSnapshot) -> Void
    let onOpenTracked: (TrackedWallet) -> Void
    let onEditTracked: (TrackedWallet) -> Void
    let onAdd: () -> Void
    @State private var sort: LeaderSort = .openPnL

    private var trackedOnly: [TrackedWallet] { TrackedWallets.shared.list.filter { !directory.isFollowing($0.address) } }

    /// Traders without a record sort last on every measure but open PnL, which every row has.
    private var sortedTop: [TraderSnapshot] {
        let top = directory.top
        let key: (TraderSnapshot) -> Double? = { trader in
            let record = directory.records[trader.id]
            switch sort {
            case .openPnL: return nil
            case .score: return record.map { Double($0.score) }
            case .winRate: return record?.winRate
            case .realised: return record?.realised
            }
        }
        if sort == .openPnL { return top }
        return top.enumerated().sorted { a, b in
            switch (key(a.element), key(b.element)) {
            case let (x?, y?): return x == y ? a.offset < b.offset : x > y
            case (nil, nil): return a.offset < b.offset
            case (nil, _): return false
            case (_, nil): return true
            }
        }.map(\.element)
    }

    private func metric(for trader: TraderSnapshot) -> String? {
        guard sort != .openPnL, let record = directory.records[trader.id] else { return nil }
        switch sort {
        case .openPnL: return nil
        case .score: return "Score \(record.score)"
        case .winRate: return record.winRate.map { "Win \(Int(($0 * 100).rounded()))% · \(record.trades ?? 0) trades" }
        case .realised: return record.realised.map { "\($0 >= 0 ? "+" : "−")\(TraderFormat.compact(abs($0))) realized" }
        }
    }

    private var followedSnapshots: [TraderSnapshot] {
        directory.followed.map { address in
            directory.following.first { $0.id == address.lowercased() }
                ?? TraderSnapshot(accountId: nil, address: address, pnl: nil, balance: nil, positions: [])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !copier.traders.isEmpty || !copier.log.isEmpty {
                CopyStatusCard(copier: copier, onOpen: onOpenCopying)
                    .padding(.bottom, 24)
            }
            let tracked = trackedOnly
            header("Following", trailing: directory.followed.isEmpty && tracked.isEmpty ? "Traders and wallets" : "\(directory.followed.count + tracked.count)")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(followedSnapshots) { trader in
                        FollowedCard(trader: trader, name: directory.name(for: trader.address),
                                     isAlerting: TradeAlerts.shared.isOn(for: trader.address)) { onSelect(trader) }
                    }
                    ForEach(tracked) { wallet in
                        TrackedCard(wallet: wallet, onTap: { onOpenTracked(wallet) }, onEdit: { onEditTracked(wallet) })
                    }
                    Button(action: onAdd) {
                        VStack(spacing: 8) {
                            Image(systemName: "plus")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(DeskColor.nightText.color)
                                .frame(width: 36, height: 36)
                                .background(Color.white.opacity(0.1), in: Circle())
                            Text(directory.followed.isEmpty && tracked.isEmpty ? "Follow a wallet" : "Add")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(DeskColor.nightText.color)
                                .lineLimit(1)
                        }
                        .frame(width: directory.followed.isEmpty && tracked.isEmpty ? 138 : 84, height: 98)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
            }
            .padding(.horizontal, -20)
            .padding(.top, 12)
            .padding(.bottom, 28)

            HStack(alignment: .firstTextBaseline) {
                Text("Top traders")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
                Spacer()
                Menu {
                    ForEach(LeaderSort.allCases) { option in
                        Button { withAnimation(.snappy(duration: 0.22)) { sort = option } } label: {
                            if sort == option { Label(option.rawValue, systemImage: "checkmark") } else { Text(option.rawValue) }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(sort.rawValue)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .bold))
                    }
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
                }
            }

            if directory.top.isEmpty, let problem = directory.topProblem {
                Label(problem, systemImage: "exclamationmark.circle.fill")
                    .font(DeskType.caption)
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .padding(.top, 14)
            } else {
                LazyVStack(spacing: 0) {
                    if directory.top.isEmpty {
                        ForEach(0..<8, id: \.self) { index in
                            LeaderRow(trader: TraderSnapshot(accountId: nil, address: "0x00000000000000000000000000000000000000\(index)0",
                                                             pnl: "1000", balance: nil, positions: []),
                                      rank: index + 1, name: "0x0000…0000", isLast: index == 7)
                                .redacted(reason: .placeholder)
                        }
                    } else {
                        let rows = sortedTop
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, trader in
                            Button { onSelect(trader) } label: {
                                LeaderRow(trader: trader, rank: index + 1, name: directory.name(for: trader.address),
                                          score: directory.scores[trader.id], metric: metric(for: trader),
                                          isFollowed: directory.isFollowing(trader.address),
                                          isLast: index == rows.count - 1)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.top, 6)
            }

            Text("Live from Perpl mainnet. PnL is on open positions, funding included. Copying a trade opens your own ticket.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(DeskColor.nightMuted.color.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 18)
        }
    }

    private func header(_ title: String, trailing: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(DeskColor.nightText.color)
            Spacer()
            Text(trailing)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(DeskColor.nightMuted.color)
        }
    }
}

private struct FollowedCard: View {
    let trader: TraderSnapshot
    let name: String
    let isAlerting: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    TraderAvatar(address: trader.address, size: 36)
                    Spacer(minLength: 0)
                    if isAlerting {
                        Image(systemName: "bell.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.5))
                            .accessibilityLabel("Alerts on")
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                        .lineLimit(1)
                    Text(trader.pnl == nil ? "Loading" : TraderFormat.compact(trader.pnl.flatMap(Double.init), signed: true))
                        .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(trader.pnl == nil ? DeskColor.nightMuted.color
                                         : (trader.isProfit ? DeskColor.rise : DeskColor.fall).color)
                }
            }
            .padding(14)
            .frame(width: 138, alignment: .leading)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// A wallet followed for its Monad swaps rather than its perps: same card, its alert
/// floor where the trader card shows open PnL.
private struct TrackedCard: View {
    let wallet: TrackedWallet
    let onTap: () -> Void
    let onEdit: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    TraderAvatar(address: wallet.address, size: 36)
                    Spacer(minLength: 0)
                    Color.clear.frame(width: 28, height: 28)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(IdentityDirectory.shared.name(for: wallet.address) ?? wallet.displayName)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                        .lineLimit(1)
                    Text(wallet.firstBuysOnly ? "First buys · $\(Int(wallet.minUsd))+" : "Swaps · $\(Int(wallet.minUsd))+")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .lineLimit(1)
                }
            }
            .padding(14)
            .frame(width: 138, alignment: .leading)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            Button(action: onEdit) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.65))
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Alert settings for \(wallet.displayName)")
            .padding(9)
        }
    }
}

private struct LeaderRow: View {
    let trader: TraderSnapshot
    let rank: Int
    let name: String
    var score: Int? = nil
    var metric: String? = nil
    var isFollowed = false
    let isLast: Bool

    private var detail: String {
        if let metric { return metric }
        let count = trader.positions.count
        let noun = count == 1 ? "position" : "positions"
        return "\(count) \(noun) · \(TraderFormat.compact(trader.positionValue))" + (score.map { " · Score \($0)" } ?? "")
    }

    var body: some View {
        HStack(spacing: 14) {
            Text("\(rank)")
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(rank <= 3 ? DeskColor.nightText.color : DeskColor.nightMuted.color)
                .frame(width: 20, alignment: .leading)
            TraderAvatar(address: trader.address, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                        .lineLimit(1)
                    if isFollowed {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(DeskColor.nightMuted.color)
                    }
                }
                Text(detail)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
            Spacer(minLength: 8)
            Text(TraderFormat.compact(trader.pnl.flatMap(Double.init), signed: true))
                .font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle((trader.isProfit ? DeskColor.rise : DeskColor.fall).color)
        }
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5).padding(.leading, 78)
            }
        }
        .contentShape(Rectangle())
    }
}

struct TraderProfileScreen: View {
    let initial: TraderSnapshot
    let directory: TraderDirectory
    let copier: CopyTrader
    let onCopy: (TraderPosition) -> Void

    private enum Tab: String, CaseIterable { case positions = "Positions", closed = "Closed", stats = "Stats" }

    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: TraderSnapshot?
    @State private var tab: Tab = .positions
    @State private var isNaming = false
    @State private var draftName = ""
    @State private var pendingCopy: TraderPosition?
    @State private var showsAlertsPrimer = false
    @State private var showsAutoCopy = false
    @State private var history: TraderHistory?
    @State private var historyLoaded = false
    @State private var showsNotificationsOff = false

    private var alerts: TradeAlerts { .shared }
    private var alerting: Bool { alerts.isOn(for: trader.address) }

    private var trader: TraderSnapshot { snapshot ?? initial }
    private var resolved: Identity? { IdentityDirectory.shared.identity(for: trader.address) }
    private var following: Bool { directory.isFollowing(trader.address) }
    private var explorerURL: URL { URL(string: "https://monadvision.com/address/\(trader.address)")! }

    var body: some View {
        ZStack {
            DeskBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    topBar.padding(.horizontal, 20)
                    identity.padding(.horizontal, 20).padding(.top, 20)
                    AutoCopyButton(rules: copier.rules(for: trader.address)) { showsAutoCopy = true }
                        .padding(.horizontal, 20)
                        .padding(.top, 18)
                    tabs.padding(.top, 24)
                    content
                }
                .padding(.bottom, 60)
            }
            .refreshable { snapshot = await directory.trader(trader.address) ?? snapshot }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task {
            while !Task.isCancelled {
                if let fresh = await directory.trader(initial.address) { snapshot = fresh }
                try? await Task.sleep(for: .seconds(15))
            }
        }
        #if DEBUG
        .task {
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-profile-stats") { tab = .stats }
            if arguments.contains("-profile-closed") { tab = .closed }
        }
        #endif
        .task {
            while !Task.isCancelled {
                if let fresh = await directory.history(initial.address) { history = fresh }
                historyLoaded = true
                try? await Task.sleep(for: .seconds(120))
            }
        }
        .alert("Name this trader", isPresented: $isNaming) {
            TextField(trader.shortAddress, text: $draftName)
            Button("Save") { directory.setNickname(draftName, for: trader.address) }
            if directory.hasNickname(trader.address) {
                Button("Remove name", role: .destructive) { directory.setNickname("", for: trader.address) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only you see this name.")
        }
        .confirmationDialog(
            pendingCopy.map { "Copy \($0.isLong ? "long" : "short") \($0.market) at \(TraderFormat.leverage($0.leverage))" } ?? "",
            isPresented: Binding(get: { pendingCopy != nil }, set: { if !$0 { pendingCopy = nil } }),
            titleVisibility: .visible
        ) {
            Button("Open ticket") { if let position = pendingCopy { onCopy(position) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Same market, side and leverage on your own account. You choose the amount.")
        }
        .task { await alerts.refreshPermission() }
        .sheet(isPresented: $showsAutoCopy) {
            AutoCopySheet(address: trader.address, name: directory.name(for: trader.address), copier: copier)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showsAlertsPrimer) {
            AlertsPrimerSheet(
                trader: trader, name: directory.name(for: trader.address),
                onEnable: {
                    alerts.hasSeenPrimer = true
                    showsAlertsPrimer = false
                    Task { await turnOnAlerts() }
                },
                onLater: {
                    alerts.hasSeenPrimer = true
                    showsAlertsPrimer = false
                })
                .fittedSheet()
                .presentationDragIndicator(.visible)
        }
        .alert("Notifications are off for Desk", isPresented: $showsNotificationsOff) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Turn them on in Settings to hear when \(directory.name(for: trader.address)) trades.")
        }
        .alert("Alerts aren't saved", isPresented: Binding(
            get: { alerts.problem != nil },
            set: { if !$0 { alerts.problem = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alerts.problem ?? "")
        }
    }

    private func toggleAlerts() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if alerting {
            withAnimation(.snappy(duration: 0.2)) { alerts.turnOff(for: trader.address) }
        } else if alerts.permission == .denied {
            showsNotificationsOff = true
        } else if !alerts.hasSeenPrimer {
            showsAlertsPrimer = true
        } else {
            Task { await turnOnAlerts() }
        }
    }

    private func turnOnAlerts() async {
        if !(await alerts.turnOn(for: trader.address)) { showsNotificationsOff = true }
    }

    private var topBar: some View {
        HStack {
            circleButton("chevron.left") { dismiss() }
            Spacer()
            ShareLink(item: explorerURL, message: Text("\(directory.name(for: trader.address)) on Perpl")) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .deskGlass(interactive: true, in: Circle())
        }
        .padding(.top, 6)
    }

    private func circleButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .deskGlass(interactive: true, in: Circle())
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                TraderAvatar(address: trader.address, size: 64)
                Spacer(minLength: 12)
                stat(TraderFormat.compact(trader.portfolio), label: "Portfolio")
                Rectangle().fill(Color.white.opacity(0.1)).frame(width: 0.5, height: 40)
                stat(TraderFormat.compact(trader.pnl.flatMap(Double.init), signed: true), label: "Open PnL",
                     tint: trader.pnl == nil ? .white : (trader.isProfit ? DeskColor.rise : DeskColor.fall).color)
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    nameBlock.fixedSize()
                    Spacer(minLength: 0)
                    actions.padding(.top, 20)
                }
                VStack(alignment: .leading, spacing: 16) {
                    nameBlock
                    actions
                }
            }
            .padding(.top, 12)
        }
    }

    private var nameBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Text(directory.name(for: trader.address))
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let score = history?.stats?.score {
                    Button { withAnimation(.snappy(duration: 0.22)) { tab = .stats } } label: {
                        Label("\(score)", systemImage: "gauge.with.dots.needle.67percent")
                            .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(score >= 70 ? DeskColor.rise.color : .white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .deskGlass(interactive: true, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Score \(score). Show stats")
                }
                if let label = resolved?.sourceLabel {
                    Text(label)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .deskGlass(in: Capsule())
                }
            }
            Button {
                UIPasteboard.general.string = trader.address
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Text(directory.hasNickname(trader.address) || resolved?.name != nil ? trader.shortAddress
                     : "Perpl account \(trader.accountId.map { "#\($0)" } ?? "")")
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HStack(spacing: 7) {
                Circle()
                    .fill(trader.positions.isEmpty ? Color.white.opacity(0.35) : DeskColor.rise.color)
                    .frame(width: 7, height: 7)
                Text(trader.positions.isEmpty ? "No open positions" : "In the market")
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.55))
            }
            .padding(.top, 2)
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            outlineButton(following ? "Following" : "Follow", symbol: nil) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                let starting = !following
                withAnimation(.snappy(duration: 0.2)) { directory.toggle(trader.address) }
                if starting && !alerts.hasSeenPrimer && alerts.permission != .denied { showsAlertsPrimer = true }
            }
            if following {
                Button(action: toggleAlerts) {
                    Image(systemName: alerting ? "bell.fill" : "bell")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 36, height: 30)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .deskGlass(interactive: true, in: Capsule())
                .accessibilityLabel(alerting ? "Turn off trade alerts" : "Turn on trade alerts")
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
            outlineButton("Set Name", symbol: "pencil") {
                draftName = directory.nicknames[trader.address.lowercased()] ?? ""
                isNaming = true
            }
        }
    }

    private func stat(_ value: String, label: String, tint: Color = .white) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity)
    }

    private func outlineButton(_ title: String, symbol: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .frame(height: 30)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .deskGlass(interactive: true, in: Capsule())
    }

    private var tabs: some View {
        Picker("Show", selection: $tab.animation(.snappy(duration: 0.22))) {
            ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .positions:
            if trader.positions.isEmpty {
                emptyState(snapshot == nil ? "Loading positions…" : "Nothing open right now.",
                           detail: snapshot == nil ? nil : "Positions appear here the moment this trader opens one.")
            } else {
                // Plain rows, the first version. Kept to compare against the cards below.
                // LazyVStack(spacing: 0) {
                //     ForEach(Array(trader.positions.enumerated()), id: \.element.id) { index, position in
                //         Button { pendingCopy = position } label: {
                //             ProfilePositionRow(position: position, isLast: index == trader.positions.count - 1)
                //         }
                //         .buttonStyle(.plain)
                //     }
                // }
                // .padding(.top, 6)
                LazyVStack(spacing: 10) {
                    ForEach(trader.positions) { position in
                        ProfilePositionCard(position: position) { pendingCopy = position }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
            }
        case .closed:
            TraderTradesList(history: history, loaded: historyLoaded)
        case .stats:
            TraderStatsView(history: history, loaded: historyLoaded)
        }
    }

    private func emptyState(_ title: String, detail: String?) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            if let detail {
                Text(detail)
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 48)
    }
}

private struct ProfilePositionRow: View {
    let position: TraderPosition
    let isLast: Bool

    var body: some View {
        HStack(spacing: 16) {
            MarketTokenLogo(symbol: position.market, size: 50)
            VStack(alignment: .leading, spacing: 4) {
                Text(TraderFormat.assetName(position.market))
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(position.isLong ? "Long" : "Short") \(TraderFormat.leverage(position.leverage)) · \(position.size) \(position.market)")
                    .font(.system(size: 15, weight: .regular, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(TraderFormat.dollars(position.value, signed: false))
                    .font(.system(size: 18, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                Text(TraderFormat.dollars(position.pnl))
                    .font(.system(size: 14, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle((position.isProfit ? DeskColor.rise : DeskColor.fall).color)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5).padding(.leading, 86).padding(.trailing, 20)
            }
        }
        .contentShape(Rectangle())
    }
}

/// A position with everything a copier weighs: side and leverage, PnL, what it is worth,
/// the size and collateral behind it, and where it was entered against where it is now.
private struct ProfilePositionCard: View {
    let position: TraderPosition
    let onCopy: () -> Void

    private var sideTint: DeskRGB { position.isLong ? DeskColor.rise : DeskColor.fall }
    private var pnlTint: DeskRGB { position.isProfit ? DeskColor.rise : DeskColor.fall }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                MarketTokenLogo(symbol: position.market, size: 28)
                Text("\(position.market)-PERP")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("\(position.isLong ? "Long" : "Short") \(TraderFormat.leverage(position.leverage))")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(sideTint.color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(sideTint.color.opacity(0.14), in: Capsule())
                Spacer(minLength: 6)
                Button(action: onCopy) {
                    Label("Copy", systemImage: "square.on.square")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .deskGlass(interactive: true, in: Capsule())
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(TraderFormat.dollars(position.pnl))
                    .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(pnlTint.color)
                    .contentTransition(.numericText())
                if let percent = position.pnlPercent {
                    Text(String(format: "%@%.1f%%", percent < 0 ? Direction.minus : "+", abs(percent)))
                        .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(pnlTint.color.opacity(0.85))
                }
            }

            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    figure("Value", TraderFormat.dollars(position.value, signed: false))
                    figure("Size", "\(position.size) \(position.market)")
                    figure("Collateral", TraderFormat.dollars(position.collateral, signed: false))
                }
                GridRow {
                    figure("Entry", TraderFormat.price(position.entry))
                    figure("Mark", TraderFormat.price(position.mark))
                    figure("Leverage", TraderFormat.leverage(position.leverage))
                }
            }
        }
        .padding(14)
        .deskGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func figure(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.45))
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
