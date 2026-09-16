import DeskUI
import SwiftUI

/// A horizontal line drawn across the price plot at a price the position depends on:
/// where the user got in, and where the venue takes them out.
///
/// The price arrives already formatted. The chart knows how to place a number on a
/// canvas and nothing about how many digits a market shows, and a chart that decides
/// that for itself is a chart that disagrees with the rows underneath it.
struct PriceGuide: Identifiable, Hashable {
    let label: String
    /// Raw, at the same price decimals as the candles beside it.
    let raw: Int64
    let text: String
    let tint: Color

    var id: String { label }
}

/// OHLC candles from the venue's own candle endpoint, with optional guides for the
/// prices a held position turns on.
///
/// Shared by the market screen and the position screen, which is the point: the chart a
/// user reads before opening a position and the one they read while holding it should
/// not be two different drawings of the same market.
struct CandlestickChart: View {
    let candles: [MarketModel.Candle]
    let priceDecimals: Int
    var guides: [PriceGuide] = []

    var body: some View {
        Canvas { context, size in
            let samples = Array(candles.suffix(25))
            guard samples.count > 1,
                  let lowRaw = samples.map(\.l).min(),
                  let highRaw = samples.map(\.h).max() else { return }
            let scale = pow(10.0, Double(priceDecimals))
            let candleLow = Double(lowRaw) / scale, candleHigh = Double(highRaw) / scale
            let candleSpread = max(candleHigh - candleLow, candleHigh * 0.0001)

            // A guide only widens the axis while it is near enough to be worth seeing.
            // A liquidation price a long way off would otherwise squash every candle
            // into a flat line to make room for one dashed rule.
            //
            // Eight tenths of the candle range rather than one and a half. At the wider
            // reach a liquidation sitting five dollars under a six dollar range still
            // pulled the floor down to meet it, and the price action — the reason the
            // chart is there — was compressed into the top half with an empty band
            // beneath it. Past this distance the guide clamps to the edge and keeps its
            // arrow, which says "further than this" without costing the candles room.
            let reach = candleSpread * 0.8
            var low = candleLow, high = candleHigh
            for guide in guides {
                let value = Double(guide.raw) / scale
                guard value >= candleLow - reach, value <= candleHigh + reach else { continue }
                low = min(low, value)
                high = max(high, value)
            }
            let spread = max(high - low, high * 0.0001)

            let plotWidth = size.width - 62
            let priceHeight = size.height * 0.76
            let volumeTop = size.height * 0.80
            let xStep = plotWidth / CGFloat(samples.count)
            func y(_ value: Double) -> CGFloat {
                priceHeight * CGFloat(1 - (value - low) / spread) * 0.90 + 7
            }
            func y(_ raw: UInt64) -> CGFloat { y(Double(raw) / scale) }

            // Placed before the axis is drawn so a grid label can stand aside for a
            // guide sitting on top of it. Two numbers in the same six points of gutter
            // are unreadable, and the guide is the one the user came for.
            let guidePositions = guides.map { guide -> (PriceGuide, CGFloat, Bool) in
                let value = Double(guide.raw) / scale
                let unclamped = y(value)
                let clamped = min(max(unclamped, 7), priceHeight)
                return (guide, clamped, abs(unclamped - clamped) > 0.5)
            }

            for row in 0...3 {
                // Placed by the same mapping the candles and guides use, rather than by
                // an even division of the plot. `y` compresses the data to 0.90 of the
                // height and offsets it by seven points; the grid did neither, so every
                // label sat up to twelve points away from its own price. That is how
                // 92.74 came to be drawn twice on one chart — once as a liquidation
                // guide at its true height, and once as an axis label well below it,
                // far enough apart that the nine-point guard below could not tell they
                // were the same number.
                let price = high - spread * Double(row) / 3
                let rowY = y(price)
                var grid = Path()
                grid.move(to: CGPoint(x: 0, y: rowY))
                grid.addLine(to: CGPoint(x: plotWidth, y: rowY))
                context.stroke(grid, with: .color(.white.opacity(0.07)),
                               style: StrokeStyle(lineWidth: 0.6, dash: [3, 5]))
                guard !guidePositions.contains(where: { abs($0.1 - rowY) < 9 }) else { continue }
                context.draw(
                    Text(Self.axis(price)).font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.gray),
                    at: CGPoint(x: plotWidth + 31, y: rowY))
            }

            let maxVolume = samples.compactMap { Double($0.v) }.max() ?? 1
            for (index, candle) in samples.enumerated() {
                let rising = candle.c >= candle.o
                let color = rising ? DeskColor.rise.color : DeskColor.fall.color
                let x = (CGFloat(index) + 0.5) * xStep
                let top = min(y(candle.o), y(candle.c)), bottom = max(y(candle.o), y(candle.c))
                var wick = Path()
                wick.move(to: CGPoint(x: x, y: y(candle.h)))
                wick.addLine(to: CGPoint(x: x, y: y(candle.l)))
                context.stroke(wick, with: .color(color), lineWidth: 0.7)
                // Narrow bodies with air between them. A fat candle reads as a bar chart
                // and hides the wicks, which are the part that says how far price
                // actually travelled inside the period.
                let halfBody = max(1, xStep * 0.16)
                let body = CGRect(x: x - halfBody, y: top,
                                  width: halfBody * 2, height: max(1, bottom - top))
                context.fill(Path(roundedRect: body, cornerRadius: 1), with: .color(color))
                let volume = (Double(candle.v) ?? 0) / maxVolume
                let volumeRect = CGRect(x: x - xStep * 0.17,
                                        y: size.height - 2 - CGFloat(volume) * (size.height - volumeTop),
                                        width: xStep * 0.34,
                                        height: CGFloat(volume) * (size.height - volumeTop))
                context.fill(Path(roundedRect: volumeRect, cornerRadius: 2),
                             with: .color(.white.opacity(0.15)))
            }

            if let last = samples.last {
                let currentY = y(last.c)
                var line = Path()
                line.move(to: CGPoint(x: 0, y: currentY))
                line.addLine(to: CGPoint(x: plotWidth, y: currentY))
                context.stroke(
                    line,
                    with: .color((last.c >= last.o ? DeskColor.rise : DeskColor.fall).color.opacity(0.55)),
                    lineWidth: 0.8)
            }

            for (guide, guideY, isOffPlot) in guidePositions {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: guideY))
                line.addLine(to: CGPoint(x: plotWidth, y: guideY))
                context.stroke(line, with: .color(guide.tint.opacity(isOffPlot ? 0.4 : 0.85)),
                               style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

                // An arrow when the price is outside the window, because a line pinned
                // to the edge otherwise reads as a price that is right there.
                let caption = isOffPlot
                    ? guide.label + (guideY <= 7 ? " ↑" : " ↓")
                    : guide.label
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

    private static func axis(_ value: Double) -> String {
        value >= 1_000 ? String(format: "%.2fK", value / 1_000) : String(format: "%.2f", value)
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
