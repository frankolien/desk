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
    private struct Response: Decodable {
        let events: [FollowingTrade]
        let pending: [String]
        let stale: [String]?
    }

    private(set) var events: [FollowingTrade] = []
    private(set) var pending: [String] = []
    private(set) var stale: [String] = []
    private(set) var loaded = false
    private(set) var problem: String?

    func run(addresses: [String]) async {
        guard !addresses.isEmpty else {
            events = []; pending = []; stale = []; loaded = true; problem = nil
            return
        }
        while !Task.isCancelled {
            await load(addresses: addresses)
            try? await Task.sleep(for: .seconds(45))
        }
    }

    func load(addresses: [String]) async {
        guard !addresses.isEmpty else {
            events = []; pending = []; stale = []; loaded = true; problem = nil
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
    let unalertedTraderCount: Int
    let onEnableTraderAlerts: () -> Void
    let notificationsOff: Bool
    let notificationProblem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent activity")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
                Spacer()
                if !addresses.isEmpty {
                    Text("\(addresses.count) following")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                }
            }

            Text("Confirmed token trades from wallets you follow. The feed may lag the chain while a wallet indexes.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(DeskColor.nightMuted.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 7)
                .padding(.bottom, 14)

            if notificationsOff {
                Label("Push alerts are off for Desk in iPhone Settings. The feed still updates here.", systemImage: "bell.slash")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 12)
            } else if let notificationProblem {
                Label(notificationProblem, systemImage: "bell.badge")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 12)
            }

            if unalertedTraderCount > 0 && !notificationsOff {
                Button(action: onEnableTraderAlerts) {
                    Label("Enable position alerts for \(unalertedTraderCount) followed trader\(unalertedTraderCount == 1 ? "" : "s")", systemImage: "bell.badge")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(DeskColor.action.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 12)
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
            } else if !model.loaded {
                ProgressView("Reading followed wallets…")
                    .tint(DeskColor.action.color)
                    .padding(.vertical, 22)
            } else {
                if let problem = model.problem {
                    Label(problem, systemImage: "exclamationmark.circle")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .padding(.bottom, 12)
                }
                if !model.pending.isEmpty {
                    Label("\(model.pending.count) wallet\(model.pending.count == 1 ? " is" : "s are") indexing; new trades will appear here.", systemImage: "clock.arrow.circlepath")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 12)
                }
                if !model.stale.isEmpty {
                    Label("Activity for \(model.stale.count) wallet\(model.stale.count == 1 ? " is" : "s are") catching up with the chain.", systemImage: "clock.arrow.circlepath")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 12)
                }
                if model.events.isEmpty && model.problem == nil && model.pending.count + model.stale.count == addresses.count {
                    Text("Still checking followed wallets. Trades will appear after indexing catches up.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .padding(.vertical, 16)
                } else if model.events.isEmpty && model.problem == nil {
                    Text("No trades found in the indexed wallet activity yet.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .padding(.vertical, 16)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(model.events) { trade in
                            FollowingTradeRow(trade: trade, walletName: name(trade.wallet))
                        }
                    }
                }
            }
        }
    }
}

private struct FollowingTradeRow: View {
    let trade: FollowingTrade
    let walletName: String

    private var timeLabel: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: Date(timeIntervalSince1970: trade.time / 1_000), relativeTo: .now)
    }

    var body: some View {
        Button {
            TokenOpenRequest.shared.open(.init(chainIndex: trade.chainIndex, contract: trade.token, symbol: trade.symbol))
        } label: {
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
                        Text(trade.gain.map { "Realized \($0.formatted(.currency(code: "USD")))" }
                             ?? "On-chain trade · tap to view token")
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
