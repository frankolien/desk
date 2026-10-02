import DeskUI
import Foundation
import Observation
import SwiftUI

struct FollowingTrade: Codable, Identifiable, Sendable {
    let wallet: String
    let chainIndex: String
    let time: Double
    let hash: String
    let token: String
    let symbol: String
    let side: String
    let amount: Double?
    let value: Double
    let gain: Double?

    var id: String { "\(wallet):\(hash):\(token):\(side)" }
    var isBuy: Bool { side == "buy" }
}

struct FollowingPerp: Codable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case opened, added, reduced, flipped, closed }

    let wallet: String
    let time: Double
    let kind: Kind
    let market: String
    let marketId: Int?
    let side: String
    let leverage: Double?
    let entry: Double?
    let value: Double?
    let previousValue: Double?

    var id: String { "\(wallet):\(market):\(kind.rawValue):\(Int(time))" }
    var isLong: Bool { side == "long" }

    private enum CodingKeys: String, CodingKey { case wallet, time, kind, market, marketId, side, leverage, entry, value, previousValue }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        wallet = try box.decode(String.self, forKey: .wallet)
        kind = try box.decode(Kind.self, forKey: .kind)
        market = try box.decode(String.self, forKey: .market)
        side = try box.decode(String.self, forKey: .side)
        guard let time = Self.number(box, .time), time > 0, time < 1e15, !market.isEmpty, side == "long" || side == "short" else {
            throw DecodingError.dataCorruptedError(forKey: .time, in: box, debugDescription: "Incomplete perps row")
        }
        self.time = time
        marketId = Self.number(box, .marketId).flatMap { Int(exactly: $0) }
        leverage = Self.number(box, .leverage).flatMap { $0 > 0 && $0 < 10_000 ? $0 : nil }
        entry = Self.number(box, .entry)
        value = Self.number(box, .value)
        previousValue = Self.number(box, .previousValue)
    }

    private static func number(_ box: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Double? {
        if let number = try? box.decode(Double.self, forKey: key) { return number }
        return (try? box.decode(String.self, forKey: key)).flatMap(Double.init)
    }
}

enum FollowingItem: Identifiable {
    case spot(FollowingTrade)
    case perp(FollowingPerp)

    var id: String {
        switch self {
        case .spot(let trade): "spot:" + trade.id
        case .perp(let move): "perp:" + move.id
        }
    }

    var time: Double {
        switch self {
        case .spot(let trade): trade.time
        case .perp(let move): move.time
        }
    }
}

private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

@MainActor
@Observable
final class FollowingFeedModel {
    struct Sync: Codable {
        let workerDelayed: Bool
        let pushDelayed: Bool
    }
    private struct Response: Decodable {
        let events: [FollowingTrade]
        let pending: [String]
        let stale: [String]?
        let sync: Sync?
        let perps: [Lossy<FollowingPerp>]?
    }
    private struct CachedFeed: Codable {
        let events: [FollowingTrade]
        let pending: [String]
        let stale: [String]
        let savedAt: Date
        var perps: [FollowingPerp]?
    }

    private(set) var events: [FollowingTrade] = []
    private(set) var perps: [FollowingPerp] = []
    private(set) var pending: [String] = []
    private(set) var stale: [String] = []
    private(set) var loaded = false
    private(set) var isRefreshing = false
    private(set) var isShowingCached = false
    private(set) var lastUpdated: Date?
    private(set) var problem: String?
    private(set) var sync: Sync?
    private var activeKey = ""

    var updatedLabel: String? {
        guard let lastUpdated else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Updated " + formatter.localizedString(for: lastUpdated, relativeTo: .now)
    }

    var items: [FollowingItem] {
        (events.map(FollowingItem.spot) + perps.map(FollowingItem.perp)).sorted { $0.time > $1.time }
    }

    func run(addresses: [String]) async {
        guard !addresses.isEmpty else {
            events = []; perps = []; pending = []; stale = []; loaded = true; problem = nil; sync = nil
            return
        }
        prepare(addresses: addresses)
        while !Task.isCancelled {
            await load(addresses: addresses)
            try? await Task.sleep(for: .seconds(45))
        }
    }

