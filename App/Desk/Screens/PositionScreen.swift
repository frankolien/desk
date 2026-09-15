import DeskPerpl
import DeskUI
import SwiftUI

struct PositionScreen: View {
    let position: PerplPosition
    let market: MarketModel
    let session: TradingSession
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsClose = false

    private var figures: PositionFigures? {
        guard position.marketID == market.market?.id,
              let config = market.market?.config,
              let mark = market.mark.value else { return nil }
        return PositionFigures(position: position, market: config, mark: mark)
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
            .confirmationDialog(
                "Close the entire \(market.symbol) position?",
                isPresented: $confirmsClose,
                titleVisibility: .visible
            ) {
                Button("Close position", role: .destructive) {
                    guard let selected = market.market else { return }
                    Task {
                        await session.closePosition(
                            position, slippageBps: min(50, selected.maxMarketSlippageBps))
                    }
                }
                Button("Keep position", role: .cancel) {}
            } message: {
                Text("This submits a reduce-only market close. It cannot open an opposite position.")
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

                Button(role: .destructive) { confirmsClose = true } label: {
                    Text(session.isBusy ? "Closing…" : "Close position")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                }
                .buttonStyle(.borderedProminent)
                .tint(DeskColor.fall.color)
                .disabled(session.isBusy)

                if let status = session.statusText {
                    Text(status)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(session.hasFailed ? DeskColor.fall.color : DeskColor.nightMuted.color)
                }
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
