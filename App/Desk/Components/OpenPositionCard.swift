import DeskMoney
import DeskPerpl
import DeskUI
import SwiftUI

/// An open position, at a glance.
///
/// A compact portfolio row. Full risk analysis belongs on the detail screen; repeating it
/// inside every row made a handful of positions consume the whole Perps page.
///
/// Mark, profit and liquidation distance descend from a single tick and therefore dim as
/// a group when the price goes stale. Entry, size and leverage do not dim: they are still
/// true whatever the network is doing, and dimming them would say otherwise.
struct OpenPositionCard: View {
    let figures: PositionFigures
    let symbol: String
    let isStale: Bool
    let onTap: () -> Void

    private var tint: DeskRGB { figures.isProfit ? DeskColor.rise : DeskColor.fall }

    /// Amber under five percent of room, red under two. The thresholds are the point at
    /// which a normal candle can end the position, not a taste.
    private var liquidationTint: DeskRGB {
        guard let distance = figures.liquidationDistanceMicros else { return DeskColor.nightMuted }
        switch distance {
        case ..<20_000: return DeskColor.fall
        case ..<50_000: return DeskColor.action
        default: return DeskColor.nightMuted
        }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                MarketTokenLogo(symbol: symbol, size: 38)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text("\(figures.side == .long ? "Long" : "Short") \(symbol)")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                        Text("\(figures.leverageHundredths / 100)×")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.white.opacity(0.1), in: Capsule())
                    }
                    Text("Entry " + figures.entry.display(fractionDigits: figures.entry.decimals)
                         + " · Liq. " + (figures.liquidationPrice?.display(
                            fractionDigits: figures.entry.decimals) ?? Unavailable.text))
                        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    Text((figures.unrealisedPnL.isNegative ? "" : "+")
                         + figures.unrealisedPnL.display() + " AUSD")
                        .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(tint.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(HomeScreen.percent(figures.returnOnMarginMicros) + " margin")
                        .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(tint.color)
                }
                .opacity(isStale ? 0.55 : 1)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
            .padding(.horizontal, 14)
            .frame(height: 82)
            .background(DeskColor.nightChip.color.opacity(0.6),
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(DeskColor.nightLine.color, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private var header: some View {
        HStack(spacing: 10) {
            MarketTokenLogo(symbol: symbol, size: 30)

            Text("\(figures.side == .long ? "Long" : "Short") \(symbol)")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(DeskColor.nightText.color)

            Text("\(figures.leverageHundredths / 100)×")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(DeskColor.nightText.color.opacity(0.9))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.1), in: Capsule())

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(DeskColor.nightMuted.color)
        }
    }

    private var pnl: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text((figures.unrealisedPnL.isNegative ? "" : "+") + figures.unrealisedPnL.display() + " AUSD")
                .font(.system(size: 32, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(tint.color)
                .contentTransition(.numericText())

            // The denominator is named because there is no standard one: Hyperliquid
            // divides by equity, Binance by entry margin, OKX by position margin. An
            // unlabelled percentage is three different numbers.
            Text(HomeScreen.percent(figures.returnOnMarginMicros) + " on margin")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(DeskColor.nightMuted.color)
        }
        .opacity(isStale ? 0.55 : 1)
        .animation(.snappy(duration: 0.25), value: figures.unrealisedPnL.raw)
    }

    /// Room left, drawn rather than stated.
    ///
    /// A percentage alone does not convey how close is close. A bar that empties does,
    /// and it is the one element on the card that should be alarming when it is nearly
    /// gone. Full at ten percent of room, because beyond that the difference stops
    /// mattering.
    private var liquidationBar: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Room to liquidation")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
                Spacer()
                Text(figures.liquidationDistanceMicros.map {
                    $0 == 0 ? "At liquidation" : HomeScreen.percent($0, signed: false)
                } ?? Unavailable.text)
                    .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(liquidationTint.color)
            }

            GeometryReader { proxy in
                let fraction = min(1, Double(figures.liquidationDistanceMicros ?? 0) / 100_000)
                ZStack(alignment: .leading) {
                    Capsule().fill(DeskColor.nightLine.color)
                    Capsule()
                        .fill(liquidationTint.color)
                        .frame(width: max(fraction > 0 ? 6 : 0, proxy.size.width * fraction))
                }
            }
            .frame(height: 5)
            .animation(.snappy(duration: 0.3), value: figures.liquidationDistanceMicros)
        }
        .opacity(isStale ? 0.55 : 1)
    }

    /// Entry, size and the liquidation price. None of these dim — they are still true
    /// while the network is down.
    ///
    /// Each figure is rendered at its own market's decimals rather than at a default.
    /// `display` takes them without one on purpose: price and size scales differ per
    /// market, and a shared default would round one of them wrongly.
    private var facts: some View {
        HStack(spacing: 0) {
            fact("Size", figures.size.display(fractionDigits: figures.size.decimals) + " " + symbol)
            Spacer(minLength: 10)
            fact("Entry", figures.entry.display(fractionDigits: figures.entry.decimals))
            Spacer(minLength: 10)
            fact("Liquidation",
                 figures.liquidationPrice?.display(fractionDigits: figures.entry.decimals)
                    ?? Unavailable.text)
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(DeskColor.nightMuted.color)
            Text(value)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(DeskColor.nightText.color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}