    func load(addresses: [String]) async {
        guard !addresses.isEmpty else {
            events = []; perps = []; pending = []; stale = []; loaded = true; problem = nil; sync = nil
            return
        }
        prepare(addresses: addresses)
        var components = URLComponents(string: "https://web-lovat-nine-49.vercel.app/api/activity")!
        components.queryItems = [
            URLQueryItem(name: "view", value: "feed"),
            URLQueryItem(name: "addresses", value: addresses.joined(separator: ",")),
        ]
        guard let url = components.url else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard !Task.isCancelled else { return }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let feed = try JSONDecoder().decode(Response.self, from: data)
            events = feed.events
            perps = feed.perps?.compactMap(\.value) ?? []
            pending = feed.pending
            stale = feed.stale ?? []
            sync = feed.sync
            problem = nil
            isShowingCached = false
            lastUpdated = .now
            persist(addresses: addresses)
        } catch {
            guard !Task.isCancelled else { return }
            let empty = events.isEmpty && perps.isEmpty
            problem = empty
                ? "Following activity couldn’t be loaded. Pull down to retry."
                : "Live refresh failed. Showing your last saved activity."
            isShowingCached = !empty
        }
        loaded = true
    }

    private func prepare(addresses: [String]) {
        let key = cacheKey(addresses)
        guard key != activeKey else { return }
        activeKey = key
        events = []
        perps = []
        pending = []
        stale = []
        sync = nil
        problem = nil
        loaded = false
        lastUpdated = nil
        guard let data = UserDefaults.standard.data(forKey: key),
              let cached = try? JSONDecoder().decode(CachedFeed.self, from: data)
        else { return }
        events = cached.events
        perps = cached.perps ?? []
        pending = cached.pending
        stale = cached.stale
        lastUpdated = cached.savedAt
        loaded = true
        isShowingCached = true
    }

    private func persist(addresses: [String]) {
        let cache = CachedFeed(events: events, pending: pending, stale: stale, savedAt: .now, perps: perps)
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: cacheKey(addresses))
        }
    }

    private func cacheKey(_ addresses: [String]) -> String {
        "desk.following.feed." + addresses.map(TrackedWallet.key).sorted().joined(separator: ",")
    }
}

