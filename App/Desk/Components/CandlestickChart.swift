import DeskUI
import SwiftUI

/// A horizontal line across the price plot: where the user got in, and where the venue
/// takes them out. The price arrives already formatted, so the chart never decides how
/// many digits a market shows.
struct PriceGuide: Identifiable, Hashable {
    let label: String
    let value: Double
    let text: String
    let tint: Color

    var id: String { label }
}

/// Every candlestick Desk draws, on every screen.
///
/// The perpetual markets and the spot tokens used to have separate charts with separate
/// axis arithmetic, and the spot one had no price labels at all. They take the same
/// candles now, so the chart a user reads before opening a position, while holding it,
/// and while looking at a token they do not own is one drawing with one scale.
struct CandlestickChart: View {
    let candles: [ChartCandle]
    var guides: [PriceGuide] = []

    var body: some View {
        Canvas { context, size in
            let samples = Array(candles.suffix(25))
            guard samples.count > 1,
                  let low = samples.map(\.low).min(),
                  let high = samples.map(\.high).max() else { return }

            let volumes = samples.compactMap(\.volume)
            let hasVolume = volumes.contains { $0 > 0 }
            let plotWidth = size.width - 62
            // Without a volume band the price keeps the whole frame, which is what the
            // spot feed needs: it publishes no volume per candle.
            let priceHeight = hasVolume ? size.height * 0.76 : size.height - 6
            let volumeTop = size.height * 0.80
            let layout = CandleLayout(count: samples.count, width: plotWidth)

            let guideValues = guides.map(\.value)
            let axis = PriceAxis(
                candleLow: low, candleHigh: high, guides: guideValues,
                height: priceHeight, topInset: 7, bottomInset: 7)
            let placements = Array(zip(guides, guideValues.map(axis.place)))

            for tick in axis.ticks(clearOf: guideValues, within: 11) {
                var grid = Path()
                grid.move(to: CGPoint(x: 0, y: tick.y))
                grid.addLine(to: CGPoint(x: plotWidth, y: tick.y))
                context.stroke(grid, with: .color(.white.opacity(0.07)),
                               style: StrokeStyle(lineWidth: 0.6, dash: [3, 5]))
                context.draw(
                    Text(tick.label).font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.gray),
                    at: CGPoint(x: plotWidth + 31, y: tick.y))
            }

            let maxVolume = volumes.max() ?? 1
            for (index, candle) in samples.enumerated() {
                let color = candle.isRising ? DeskColor.rise.color : DeskColor.fall.color
                let x = layout.x(index)
                let top = min(axis.y(candle.open), axis.y(candle.close))
                let bottom = max(axis.y(candle.open), axis.y(candle.close))
                var wick = Path()
                wick.move(to: CGPoint(x: x, y: axis.y(candle.high)))
                wick.addLine(to: CGPoint(x: x, y: axis.y(candle.low)))
                context.stroke(wick, with: .color(color), lineWidth: 0.7)
                // Narrow bodies: a fat candle hides the wick, which is the telling part.
                let halfBody = max(1, layout.step * 0.16)
                let body = CGRect(x: x - halfBody, y: top,
                                  width: halfBody * 2, height: max(1, bottom - top))
                context.fill(Path(roundedRect: body, cornerRadius: 1), with: .color(color))

                guard hasVolume, let volume = candle.volume else { continue }
                let share = volume / maxVolume
                let volumeRect = CGRect(x: x - layout.step * 0.17,
                                        y: size.height - 2 - CGFloat(share) * (size.height - volumeTop),
                                        width: layout.step * 0.34,
                                        height: CGFloat(share) * (size.height - volumeTop))
                context.fill(Path(roundedRect: volumeRect, cornerRadius: 2),
                             with: .color(.white.opacity(0.15)))
            }

            if let last = samples.last {
                let currentY = axis.y(last.close)
                var line = Path()
                line.move(to: CGPoint(x: 0, y: currentY))
                line.addLine(to: CGPoint(x: plotWidth, y: currentY))
                context.stroke(
                    line,
                    with: .color((last.isRising ? DeskColor.rise : DeskColor.fall).color.opacity(0.55)),
                    lineWidth: 0.8)
            }

            for (guide, placement) in placements {
                let guideY = placement.y
                var line = Path()
                line.move(to: CGPoint(x: 0, y: guideY))
                line.addLine(to: CGPoint(x: plotWidth, y: guideY))
                context.stroke(
                    line, with: .color(guide.tint.opacity(placement.isOffScale ? 0.4 : 0.85)),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

                // An arrow when the price is off-scale: a line pinned to the edge
                // otherwise reads as a price that is right there.
                let caption = switch placement.offScale {
                case .above: guide.label + " ↑"
                case .below: guide.label + " ↓"
                case nil: guide.label
                }
                let resolved = context.resolve(
                    Text(caption).font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(guide.tint))
                let textSize = resolved.measure(in: CGSize(width: 180, height: 40))
                let pill = CGRect(x: 2, y: guideY - textSize.height / 2 - 3,
                                  width: textSize.width + 12, height: textSize.height + 6)
                context.fill(Path(roundedRect: pill, cornerRadius: pill.height / 2),
                             with: .color(.black.opacity(0.78)))
                context.stroke(Path(roundedRect: pill, cornerRadius: pill.height / 2),
                               with: .color(guide.tint.opacity(0.5)), lineWidth: 0.8)
                context.draw(resolved, at: CGPoint(x: pill.midX, y: pill.midY), anchor: .center)

                context.draw(
                    Text(guide.text).font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(guide.tint),
                    at: CGPoint(x: plotWidth + 31, y: guideY), anchor: .center)
            }
        }
    }
}

extension MarketModel.Candle {
    /// The venue's integers, scaled for drawing only.
    func chartCandle(scale: Double) -> ChartCandle {
        ChartCandle(
            open: Double(o) / scale, high: Double(h) / scale,
            low: Double(l) / scale, close: Double(c) / scale,
            volume: Double(v))
    }
}

/// The interval rail under a chart. One control, so the market screen and the position
/// screen cannot drift into offering different ranges of the same series.
struct CandleIntervalRail: View {
    let market: MarketModel

    private static let intervals = [(60, "1m"), (180, "3m"), (300, "5m"),
                                    (900, "15m"), (1_800, "30m"), (3_600, "1H")]

    var body: some View {
        HStack {
            ForEach(Self.intervals, id: \.0) { seconds, label in
                let selected = market.candleIntervalSeconds == seconds
                Button { market.selectCandleInterval(seconds) } label: {
                    Text(label)
                        .foregroundStyle(selected ? DeskColor.nightText.color : DeskColor.nightMuted.color)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .modifier(SelectedIntervalGlass(selected: selected))
            }
        }
        .font(.system(size: 13, weight: .bold, design: .rounded))
    }
}

private struct SelectedIntervalGlass: ViewModifier {
    let selected: Bool

    func body(content: Content) -> some View {
        if selected { content.deskGlass(in: Capsule()) } else { content }
    }
}
