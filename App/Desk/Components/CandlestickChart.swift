import DeskUI
import SwiftUI

struct PriceGuide: Identifiable, Hashable {
    let label: String
    let value: Double
    let text: String
    let tint: Color

    var id: String { label }
}

/// A moment on the chart, such as the buy that opened a position: a dot on the first candle
/// at or after that time, with the candle's close as its height.
struct ChartMark: Identifiable, Hashable {
    let time: Double
    let label: String
    let tint: Color

    var id: Double { time }
}

struct CandlestickChart: View {
    let candles: [ChartCandle]
    var guides: [PriceGuide] = []
    var marks: [ChartMark] = []
    /// Told when the crosshair lands and lifts, so the screen can clear the status bar while reading.
    var onScrub: ((Bool) -> Void)?
    /// Where the finger is: the crosshair follows it exactly, the candle it reads is the nearest.
    @State private var scrub: CGPoint?
    /// The candle a double tap pinned, by time; its card stays until a tap lifts it.
    @State private var pinnedTime: Double?
    /// How many candles the window shows: a pinch widens or narrows it between 8 and whatever is loaded.
    @State private var visible = CandlestickChart.defaultVisible
    @State private var pinchStart: Int?
    static let defaultVisible = 25
    private static let fewest = 8

    /// The window drawn: the last `visible` candles and the scales they sit on.
    private struct Scene {
        let samples: [ChartCandle]
        let layout: CandleLayout
        let axis: PriceAxis
        let plotWidth: CGFloat
        let priceHeight: CGFloat
        let hasVolume: Bool

        func nearest(_ x: CGFloat) -> Int {
            min(max(Int(x / layout.step) - layout.leading, 0), samples.count - 1)
        }

        func pin(_ time: Double?) -> CandlePin? {
            guard let time, let index = samples.firstIndex(where: { $0.time == time }) else { return nil }
            let candle = samples[index]
            return CandlePin(candle: candle, x: layout.x(index),
                             anchorY: (axis.y(candle.open) + axis.y(candle.close)) / 2,
                             plot: CGRect(x: 0, y: 0, width: plotWidth, height: priceHeight))
        }
    }

    private func scene(_ size: CGSize) -> Scene? {
        let samples = Array(candles.suffix(visible))
        guard samples.count > 1,
              let low = samples.map(\.low).min(),
              let high = samples.map(\.high).max() else { return nil }
        let hasVolume = samples.compactMap(\.volume).contains { $0 > 0 }
        let plotWidth = size.width - 62
        let priceHeight = hasVolume ? size.height * 0.76 : size.height - 6
        let axis = PriceAxis(
            candleLow: low, candleHigh: high, guides: guides.map(\.value),
            height: priceHeight, topInset: 7, bottomInset: 7)
        return Scene(samples: samples, layout: CandleLayout(count: samples.count, width: plotWidth, minimumSlots: min(24, visible)),
                     axis: axis, plotWidth: plotWidth, priceHeight: priceHeight, hasVolume: hasVolume)
    }

    var body: some View {
        GeometryReader { proxy in
            canvas
                .gesture(ScrubPress { location in
                    guard let location, let scene = scene(proxy.size) else { scrub = nil; return }
                    let before = scrub.map { scene.nearest($0.x) }
                    scrub = location
                    if scene.nearest(location.x) != before {
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
                })
                .gesture(ChartTap { location in
                    guard let scene = scene(proxy.size) else { return }
                    pin(at: location, in: scene)
                })
                .gesture(ChartPinch { scale in
                    guard let scale else { pinchStart = nil; return }
                    let start = pinchStart ?? visible
                    pinchStart = start
                    zoom(to: Int((Double(start) / scale).rounded()))
                })
        }
        .onChange(of: scrub != nil) { _, active in onScrub?(active) }
        #if DEBUG
        .task(id: candles.count) {
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "-zoom-chart"), arguments.indices.contains(index + 1),
               let count = Int(arguments[index + 1]) { zoom(to: count) }
            guard pinnedTime == nil, arguments.contains("-pin-candle") else { return }
            pinnedTime = candles.suffix(visible).dropLast(7).last?.time
        }
        #endif
    }

