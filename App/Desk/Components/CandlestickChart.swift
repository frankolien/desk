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
    /// The candle under a held finger; nil until the chart is pressed.
    @State private var scrubbed: Int?

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM HH:mm"
        return formatter
    }()

    var body: some View {
        GeometryReader { proxy in
            canvas
                .gesture(
                    LongPressGesture(minimumDuration: 0.18)
                        .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                        .onChanged { value in
                            guard case .second(true, let drag) = value, let drag else { return }
                            let samples = Array(candles.suffix(25))
                            let layout = CandleLayout(count: samples.count, width: proxy.size.width - 62)
                            let index = min(max(Int(drag.location.x / layout.step) - layout.leading, 0), samples.count - 1)
                            if index != scrubbed {
                                scrubbed = index
                                UISelectionFeedbackGenerator().selectionChanged()
                            }
                        }
                        .onEnded { _ in scrubbed = nil }
                )
        }
    }

    private var canvas: some View {
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
                let tint = (last.isRising ? DeskColor.rise : DeskColor.fall).color
                var line = Path()
                line.move(to: CGPoint(x: 0, y: currentY))
                line.addLine(to: CGPoint(x: plotWidth, y: currentY))
                context.stroke(line, with: .color(tint.opacity(0.55)), style: StrokeStyle(lineWidth: 0.8, dash: [2, 3]))
                let resolved = context.resolve(
                    Text(PriceAxis.label(last.close)).font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.black))
                let textSize = resolved.measure(in: CGSize(width: 80, height: 20))
                let tag = CGRect(x: plotWidth + 4, y: currentY - textSize.height / 2 - 3,
                                 width: min(size.width - plotWidth - 6, textSize.width + 10), height: textSize.height + 6)
                context.fill(Path(roundedRect: tag, cornerRadius: 4), with: .color(tint))
                context.draw(resolved, at: CGPoint(x: tag.midX, y: tag.midY), anchor: .center)
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

            if let scrubbed, samples.indices.contains(scrubbed) {
                let candle = samples[scrubbed]
                let x = layout.x(scrubbed)
                let y = axis.y(candle.close)
                var cross = Path()
                cross.move(to: CGPoint(x: x, y: 0))
                cross.addLine(to: CGPoint(x: x, y: size.height))
                cross.move(to: CGPoint(x: 0, y: y))
                cross.addLine(to: CGPoint(x: plotWidth, y: y))
                context.stroke(cross, with: .color(.white.opacity(0.7)), style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))

                let price = context.resolve(
                    Text(PriceAxis.label(candle.close)).font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white))
                let priceSize = price.measure(in: CGSize(width: 80, height: 20))
                let priceTag = CGRect(x: plotWidth + 4, y: y - priceSize.height / 2 - 3,
                                      width: min(size.width - plotWidth - 6, priceSize.width + 10), height: priceSize.height + 6)
                context.fill(Path(roundedRect: priceTag, cornerRadius: 4), with: .color(.white.opacity(0.28)))
                context.draw(price, at: CGPoint(x: priceTag.midX, y: priceTag.midY), anchor: .center)

                let ohlc = context.resolve(
                    Text("O \(PriceAxis.label(candle.open))  H \(PriceAxis.label(candle.high))  L \(PriceAxis.label(candle.low))  C \(PriceAxis.label(candle.close))")
                        .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85)))
                context.draw(ohlc, at: CGPoint(x: 2, y: 2), anchor: .topLeading)

                if let time = candle.time {
                    let when = context.resolve(
                        Text(Self.stamp.string(from: Date(timeIntervalSince1970: time)))
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.white))
                    let whenSize = when.measure(in: CGSize(width: 140, height: 20))
                    let width = whenSize.width + 12
                    let tag = CGRect(x: min(max(x - width / 2, 0), plotWidth - width), y: priceHeight - whenSize.height - 8,
                                     width: width, height: whenSize.height + 6)
                    context.fill(Path(roundedRect: tag, cornerRadius: 4), with: .color(.white.opacity(0.28)))
                    context.draw(when, at: CGPoint(x: tag.midX, y: tag.midY), anchor: .center)
                }
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
            volume: Double(v), time: t > 100_000_000_000 ? Double(t) / 1_000 : Double(t))
    }
}

/// The corner control that opens the full-screen chart.
struct ChartExpandButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(DeskColor.nightMuted.color)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .deskGlass(interactive: true, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(.trailing, 66)
        .accessibilityLabel("Expand chart")
    }
}

/// The interval rail under a chart. One control, so the market screen and the position
/// screen cannot drift into offering different ranges of the same series.
struct CandleIntervalRail: View {
    let market: MarketModel

    static let intervals = [(60, "1m"), (180, "3m"), (300, "5m"), (900, "15m"),
                            (1_800, "30m"), (3_600, "1H"), (14_400, "4H"), (86_400, "1D")]

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