struct FollowingFeed: View {
    let model: FollowingFeedModel
    let addresses: [String]
    let name: (String) -> String
    let onAdd: () -> Void
    let onOpen: (FollowingTrade) -> Void
    let onOpenPerp: (FollowingPerp) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent activity")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
                Spacer()
                if model.isRefreshing {
                    ProgressView().controlSize(.small).tint(DeskColor.nightMuted.color)
                } else if let updated = model.updatedLabel {
                    Text(updated)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                }
            }
            .padding(.bottom, 6)

            if let problem = model.problem {
                Label(problem, systemImage: model.isShowingCached ? "clock.arrow.circlepath" : "wifi.exclamationmark")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(model.isShowingCached ? DeskColor.action.color : DeskColor.nightMuted.color)
                    .padding(.vertical, 10)
            } else if !model.pending.isEmpty || !model.stale.isEmpty {
                let count = model.pending.count + model.stale.count
                Label("Indexing \(count) followed \(count == 1 ? "wallet" : "wallets")", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .padding(.vertical, 10)
            }

            if addresses.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Your first signal takes three steps")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                    guideStep("1", "Follow a wallet you want to learn from")
                    guideStep("2", "Desk shows their trades on Monad and their perps on Perpl")
                    guideStep("3", "Inspect the movement, then decide whether to trade")
                    Button(action: onAdd) {
                        Label("Follow your first wallet", systemImage: "plus")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(DeskColor.onAction.color)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(DeskColor.action.color, in: Capsule())
                    }
                    .buttonStyle(DeskPressStyle(scale: 0.98))
                }
                .padding(18)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(.top, 8)
            } else if !model.loaded {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(0..<3, id: \.self) { SkeletonRow(widthFraction: 0.85 - Double($0) * 0.15) }
                }
                .padding(.top, 14)
            } else if model.items.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No confirmed movements yet")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                    Text("Desk shows their trades on Monad and, with alerts on, their perps moves on Perpl.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 14)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(model.items) { item in
                        switch item {
                        case .spot(let trade):
                            FollowingTradeRow(trade: trade, walletName: name(trade.wallet)) { onOpen(trade) }
                        case .perp(let move):
                            FollowingPerpRow(move: move, walletName: name(move.wallet)) { onOpenPerp(move) }
                        }
                    }
                }
            }
        }
    }

    private func guideStep(_ number: String, _ text: String) -> some View {
        HStack(spacing: 11) {
            Text(number)
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(DeskColor.night.color)
                .frame(width: 24, height: 24)
                .background(DeskColor.action.color, in: Circle())
            Text(text)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(DeskColor.nightText.color.opacity(0.86))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct FollowingTradeDetailSheet: View {
    let trade: FollowingTrade
    let walletName: String
    let onViewWallet: () -> Void
    let onViewToken: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private var timeLabel: String {
        Date(timeIntervalSince1970: trade.time / 1_000)
            .formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    TraderAvatar(address: trade.wallet, size: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(walletName)
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                        Text(timeLabel)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(DeskColor.nightMuted.color)
                    }
                    Spacer()
                    Text(trade.isBuy ? "BUY" : "SELL")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .foregroundStyle((trade.isBuy ? DeskColor.rise : DeskColor.fall).color)
                        .padding(.horizontal, 9)
                        .frame(height: 26)
                        .background((trade.isBuy ? DeskColor.rise : DeskColor.fall).color.opacity(0.14), in: Capsule())
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text(trade.isBuy ? "Bought" : "Sold")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                    Text(trade.value.formatted(.currency(code: "USD").precision(.fractionLength(2))))
                        .font(.system(size: 36, weight: .heavy, design: .rounded).monospacedDigit())
                    HStack(spacing: 10) {
                        MarketTokenLogo(symbol: trade.symbol, size: 36)
                        Text(trade.symbol)
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                        if let amount = trade.amount {
                            Text("· \(amount.formatted(.number.precision(.fractionLength(0...4)))) tokens")
                                .font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
                                .foregroundStyle(DeskColor.nightMuted.color)
                        }
                    }
                }
                .padding(18)
                .deskGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                VStack(spacing: 0) {
                    detailRow("Network", trade.chainIndex == "143" ? "Monad" : "Chain \(trade.chainIndex)")
                    detailRow("Source", "Confirmed on-chain movement")
                    Button {
                        UIPasteboard.general.string = trade.hash
                        copied = true
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        HStack {
                            Text("Transaction")
                            Spacer()
                            Text(copied ? "Copied" : "\(trade.hash.prefix(7))…\(trade.hash.suffix(5))")
                                .monospaced()
                                .foregroundStyle(copied ? DeskColor.rise.color : DeskColor.nightMuted.color)
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                        .frame(height: 44)
                    }
                    .buttonStyle(DeskPressStyle())
                }

                HStack(spacing: 10) {
                    Button {
                        dismiss()
                        onViewWallet()
                    } label: {
                        Label("View wallet", systemImage: "person.crop.circle")
                            .frame(maxWidth: .infinity).frame(height: 50)
                    }
                    .buttonStyle(DeskPressStyle())
                    .deskGlass(interactive: true, in: Capsule())

                    Button {
                        dismiss()
                        onViewToken()
                    } label: {
                        Label("View token", systemImage: "chart.line.uptrend.xyaxis")
                            .frame(maxWidth: .infinity).frame(height: 50)
                            .foregroundStyle(DeskColor.onAction.color)
                            .background(DeskColor.action.color, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .font(.system(size: 13, weight: .bold, design: .rounded))

                Spacer(minLength: 0)
            }
            .padding(20)
            .foregroundStyle(DeskColor.nightText.color)
            .background(DeskBackground())
            .navigationTitle("Trade movement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(DeskColor.nightMuted.color)
            Spacer()
            Text(value).foregroundStyle(DeskColor.nightText.color)
        }
        .font(.system(size: 13, weight: .semibold, design: .rounded))
        .frame(height: 40)
    }
}

private struct FollowingTradeRow: View {
    let trade: FollowingTrade
    let walletName: String
    let onOpen: () -> Void

    private static func compact(_ value: Double) -> String {
        let magnitude = abs(value)
        if magnitude >= 1e9 { return String(format: "%.1fB", magnitude / 1e9) }
        if magnitude >= 1e6 { return String(format: "%.1fM", magnitude / 1e6) }
        if magnitude >= 1e3 { return String(format: "%.1fK", magnitude / 1e3) }
        if magnitude >= 100 { return String(format: "%.0f", magnitude) }
        return String(format: magnitude >= 1 ? "%.2f" : "%.4f", magnitude)
    }

    private var detail: String {
        var parts: [String] = []
        if let amount = trade.amount, amount > 0 { parts.append("\(trade.isBuy ? "+" : "−")\(Self.compact(amount)) \(trade.symbol)") }
        if let gain = trade.gain, abs(gain) >= 0.01 { parts.append("\(gain >= 0 ? "+" : "−")\(abs(gain).formatted(.currency(code: "USD")))") }
        return parts.joined(separator: " · ")
    }

    private var timeLabel: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: Date(timeIntervalSince1970: trade.time / 1_000), relativeTo: .now)
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 10) {
                    TraderAvatar(address: trade.wallet, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(walletName).font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(DeskColor.nightText.color).lineLimit(1)
                        Text(trade.chainIndex == "501" ? "Following · Solana" : "Following · Monad")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(DeskColor.nightMuted.color)
                    }
                    Spacer(minLength: 4)
                    Text(timeLabel)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                }
                HStack(spacing: 12) {
                    MarketTokenLogo(symbol: trade.symbol, size: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Text(trade.isBuy ? "Bought" : "Sold")
                                .foregroundStyle(trade.isBuy ? DeskColor.rise.color : DeskColor.fall.color)
                            Text("\(trade.value.formatted(.currency(code: "USD").precision(.fractionLength(2)))) \(trade.symbol)")
                                .foregroundStyle(DeskColor.nightText.color)
                        }
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .lineLimit(1).minimumScaleFactor(0.8)
                        Text(detail)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(DeskColor.nightMuted.color)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DeskColor.nightMuted.color)
                }
            }
            .padding(.vertical, 15)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(DeskPressStyle())
    }
}

