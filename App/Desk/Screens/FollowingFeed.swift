import DeskUI
import Foundation
import Observation
import SwiftUI

struct FollowingTrade: Decodable, Identifiable, Sendable {
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
    struct Sync: Decodable {
        let workerDelayed: Bool
        let pushDelayed: Bool
    }
    private struct Response: Decodable {
        let events: [FollowingTrade]
        let pending: [String]
        let stale: [String]?
        let sync: Sync?
    }

    private(set) var events: [FollowingTrade] = []
    private(set) var pending: [String] = []
    private(set) var stale: [String] = []
    private(set) var loaded = false
    private(set) var problem: String?
    private(set) var sync: Sync?

    func run(addresses: [String]) async {
        guard !addresses.isEmpty else {
            events = []; pending = []; stale = []; loaded = true; problem = nil; sync = nil
            return
        }
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
        var components = URLComponents(string: "https://web-lovat-nine-49.vercel.app/api/activity")!
        components.queryItems = [
            URLQueryItem(name: "view", value: "feed"),
            URLQueryItem(name: "addresses", value: addresses.joined(separator: ",")),
        ]
        guard let url = components.url else { return }
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
        } catch {
            guard !Task.isCancelled else { return }
            problem = "Following activity couldn't be refreshed. Pull down to retry."
        }
        loaded = true
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
            Text("Recent activity")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(DeskColor.nightText.color)
                .padding(.bottom, 6)

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
                Text("No recent activity yet")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
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
