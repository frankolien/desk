import DeskPerpl
import DeskUI
import SwiftUI

struct PositionScreen: View {
    let model: AppModel
    let market: MarketModel
    @Environment(\.dismiss) private var dismiss

    private var figures: PositionFigures? {
        guard let held = model.openPosition,
              held.marketID == market.market?.id,
              let config = market.market?.config,
              let mark = market.mark.value else { return nil }
        return PositionFigures(position: held, market: config, mark: mark)
    }

    private var stale: Bool { market.freshness.freezesDigits }

    var body: some View {
        NavigationStack {
            ZStack {
                DeskBackground()
                if let figures { content(figures) } else { unavailable }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }

    private func content(_ figures: PositionFigures) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    MarketTokenLogo(symbol: market.symbol, size: 34)
                    Text("\(figures.side == .long ? "Long" : "Short") \(market.symbol)")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("\(figures.leverageHundredths / 100)×")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.white.opacity(0.1), in: Capsule())
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text((figures.unrealisedPnL.isNegative ? "" : "+")
                         + figures.unrealisedPnL.display() + " AUSD")
                        .font(.system(size: 42, weight: .heavy, design: .rounded).monospacedDigit())
                        .foregroundStyle(figures.isProfit ? DeskColor.rise.color : DeskColor.fall.color)
                        .contentTransition(.numericText())
                    Text(HomeScreen.percent(figures.returnOnMarginMicros) + " on margin")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                }
                .opacity(stale ? 0.55 : 1)

                VStack(spacing: 10) {
                    ValueRow(
                        label: "Liquidation",
                        value: figures.liquidationPrice?.display(fractionDigits: figures.entry.decimals) ?? Unavailable.text,
                        detail: figures.liquidationDistanceMicros.map {
                            $0 == 0 ? "At liquidation" : HomeScreen.percent($0, signed: false) + " away"
                        }, tint: DeskColor.fall, isDimmed: stale)
                    ValueRow(
                        label: "Size",
                        value: figures.size.display(fractionDigits: figures.size.decimals) + " \(market.symbol)",
                        detail: figures.collateral.display() + " AUSD collateral")
                    ValueRow(label: "Entry", value: figures.entry.display(fractionDigits: figures.entry.decimals))
                    ValueRow(label: "Mark", value: figures.mark.display(fractionDigits: figures.mark.decimals), isDimmed: stale)
                    ValueRow(label: "Funding", value: figures.fundingSinceEntry.map { $0.display() + " AUSD" } ?? Unavailable.text,
                             detail: "since you opened")
                }

                Text("Closing is coming next. Desk will not fake it by sending an opposite order, which could increase risk instead of reducing this position.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(DeskColor.nightText.color)
            .padding(20)
        }
    }

    private var unavailable: some View {
        ContentUnavailableView("Position unavailable", systemImage: "chart.xyaxis.line",
            description: Text("Waiting for the authenticated Perpl position stream."))
            .foregroundStyle(DeskColor.nightText.color)
    }
}