    /// Fewer than eight candles reads as a bar chart; more than are loaded would draw nothing.
    private func zoom(to count: Int) {
        let widest = max(Self.fewest, candles.count)
        let next = min(max(count, Self.fewest), widest)
        guard next != visible else { return }
        if next == Self.fewest || next == widest { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        visible = next
    }

    /// A double tap on a candle pins it; on the pinned candle, its card, or empty space it lets go.
    private func pin(at location: CGPoint, in scene: Scene) {
        if let pin = scene.pin(pinnedTime), pin.card.contains(location) || abs(pin.x - location.x) < scene.layout.step / 2 {
            pinnedTime = nil
            return
        }
        let index = scene.nearest(location.x)
        guard location.x <= scene.plotWidth, abs(scene.layout.x(index) - location.x) < scene.layout.step,
              let time = scene.samples[index].time else {
            pinnedTime = nil
            return
        }
        pinnedTime = time
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private var canvas: some View {
        Canvas { context, size in
            guard let scene = scene(size) else { return }
            let samples = scene.samples
            let hasVolume = scene.hasVolume
            let plotWidth = scene.plotWidth
            let priceHeight = scene.priceHeight
            let volumeTop = size.height * 0.80
            let layout = scene.layout
            let axis = scene.axis
            let volumes = samples.compactMap(\.volume)

            let guideValues = guides.map(\.value)
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

            for mark in marks {
                // Before the window: pinned to its first candle, so the position still reads as open.
                guard let index = samples.firstIndex(where: { ($0.time ?? 0) >= mark.time })
                        ?? (samples.last.flatMap { ($0.time ?? 0) < mark.time ? nil : 0 }) else { continue }
                let candle = samples[index]
                let center = CGPoint(x: layout.x(index), y: axis.y(candle.close))
                let dot = CGRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16)
                context.fill(Path(ellipseIn: dot), with: .color(mark.tint))
                context.stroke(Path(ellipseIn: dot), with: .color(.black.opacity(0.6)), lineWidth: 1.5)
                context.draw(
                    Text("+").font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundStyle(.black),
                    at: center, anchor: .center)
                let resolved = context.resolve(
                    Text(mark.label).font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(mark.tint))
                let textSize = resolved.measure(in: CGSize(width: 120, height: 20))
                let pill = CGRect(x: min(max(center.x - textSize.width / 2 - 6, 0), plotWidth - textSize.width - 12),
                                  y: max(center.y - 30, 0), width: textSize.width + 12, height: textSize.height + 6)
                context.fill(Path(roundedRect: pill, cornerRadius: pill.height / 2), with: .color(.black.opacity(0.78)))
                context.draw(resolved, at: CGPoint(x: pill.midX, y: pill.midY), anchor: .center)
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

            scene.pin(pinnedTime)?.draw(in: &context)

            if let scrub {
                let candle = samples[scene.nearest(scrub.x)]
                let x = min(max(scrub.x, 0), plotWidth)
                let y = min(max(scrub.y, 0), priceHeight)
                let value = axis.value(atY: y)
                var cross = Path()
                cross.move(to: CGPoint(x: x, y: 0))
                cross.addLine(to: CGPoint(x: x, y: size.height))
                cross.move(to: CGPoint(x: 0, y: y))
                cross.addLine(to: CGPoint(x: plotWidth, y: y))
                context.stroke(cross, with: .color(.white.opacity(0.7)), style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
                var mark = Path()
                mark.move(to: CGPoint(x: x - 7, y: y))
                mark.addLine(to: CGPoint(x: x + 7, y: y))
                mark.move(to: CGPoint(x: x, y: y - 7))
                mark.addLine(to: CGPoint(x: x, y: y + 7))
                context.stroke(mark, with: .color(DeskColor.identity.color), lineWidth: 1.4)

                let price = context.resolve(
                    Text(PriceAxis.label(value)).font(.system(size: 10, weight: .bold, design: .rounded))
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
                        Text(CandlePin.stamp.string(from: Date(timeIntervalSince1970: time)))
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

struct CandleIntervalRail: View {
    let market: MarketModel

    /// Only resolutions Perpl serves: 60, 300, 900, 1,800, 3,600, 7,200, 14,400, 28,800,
    /// 43,200 and 86,400 seconds. It answers 180 with a 400, which read as an empty chart.
    static let intervals = [(60, "1m"), (300, "5m"), (900, "15m"), (1_800, "30m"),
                            (3_600, "1H"), (7_200, "2H"), (14_400, "4H"), (86_400, "1D")]

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

/// Hold, then slide, to read candles. UIKit's long press rather than SwiftUI's: it fails the moment
/// a finger moves before the hold completes, so a flick that starts on the chart still scrolls the
/// page or drags its sheet down. SwiftUI's sequenced long press held every touch on the chart.
struct ScrubPress: UIGestureRecognizerRepresentable {
    var minimumDuration: TimeInterval = 0.18
    let onChange: (CGPoint?) -> Void

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = minimumDuration
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began, .changed: onChange(context.converter.localLocation)
        default: onChange(nil)
        }
    }
}

/// A double tap, through UIKit's own recognizer: it cancels no touches and gives up on the
/// first movement, so a flick still scrolls the page and a hold still scrubs.
struct ChartTap: UIGestureRecognizerRepresentable {
    let onDoubleTap: (CGPoint) -> Void

    func makeUIGestureRecognizer(context: Context) -> UITapGestureRecognizer {
        let recognizer = UITapGestureRecognizer()
        recognizer.numberOfTapsRequired = 2
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesEnded = false
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UITapGestureRecognizer, context: Context) {
        guard recognizer.state == .ended else { return }
        onDoubleTap(context.converter.localLocation)
    }
}

/// A two-finger pinch, through UIKit's own recognizer so one finger still scrolls the page and
/// holds to scrub. Reports the running scale, nil when the fingers lift.
struct ChartPinch: UIGestureRecognizerRepresentable {
    let onChange: (Double?) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPinchGestureRecognizer {
        UIPinchGestureRecognizer()
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPinchGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began, .changed: onChange(Double(recognizer.scale))
        default: onChange(nil)
        }
    }
}

/// One candle's reading, held on the chart: a marker through the candle and a card beside it.
/// The card is measured with UIKit so a tap can be tested against it outside a draw pass.
struct CandlePin {
    static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM HH:mm"
        return formatter
    }()

    private static let font: UIFont = {
        let base = UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        return UIFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: 10)
    }()

    let x: CGFloat
    let plot: CGRect
    let card: CGRect
    private let body: String
    private let delta: String
    private let rising: Bool

    init(candle: ChartCandle, x: CGFloat, anchorY: CGFloat, plot: CGRect) {
        var lines: [String] = []
        if let time = candle.time { lines.append(Self.stamp.string(from: Date(timeIntervalSince1970: time))) }
        lines.append("O \(PriceAxis.label(candle.open))   H \(PriceAxis.label(candle.high))")
        lines.append("L \(PriceAxis.label(candle.low))   C \(PriceAxis.label(candle.close))")
        body = lines.joined(separator: "\n")
        let percent = candle.open > 0 ? (candle.close - candle.open) / candle.open * 100 : 0
        rising = percent >= 0
        delta = String(format: "%@%.2f%%", rising ? "+" : Direction.minus, abs(percent))

        let bodySize = Self.measure(body)
        let deltaSize = Self.measure(delta)
        let size = CGSize(width: max(bodySize.width, deltaSize.width) + 16,
                          height: bodySize.height + deltaSize.height + 16)
        var origin = CGPoint(x: x + 12, y: anchorY - size.height / 2)
        if origin.x + size.width > plot.maxX - 2 { origin.x = x - 12 - size.width }
        origin.x = max(origin.x, 2)
        origin.y = min(max(origin.y, plot.minY + 2), plot.maxY - size.height - 2)
        card = CGRect(origin: origin, size: size)
        self.x = x
        self.plot = plot
    }

    func draw(in context: inout GraphicsContext) {
        var marker = Path()
        marker.move(to: CGPoint(x: x, y: plot.minY))
        marker.addLine(to: CGPoint(x: x, y: plot.maxY))
        context.stroke(marker, with: .color(DeskColor.identity.color.opacity(0.8)), lineWidth: 1)
        context.fill(Path(roundedRect: card, cornerRadius: 8), with: .color(Color(white: 0.12).opacity(0.96)))
        context.stroke(Path(roundedRect: card, cornerRadius: 8), with: .color(DeskColor.identity.color.opacity(0.5)), lineWidth: 0.8)
        let font = Font(Self.font)
        context.draw(Text(body).font(font).foregroundStyle(.white),
                     at: CGPoint(x: card.minX + 8, y: card.minY + 8), anchor: .topLeading)
        context.draw(Text(delta).font(font).foregroundStyle(rising ? DeskColor.rise.color : DeskColor.fall.color),
                     at: CGPoint(x: card.minX + 8, y: card.maxY - 8), anchor: .bottomLeading)
    }

    private static func measure(_ text: String) -> CGSize {
        (text as NSString).boundingRect(
            with: CGSize(width: 240, height: 120), options: [.usesLineFragmentOrigin],
            attributes: [.font: font], context: nil).size
    }

}
