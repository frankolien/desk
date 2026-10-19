import DeskUI
import Observation
import SwiftUI

/// One smart-money buy: a token bought by one or more wallets OKX rates as consistently
/// profitable, from /api/token-details?view=smart-money.
struct SmartMoneyTrade: Decodable, Identifiable, Sendable {
    let id: String
    let wallet: String?
    let walletCount: Int?
    let chainIndex: String
    let chainName: String
    let token: String
    let symbol: String
    let name: String
    let logoURL: String
    let usd: Double?
    let time: Double?
    let soldPercent: Double?
    let marketCap: Double?
    let change24h: Double?
    let liquidity: Double?
    let winRate: Double?
    let realized: Double?
    var side: String? = nil
}

@MainActor @Observable final class SmartMoneyFeedModel {
    private struct Response: Decodable { let trades: [SmartMoneyTrade]; let monad: [SmartMoneyTrade]? }
    /// Monad's own smart money (Mobula), then OKX's on Base, BNB Chain and Ethereum.
    private(set) var monad: [SmartMoneyTrade] = []
    private(set) var trades: [SmartMoneyTrade] = []
    private(set) var loaded = false
    private(set) var failed = false

    func run() async {
        while !Task.isCancelled {
            await load()
            try? await Task.sleep(for: .seconds(30))
        }
    }

    func load() async {
        let url = URL(string: "https://web-lovat-nine-49.vercel.app/api/token-details?view=smart-money")!
        do {
            let (data, _) = try await ResponseCache.shared.data(from: url)
            let body = try JSONDecoder().decode(Response.self, from: data)
            monad = body.monad ?? []
            trades = body.trades
            failed = false
        } catch {
            failed = trades.isEmpty && monad.isEmpty
        }
        loaded = true
    }
}

/// Signals' Smart Money tab, laid out like a trade feed: who, what they bought and for how
/// much, the token's day and depth, and the lead wallet's last 30 days.
struct SmartMoneyFeedView: View {
    let feed: SmartMoneyFeedModel
    let onOpen: (SmartMoneyTrade) -> Void
    /// The wallet behind a trade: a tap on its name opens its page, where it can be followed or copied.
    var onOpenWallet: ((String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Trades by wallets with a winning 30-day record.")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    Circle().fill(DeskColor.rise.color).frame(width: 7, height: 7)
                    Text("Live").font(.system(size: 13, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(DeskColor.nightText.color)
            }
            .padding(.bottom, 8)

            if feed.trades.isEmpty && feed.monad.isEmpty {
                if feed.failed || feed.loaded {
                    Text(feed.failed ? "Smart money couldn't load. Pull down to try again." : "No smart-money trades right now.")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    SkeletonList(rows: 4, avatarSize: 46, spacing: 22)
                        .padding(.top, 14)
                }
            }
            if !feed.monad.isEmpty {
                sectionTitle("On Monad", detail: "Wallets that made money on Monad over the last 30 days")
                ForEach(feed.monad) { trade in row(trade) }
            }
            if !feed.trades.isEmpty {
                if !feed.monad.isEmpty { sectionTitle("Elsewhere", detail: "Base, BNB Chain and Ethereum, scored by OKX").padding(.top, 14) }
                ForEach(feed.trades) { trade in row(trade) }
            }
            Text("Monad wallets are scored on their own 30-day record. Other chains by OKX.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(DeskColor.nightMuted.color)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
        }
    }

    private func row(_ trade: SmartMoneyTrade) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    if let wallet = trade.wallet { onOpenWallet?(wallet) }
                } label: {
                    HStack(spacing: 10) {
                        if let wallet = trade.wallet { TraderAvatar(address: wallet, size: 30) }
                        Text(walletLine(trade))
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(DeskColor.nightText.color)
                            .lineLimit(1)
                        if trade.wallet != nil, onOpenWallet != nil {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(DeskColor.nightMuted.color)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(trade.wallet == nil || onOpenWallet == nil)
                .accessibilityLabel(trade.wallet.map { "Open wallet \($0)" } ?? "Smart money")
                Spacer()
                if let time = trade.time {
                    Text(Date(timeIntervalSince1970: time / 1000), format: .relative(presentation: .named))
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                }
            }
            Button { onOpen(trade) } label: { body(trade) }
                .buttonStyle(.plain)
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)
        }
        .padding(.vertical, 12)
    }

    /// The trade itself: the token, what was bought or sold, and the lead wallet's record.
    private func body(_ trade: SmartMoneyTrade) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                MarketTokenLogo(symbol: trade.symbol, size: 46, remoteURL: TokenArtwork.url(trade.logoURL))
                VStack(alignment: .leading, spacing: 3) {
                    (Text(trade.side == "sell" ? "Sold " : "Bought ").foregroundStyle(trade.side == "sell" ? DeskColor.fall.color : DeskColor.rise.color)
                        + Text("\(trade.usd.map { CoinRow.compact($0) } ?? "") \(trade.symbol)").foregroundStyle(DeskColor.nightText.color))
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .lineLimit(1)
                    Text("\(trade.name) · \(trade.chainName)")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .lineLimit(1)
                    Text(marketLine(trade))
                        .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
            if let record = recordLine(trade) {
                Text(record)
                    .font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
        }
        .contentShape(Rectangle())
    }

    private func sectionTitle(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(DeskColor.nightText.color)
            Text(detail).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(DeskColor.nightMuted.color)
        }
        .padding(.top, 8)
    }

    private func walletLine(_ trade: SmartMoneyTrade) -> String {
        let short = trade.wallet.map { "\($0.prefix(6))…\($0.suffix(4))" } ?? "Smart money"
        let others = (trade.walletCount ?? 1) - 1
        return others > 0 ? "\(short) + \(others) more" : short
    }

    private func marketLine(_ trade: SmartMoneyTrade) -> String {
        var parts: [String] = []
        if let change = trade.change24h { parts.append(String(format: "24H %+.2f%%", change)) }
        if let liquidity = trade.liquidity { parts.append("LIQ \(CoinRow.compact(liquidity))") }
        else if let cap = trade.marketCap { parts.append("MC \(CoinRow.compact(cap))") }
        if let sold = trade.soldPercent, sold >= 1 { parts.append("\(Int(sold.rounded()))% sold since") }
        return parts.joined(separator: " · ")
    }

    private func recordLine(_ trade: SmartMoneyTrade) -> String? {
        guard trade.winRate != nil || trade.realized != nil else { return nil }
        var parts = ["30D"]
        if let rate = trade.winRate { parts.append(String(format: "Win rate %.1f%%", rate)) }
        if let realized = trade.realized { parts.append("Realized \(realized < 0 ? "−" : "")\(CoinRow.compact(abs(realized)))") }
        return parts.joined(separator: " · ")
    }
}