private struct FollowingPerpRow: View {
    let move: FollowingPerp
    let walletName: String
    let onOpen: () -> Void

    private var tint: Color {
        switch move.kind {
        case .closed, .reduced: DeskColor.nightMuted.color
        default: (move.isLong ? DeskColor.rise : DeskColor.fall).color
        }
    }

    private var verb: String {
        switch move.kind {
        case .opened: "Opened"
        case .added: "Added to"
        case .reduced: "Trimmed"
        case .flipped: "Flipped to"
        case .closed: "Closed"
        }
    }

    private var subject: String {
        let leverage = TraderFormat.leverage(move.leverage)
        let levered = leverage.isEmpty ? "\(move.side) \(move.market)" : "\(leverage) \(move.side) \(move.market)"
        let value = move.value.map { TraderFormat.compact($0) }
        let change = move.previousValue.map { TraderFormat.compact($0) }.flatMap { from in value.map { "\(from) → \($0)" } } ?? value
        switch move.kind {
        case .opened, .flipped: return value.map { "\(levered) · \($0)" } ?? levered
        case .added, .reduced: return change.map { "\(move.market) \(move.side) · \($0)" } ?? "\(move.market) \(move.side)"
        case .closed: return "\(move.market) \(move.side)"
        }
    }

    private var detail: String {
        var parts = ["\(move.market)-PERP"]
        if let entry = move.entry, entry > 0 { parts.append("Entry \(TraderFormat.price(String(entry)))") }
        return parts.joined(separator: " · ")
    }

    private var timeLabel: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: Date(timeIntervalSince1970: move.time / 1_000), relativeTo: .now)
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 10) {
                    TraderAvatar(address: move.wallet, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(walletName).font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(DeskColor.nightText.color).lineLimit(1)
                        Text("Following · Perpl")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(DeskColor.nightMuted.color)
                    }
                    Spacer(minLength: 4)
                    Text(timeLabel)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                }
                HStack(spacing: 12) {
                    MarketTokenLogo(symbol: move.market, size: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Text(verb).foregroundStyle(tint)
                            Text(subject).foregroundStyle(DeskColor.nightText.color)
                        }
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .lineLimit(1).minimumScaleFactor(0.8)
                        Text(detail)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(DeskColor.nightMuted.color)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DeskColor.nightMuted.color)
                }
            }
            .padding(.vertical, 15)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(DeskPressStyle())
    }
}
