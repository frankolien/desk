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
    }
    private struct CachedFeed: Codable {
        let events: [FollowingTrade]
        let pending: [String]
        let stale: [String]
        let savedAt: Date
    }

    private(set) var events: [FollowingTrade] = []
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

    func run(addresses: [String]) async {
        guard !addresses.isEmpty else {
            events = []; pending = []; stale = []; loaded = true; problem = nil; sync = nil
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
            events = []; pending = []; stale = []; loaded = true; problem = nil; sync = nil
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
            pending = feed.pending
            stale = feed.stale ?? []
            sync = feed.sync
            problem = nil
            isShowingCached = false
            lastUpdated = .now
            persist(addresses: addresses)
        } catch {
            guard !Task.isCancelled else { return }
            problem = events.isEmpty
                ? "Following activity couldn’t be loaded. Pull down to retry."
                : "Live refresh failed. Showing your last saved activity."
            isShowingCached = !events.isEmpty
        }
        loaded = true
    }

    private func prepare(addresses: [String]) {
        let key = cacheKey(addresses)
        guard key != activeKey else { return }
        activeKey = key
        events = []
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
        pending = cached.pending
        stale = cached.stale
        lastUpdated = cached.savedAt
        loaded = true
        isShowingCached = true
    }

    private func persist(addresses: [String]) {
        let cache = CachedFeed(events: events, pending: pending, stale: stale, savedAt: .now)
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
                Button(action: onAdd) {
                    Label("Follow a wallet", systemImage: "plus.circle.fill")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(DeskColor.action.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            } else if !model.loaded {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(0..<3, id: \.self) { SkeletonRow(widthFraction: 0.85 - Double($0) * 0.15) }
                }
                .padding(.top, 14)
            } else if model.events.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No confirmed movements yet")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                    Text("Desk will keep this feed ready and add the next confirmed buy or sell from a wallet you track.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 14)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(model.events) { trade in
                        FollowingTradeRow(trade: trade, walletName: name(trade.wallet)) { onOpen(trade) }
                    }
                }
            }
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
                    .buttonStyle(.plain)
                }

                HStack(spacing: 10) {
                    Button {
                        dismiss()
                        onViewWallet()
                    } label: {
                        Label("View wallet", systemImage: "person.crop.circle")
                            .frame(maxWidth: .infinity).frame(height: 50)
                    }
                    .buttonStyle(.plain)
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
        .buttonStyle(.plain)
    }
}
