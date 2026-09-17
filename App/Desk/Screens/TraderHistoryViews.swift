import DeskUI
import SwiftUI

/// A trader's record from Perpl's position events: statistics, style, one score and the
/// last closed trades. Built on the server from the chain; nothing here is estimated.
struct TraderHistory: Decodable, Sendable {
    struct Market: Decodable, Sendable { let symbol: String; let pnl: Double; let count: Int }

    struct Stats: Decodable, Sendable {
        let trades: Int
        let wins: Int
        let losses: Int
        let winRate: Double?
        let profitFactor: Double?
        let realised: Double
        let grossProfit: Double
        let grossLoss: Double
        let maxDrawdown: Double
        let bestStreak: Int
        let worstStreak: Int
        let averageHoldSeconds: Double?
        let averageLeverage: Double?
        let liquidations: Int
        let volume: Double
        let since: Double?
        let bestMarket: Market?
        let worstMarket: Market?
        let tags: [String]
        let score: Int?
    }

    struct Trade: Decodable, Sendable, Identifiable {
        let time: Double?
        let market: String
        let side: String
        let entry: Double?
        let exit: Double?
        let pnl: Double
        let holdSeconds: Double?
        let leverage: Double?
        let liquidated: Bool

        var id: String { "\(time ?? 0)-\(market)-\(side)-\(pnl)" }
        var isLong: Bool { side == "long" }
        var date: Date? { time.map { Date(timeIntervalSince1970: $0) } }
    }

    let stats: Stats?
    let summary: String?
    let summarySource: String?
    let trades: [Trade]

    static func duration(_ seconds: Double?) -> String {
        guard let seconds else { return Unavailable.text }
        switch seconds {
        case ..<60: return "\(Int(seconds)) s"
        case ..<3600: return "\(Int(seconds / 60)) min"
        case ..<86_400: return String(format: "%.1f h", seconds / 3600)
        default: return String(format: "%.1f d", seconds / 86_400)
        }
    }
}

/// The score as a native gauge, tinted by band.
struct TraderScoreGauge: View {
    let score: Int

    private var tint: Color {
        switch score {
        case 70...: DeskColor.rise.color
        case 40..<70: DeskColor.action.color
        default: DeskColor.fall.color
        }
    }

    var body: some View {
        Gauge(value: Double(score), in: 0...100) {
            Text("Score")
        } currentValueLabel: {
            Text("\(score)").font(.system(size: 15, weight: .bold, design: .rounded)).monospacedDigit()
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(tint)
        .accessibilityLabel("Trader score \(score) out of 100")
    }
}

/// The closed-trades tab.
struct TraderTradesList: View {
    let history: TraderHistory?
    let loaded: Bool

    var body: some View {
        if let trades = history?.trades, !trades.isEmpty {
            GlassSection(footer: "The last \(trades.count) round trips, from Perpl's position events. PnL includes partial closes, before funding.") {
                ForEach(trades) { trade in
                    HStack(spacing: 10) {
                        MarketTokenLogo(symbol: trade.market, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                Text("\(trade.isLong ? "Long" : "Short") \(trade.market)\(trade.leverage.map { " \(TraderFormat.leverage($0))" } ?? "")")
                                    .fontWeight(.medium)
                                if trade.liquidated {
                                    Text("LIQUIDATED")
                                        .font(.system(size: 9, weight: .heavy))
                                        .foregroundStyle(DeskColor.fall.color)
                                }
                            }
                            Text(detail(trade))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text(DisplayCurrency.shared.format(trade.pnl, signed: true))
                            .fontWeight(.semibold)
                            .monospacedDigit()
                            .foregroundStyle((trade.pnl < 0 ? DeskColor.fall : DeskColor.rise).color)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        } else {
            ContentUnavailableView(
                loaded ? "No Closed Trades Yet" : "Loading Trades…",
                systemImage: "clock.arrow.circlepath",
                description: Text(loaded ? "Closed trades appear here as Desk indexes Perpl's history." : ""))
                .padding(.top, 20)
        }
    }

    private func detail(_ trade: TraderHistory.Trade) -> String {
        var parts: [String] = []
        if let entry = trade.entry, let exit = trade.exit {
            parts.append("\(TraderFormat.price(String(entry))) → \(TraderFormat.price(String(exit)))")
        }
        if let hold = trade.holdSeconds { parts.append("held \(TraderHistory.duration(hold))") }
        if let date = trade.date { parts.append(date.formatted(.relative(presentation: .named))) }
        return parts.joined(separator: " · ")
    }
}

/// The statistics tab: score, style, and the figures behind them.
struct TraderStatsView: View {
    let history: TraderHistory?
    let loaded: Bool

    var body: some View {
        if let stats = history?.stats, stats.trades > 0 {
            VStack(alignment: .leading, spacing: 18) {
                GlassSection {
                    HStack(alignment: .top, spacing: 14) {
                        if let score = stats.score { TraderScoreGauge(score: score) }
                        VStack(alignment: .leading, spacing: 6) {
                            if let summary = history?.summary {
                                Text(summary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if history?.summarySource == "ai" {
                                Label("Summarised from the figures below", systemImage: "sparkles")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !stats.tags.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(stats.tags, id: \.self) { tag in
                                    Text(tag)
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 4)
                                        .deskGlass(in: Capsule())
                                }
                            }
                        }
                    }
                }

                GlassSection("Performance") {
                    GlassRow("Realised PnL") {
                        Text(DisplayCurrency.shared.format(stats.realised, signed: true))
                            .foregroundStyle((stats.realised < 0 ? DeskColor.fall : DeskColor.rise).color)
                            .monospacedDigit()
                    }
                    GlassRow("Win rate", value: stats.winRate.map { String(format: "%.0f%% · %d–%d", $0 * 100, stats.wins, stats.losses) } ?? Unavailable.text)
                    GlassRow("Profit factor", value: stats.profitFactor.map { String(format: "%.2f", $0) } ?? (stats.grossProfit > 0 ? "No losses" : Unavailable.text))
                    GlassRow("Max drawdown", value: DisplayCurrency.shared.format(stats.maxDrawdown))
                    GlassRow("Streaks", value: "\(stats.bestStreak) wins · \(stats.worstStreak) losses")
                }

                GlassSection("Style", footer: footer(stats)) {
                    GlassRow("Average hold", value: TraderHistory.duration(stats.averageHoldSeconds))
                    GlassRow("Average leverage", value: stats.averageLeverage.map { String(format: "%.1f×", $0) } ?? Unavailable.text)
                    if let best = stats.bestMarket {
                        GlassRow("Best market", value: "\(best.symbol) · \(DisplayCurrency.shared.format(best.pnl, signed: true))")
                    }
                    if let worst = stats.worstMarket {
                        GlassRow("Worst market", value: "\(worst.symbol) · \(DisplayCurrency.shared.format(worst.pnl, signed: true))")
                    }
                    GlassRow("Volume traded", value: TraderFormat.compact(stats.volume))
                    GlassRow("Liquidations", value: "\(stats.liquidations)")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        } else {
            ContentUnavailableView(
                loaded ? "Not Enough History" : "Loading Stats…",
                systemImage: "chart.bar.xaxis",
                description: Text(loaded ? "Stats appear once this trader has closed trades Desk has indexed." : ""))
                .padding(.top, 20)
        }
    }

    private func footer(_ stats: TraderHistory.Stats) -> String {
        let since = stats.since.map { "since \(Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .omitted))" } ?? ""
        return "From \(stats.trades) closed trades on Perpl mainnet \(since). The score weighs win rate, profit factor and drawdown by how many trades and how much money back them."
    }
}
