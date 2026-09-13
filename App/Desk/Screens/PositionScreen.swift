import DeskUI
import SwiftUI

/// Profit and loss first, liquidation second, then size, then reference prices. The
/// mobile ordering, not the desktop table's.
struct PositionScreen: View {
    let model: AppModel
    let isStale: Bool

    var body: some View {
        ZStack {
            DeskBackground()
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 9) {
                    AssetMark.bitcoin(size: 30)
                    Text("Long BTC · 3×")
                        .font(DeskType.label)
                        .foregroundStyle(DeskColor.nightMuted.color)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: Direction.up.symbolName)
                            .foregroundStyle(DeskColor.rise.color)
                        Text("+42.18 AUSD")
                            .font(DeskType.display)
                            .foregroundStyle(DeskColor.rise.color)
                    }
                    // The denominator is named because there is no standard one:
                    // Hyperliquid divides by equity, Binance by entry margin, OKX by
                    // position margin. They are not interchangeable.
                    Text("+4.2% on margin")
                        .font(DeskType.caption)
                        .foregroundStyle(DeskColor.nightMuted.color)
                }
                // Field-level staleness: mark, PnL and liquidation derive from the same
                // tick, so they dim and freeze together.
                .opacity(isStale ? 0.55 : 1)

                VStack(spacing: 12) {
                    ValueRow(label: "Liquidation", value: "62,315.40", detail: "7.6% away",
                             tint: DeskColor.fall, isDimmed: isStale)
                    ValueRow(label: "Size", value: "1,000.00 AUSD", detail: "0.0148 BTC")
                    ValueRow(label: "Entry", value: "66,980.10")
                    ValueRow(label: "Mark", value: "67,412.30", isDimmed: isStale)
                    // Entry, size and funding do not dim: they are still true.
                    ValueRow(label: "Funding", value: "\(Direction.minus)0.83 AUSD",
                             detail: "since you opened")
                }

                Spacer()

                PrimaryButton(title: "Close position", tint: DeskColor.fall) {}
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
        }
    }
}
