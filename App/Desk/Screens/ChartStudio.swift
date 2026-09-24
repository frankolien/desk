import DeskUI
import SwiftUI
import UIKit

/// Holds every screen but one to portrait. The full-screen chart asks for landscape on
/// the way in and gives it back on the way out; the app delegate reads `mask`.
@MainActor
enum OrientationLock {
    private(set) static var mask: UIInterfaceOrientationMask = .portrait

    static func request(_ orientation: UIInterfaceOrientationMask) {
        mask = orientation
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        var controller = scene.keyWindow?.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        controller?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation))
    }
}

// MARK: - Model

enum ChartStyle: String, CaseIterable, Identifiable {
    case candles, hollow, bars, line, area, heikinAshi
    var id: String { rawValue }

    var title: String {
        switch self {
        case .candles: "Candles"
        case .hollow: "Hollow candles"
        case .bars: "Bars"
        case .line: "Line"
        case .area: "Area"
        case .heikinAshi: "Heikin Ashi"
        }
    }

    var symbol: String {
        switch self {
        case .candles: "chart.bar.fill"
        case .hollow: "chart.bar"
        case .bars: "chart.bar.xaxis"
        case .line: "chart.xyaxis.line"
        case .area: "chart.line.uptrend.xyaxis"
        case .heikinAshi: "waveform.path"
        }
    }
}

enum ChartOverlay: String, CaseIterable, Identifiable {
    case ma7, ma25, ma99, ema12, ema26, bollinger, vwap
    var id: String { rawValue }

    var title: String {
        switch self {
        case .ma7: "MA 7"
        case .ma25: "MA 25"
        case .ma99: "MA 99"
        case .ema12: "EMA 12"
        case .ema26: "EMA 26"
        case .bollinger: "Bollinger 20 · 2"
        case .vwap: "VWAP"
        }
    }

    var tint: Color {
        switch self {
        case .ma7: DeskColor.action.color
        case .ma25: Color(red: 0.91, green: 0.36, blue: 0.66)
        case .ma99: Color(red: 0.55, green: 0.47, blue: 0.98)
        case .ema12: Color(red: 0.30, green: 0.83, blue: 0.94)
        case .ema26: Color(red: 0.98, green: 0.58, blue: 0.24)
        case .bollinger: DeskColor.identity.color
        case .vwap: Color.white.opacity(0.8)
        }
    }
}

enum ChartPane: String, CaseIterable, Identifiable {
    case volume, rsi, macd
    var id: String { rawValue }

    var title: String {
        switch self {
        case .volume: "Volume"
        case .rsi: "RSI 14"
        case .macd: "MACD 12 · 26 · 9"
        }
    }

    var caption: String {
        switch self {
        case .volume: "Vol"
        case .rsi: "RSI 14"
        case .macd: "MACD 12 26 9"
        }
    }
}

enum ChartTool: String, CaseIterable, Identifiable {
    case none, level, trend, erase
    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "Pan and zoom"
        case .level: "Price level"
        case .trend: "Trend line"
        case .erase: "Erase"
        }
    }

    var symbol: String {
        switch self {
        case .none: "hand.draw"
        case .level: "minus"
        case .trend: "line.diagonal"
        case .erase: "eraser"
        }
    }
}

/// A point on the chart in the chart's own units, so it survives new candles, a zoom,
/// and a relaunch.
struct ChartAnchor: Codable, Hashable {
    var time: Double
    var price: Double
}

struct ChartDrawing: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case level, trend }
    var id: UUID
    var kind: Kind
    var a: ChartAnchor
    var b: ChartAnchor?
}

enum ChartDrawingStore {
    static func key(_ symbol: String, network: String) -> String { "desk.chart.drawings.\(network).\(symbol)" }

    static func load(_ key: String) -> [ChartDrawing] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([ChartDrawing].self, from: data)) ?? []
    }

    static func save(_ drawings: [ChartDrawing], key: String) {
        if drawings.isEmpty { UserDefaults.standard.removeObject(forKey: key); return }
        UserDefaults.standard.set(try? JSONEncoder().encode(drawings), forKey: key)
    }
}

/// Everything the painter needs, gathered once per frame.
struct StudioFrame {
    var candles: [ChartCandle]
    var interval: Double
    var window: ChartWindow
    var style: ChartStyle
    var overlays: Set<ChartOverlay>
    var panes: [ChartPane]
    var logScale: Bool
    var guides: [PriceGuide]
    var drawings: [ChartDrawing]
    var pendingTrend: ChartAnchor?
    var ruler: (from: ChartAnchor, to: ChartAnchor)?
    var crosshair: CGPoint?
    var magnet: Bool
    var studies: StudySet
    var alerts: [Double] = []
    var leverage: Int = 1
}

/// Study series over the full history, computed when the candles change rather than on
/// every finger move.
struct StudySet {
    var ma7: [Double?] = []
    var ma25: [Double?] = []
    var ma99: [Double?] = []
    var ema12: [Double?] = []
    var ema26: [Double?] = []
    var bands = ChartStudies.Bands(upper: [], middle: [], lower: [])
    var vwap: [Double?] = []
    var rsi: [Double?] = []
    var macd = ChartStudies.MACD(line: [], signal: [], histogram: [])
    var heikin: [ChartCandle] = []

    init() {}

    init(candles: [ChartCandle]) {
        let closes = candles.map(\.close)
        ma7 = ChartStudies.sma(closes, period: 7)
        ma25 = ChartStudies.sma(closes, period: 25)
        ma99 = ChartStudies.sma(closes, period: 99)
        ema12 = ChartStudies.ema(closes, period: 12)
        ema26 = ChartStudies.ema(closes, period: 26)
        bands = ChartStudies.bollinger(closes)
        vwap = ChartStudies.vwap(candles)
        rsi = ChartStudies.rsi(closes)
        macd = ChartStudies.macd(closes)
        heikin = ChartStudies.heikinAshi(candles)
    }

    func series(_ overlay: ChartOverlay) -> [[Double?]] {
        switch overlay {
        case .ma7: [ma7]
        case .ma25: [ma25]
        case .ma99: [ma99]
        case .ema12: [ema12]
        case .ema26: [ema26]
        case .bollinger: [bands.upper, bands.middle, bands.lower]
        case .vwap: [vwap]
        }
    }
}

// MARK: - Geometry

/// Where everything sits for one frame size. Shared by the painter and the gestures, so
/// a finger and a pixel agree about which candle they mean.
struct StudioGeometry {
    static let axisWidth: CGFloat = 60
    static let timeAxisHeight: CGFloat = 20

    let size: CGSize
    let plot: CGRect
    let panes: [(pane: ChartPane, rect: CGRect)]
    let slotWidth: CGFloat
    let window: ChartWindow
    let scale: ChartScale

    init(size: CGSize, frame: StudioFrame) {
        self.size = size
        window = frame.window
        let plotWidth = max(size.width - Self.axisWidth, 1)
        let chartHeight = max(size.height - Self.timeAxisHeight, 1)
        let paneShare = frame.panes.isEmpty ? 0 : min(0.22, 0.58 / Double(frame.panes.count))
        let paneHeight = max(chartHeight * CGFloat(paneShare), frame.panes.isEmpty ? 0 : 40)
        let priceHeight = chartHeight - paneHeight * CGFloat(frame.panes.count)
        plot = CGRect(x: 0, y: 0, width: plotWidth, height: priceHeight)
        var y = priceHeight
        var rects: [(ChartPane, CGRect)] = []
        for pane in frame.panes {
            rects.append((pane, CGRect(x: 0, y: y, width: plotWidth, height: paneHeight)))
            y += paneHeight
        }
        panes = rects
        slotWidth = plotWidth / CGFloat(max(frame.window.visible, 1))

        let visible = frame.window.range
        let drawn = frame.style == .heikinAshi ? frame.studies.heikin : frame.candles
        var low = Double.greatestFiniteMagnitude
        var high = -Double.greatestFiniteMagnitude
        for index in visible where drawn.indices.contains(index) {
            low = min(low, drawn[index].low)
            high = max(high, drawn[index].high)
        }
        for overlay in frame.overlays {
            for series in frame.studies.series(overlay) {
                for index in visible where series.indices.contains(index) {
                    if let value = series[index] { low = min(low, value); high = max(high, value) }
                }
            }
        }
        if low > high { low = 0; high = 1 }
        scale = ChartScale(low: low, high: high, logarithmic: frame.logScale, top: plot.minY + 10, height: max(plot.height - 20, 1))
    }

    func x(slot: Int) -> CGFloat { (CGFloat(slot) + 0.5) * slotWidth }
    func x(index: Int) -> CGFloat { x(slot: window.slot(of: index)) }
    func x(fractionalIndex: Double) -> CGFloat { (CGFloat(fractionalIndex - Double(window.end - window.visible)) + 0.5) * slotWidth }
    func slot(atX x: CGFloat) -> Int { Int((x / slotWidth).rounded(.down)) }
    func fractionalIndex(atX x: CGFloat) -> Double { Double(x / slotWidth) - 0.5 + Double(window.end - window.visible) }
}

// MARK: - Painter

struct StudioPainter {
    let frame: StudioFrame
    let geometry: StudioGeometry

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return formatter
    }()
    private static let full: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM HH:mm"
        return formatter
    }()

    private var candles: [ChartCandle] { frame.style == .heikinAshi ? frame.studies.heikin : frame.candles }
    private var firstTime: Double? { frame.candles.first?.time }

    func fractionalIndex(of time: Double) -> Double? {
        guard let firstTime, frame.interval > 0 else { return nil }
        return (time - firstTime) / frame.interval
    }

    func time(atFractionalIndex index: Double) -> Double? {
        guard let firstTime else { return nil }
        return firstTime + index * frame.interval
    }

    func point(_ anchor: ChartAnchor) -> CGPoint? {
        guard let index = fractionalIndex(of: anchor.time) else { return nil }
        return CGPoint(x: geometry.x(fractionalIndex: index), y: geometry.scale.y(anchor.price))
    }

    func draw(in context: inout GraphicsContext) {
        let plot = geometry.plot
        let scale = geometry.scale
        let range = frame.window.range

        drawGrid(in: &context)
        drawTimeAxis(in: &context)

        // A clip on a graphics context cannot be lifted, so the plot draws into a copy.
        var clipped = context
        clipped.clip(to: Path(plot))
        drawOverlayFills(in: &clipped, range: range)
        drawPrice(in: &clipped, range: range)
        drawOverlayLines(in: &clipped, range: range)
        drawDrawings(in: &clipped)
        drawRuler(in: &clipped)

        for (pane, rect) in geometry.panes {
            var paneContext = context
            paneContext.clip(to: Path(CGRect(x: 0, y: rect.minY, width: geometry.size.width, height: rect.height)))
            drawPane(pane, in: rect, context: &paneContext, range: range)
        }

        drawGuides(in: &context)
        for drawing in frame.drawings where drawing.kind == .level {
            let y = scale.y(drawing.a.price)
            guard y > plot.minY, y < plot.maxY else { continue }
            axisTag(PriceAxis.label(drawing.a.price), y: y, fill: DeskColor.action.color, text: .black, in: &context)
        }
        drawLastPrice(in: &context)
        drawCrosshair(in: &context)
    }

    private func drawGrid(in context: inout GraphicsContext) {
        let plot = geometry.plot
        for tick in geometry.scale.ticks(count: 6) where tick.y > plot.minY + 6 && tick.y < plot.maxY - 6 {
            var line = Path()
            line.move(to: CGPoint(x: 0, y: tick.y))
            line.addLine(to: CGPoint(x: plot.maxX, y: tick.y))
            context.stroke(line, with: .color(.white.opacity(0.06)), lineWidth: 0.6)
            context.draw(
                Text(tick.label).font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(DeskColor.nightMuted.color),
                at: CGPoint(x: plot.maxX + 6, y: tick.y), anchor: .leading)
        }
        var axis = Path()
        axis.move(to: CGPoint(x: plot.maxX, y: 0))
        axis.addLine(to: CGPoint(x: plot.maxX, y: geometry.size.height - StudioGeometry.timeAxisHeight))
        context.stroke(axis, with: .color(.white.opacity(0.08)), lineWidth: 0.6)
    }

    private func drawTimeAxis(in context: inout GraphicsContext) {
        let top = geometry.size.height - StudioGeometry.timeAxisHeight
        var line = Path()
        line.move(to: CGPoint(x: 0, y: top))
        line.addLine(to: CGPoint(x: geometry.plot.maxX, y: top))
        context.stroke(line, with: .color(.white.opacity(0.08)), lineWidth: 0.6)

        let every = max(1, Int((80 / geometry.slotWidth).rounded(.up)))
        var labels: [(x: CGFloat, text: String, strong: Bool)] = []
        var previousDay: Int?
        for index in frame.window.range where frame.candles.indices.contains(index) {
            guard let time = frame.candles[index].time else { continue }
            let day = Int((time / 86_400).rounded(.down))
            let dayChanged = previousDay != nil && previousDay != day && frame.interval < 86_400
            previousDay = day
            guard dayChanged else { continue }
            labels.append((geometry.x(index: index), Self.day.string(from: Date(timeIntervalSince1970: time)), true))
        }
        for index in frame.window.range where frame.candles.indices.contains(index) && index % every == 0 {
            guard let time = frame.candles[index].time else { continue }
            let x = geometry.x(index: index)
            guard x > 22, !labels.contains(where: { abs($0.x - x) < 44 }) else { continue }
            let text = frame.interval >= 86_400 ? Self.day.string(from: Date(timeIntervalSince1970: time))
                                                : Self.clock.string(from: Date(timeIntervalSince1970: time))
            labels.append((x, text, false))
        }
        for label in labels {
            var tick = Path()
            tick.move(to: CGPoint(x: label.x, y: top))
            tick.addLine(to: CGPoint(x: label.x, y: top + 3))
            context.stroke(tick, with: .color(.white.opacity(0.25)), lineWidth: 0.6)
            context.draw(
                Text(label.text).font(.system(size: 10, weight: label.strong ? .bold : .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(label.strong ? DeskColor.nightText.color : DeskColor.nightMuted.color),
                at: CGPoint(x: label.x, y: top + 11), anchor: .center)
        }
    }

    private func drawPrice(in context: inout GraphicsContext, range: Range<Int>) {
        let scale = geometry.scale
        let series = candles
        let bodyHalf = max(1, geometry.slotWidth * 0.4)

        switch frame.style {
        case .line, .area:
            var path = Path()
            var started = false
            for index in range where series.indices.contains(index) {
                let point = CGPoint(x: geometry.x(index: index), y: scale.y(series[index].close))
                if started { path.addLine(to: point) } else { path.move(to: point); started = true }
            }
            let tint = (series.last?.isRising ?? true) ? DeskColor.rise.color : DeskColor.fall.color
            if frame.style == .area, let first = range.first, let last = range.last, series.indices.contains(first), series.indices.contains(last) {
                var fill = path
                fill.addLine(to: CGPoint(x: geometry.x(index: min(last, series.count - 1)), y: geometry.plot.maxY))
                fill.addLine(to: CGPoint(x: geometry.x(index: first), y: geometry.plot.maxY))
                fill.closeSubpath()
                context.fill(fill, with: .linearGradient(
                    Gradient(colors: [tint.opacity(0.32), tint.opacity(0.0)]),
                    startPoint: CGPoint(x: 0, y: geometry.plot.minY), endPoint: CGPoint(x: 0, y: geometry.plot.maxY)))
            }
            context.stroke(path, with: .color(tint), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))

        case .candles, .hollow, .heikinAshi, .bars:
            // Edges on device pixels, or a body's two sides blur into different widths
            // as the chart pans. A fixed gap keeps neighbours apart at every zoom.
            let pixel = 1 / max(UITraitCollection.current.displayScale, 1)
            let snap: (CGFloat) -> CGFloat = { ($0 / pixel).rounded() * pixel }
            let slot = geometry.slotWidth
            let gap = max(pixel, snap(slot * 0.22))
            let bodyWidth = max(pixel, snap(slot) - gap)
            let wickWidth = max(pixel, snap(min(slot * 0.12, 2)))
            _ = bodyHalf

            for index in range where series.indices.contains(index) {
                let candle = series[index]
                let color = candle.isRising ? DeskColor.rise.color : DeskColor.fall.color
                let x = geometry.x(index: index)
                let centre = snap(x - wickWidth / 2) + wickWidth / 2
                let openY = scale.y(candle.open)
                let closeY = scale.y(candle.close)
                let top = snap(min(openY, closeY))
                let bottom = max(top + pixel, snap(max(openY, closeY)))
                let high = snap(scale.y(candle.high))
                let low = snap(scale.y(candle.low))

                if frame.style == .bars {
                    var bar = Path()
                    bar.move(to: CGPoint(x: centre, y: high))
                    bar.addLine(to: CGPoint(x: centre, y: low))
                    let tick = snap(openY) + wickWidth / 2
                    bar.move(to: CGPoint(x: centre - bodyWidth / 2, y: tick))
                    bar.addLine(to: CGPoint(x: centre, y: tick))
                    let closeTick = snap(closeY) + wickWidth / 2
                    bar.move(to: CGPoint(x: centre, y: closeTick))
                    bar.addLine(to: CGPoint(x: centre + bodyWidth / 2, y: closeTick))
                    context.stroke(bar, with: .color(color), lineWidth: wickWidth)
                    continue
                }

                var wick = Path()
                wick.move(to: CGPoint(x: centre, y: high))
                wick.addLine(to: CGPoint(x: centre, y: low))
                context.stroke(wick, with: .color(color), lineWidth: wickWidth)

                let body = CGRect(x: snap(x - bodyWidth / 2), y: top, width: bodyWidth, height: bottom - top)
                if frame.style == .hollow, candle.isRising, bodyWidth > 3 * pixel {
                    context.fill(Path(body), with: .color(.black))
                    context.stroke(Path(body.insetBy(dx: pixel / 2, dy: pixel / 2)), with: .color(color), lineWidth: pixel)
                } else {
                    context.fill(Path(body), with: .color(color))
                }
            }
        }
    }

    private func drawOverlayFills(in context: inout GraphicsContext, range: Range<Int>) {
        guard frame.overlays.contains(.bollinger) else { return }
        let bands = frame.studies.bands
        var upper = Path()
        var lowerPoints: [CGPoint] = []
        var started = false
        for index in range where bands.upper.indices.contains(index) {
            guard let high = bands.upper[index], let low = bands.lower[index] else { continue }
            let x = geometry.x(index: index)
            let point = CGPoint(x: x, y: geometry.scale.y(high))
            if started { upper.addLine(to: point) } else { upper.move(to: point); started = true }
            lowerPoints.append(CGPoint(x: x, y: geometry.scale.y(low)))
        }
        guard started else { return }
        for point in lowerPoints.reversed() { upper.addLine(to: point) }
        upper.closeSubpath()
        context.fill(upper, with: .color(ChartOverlay.bollinger.tint.opacity(0.07)))
    }

    private func drawOverlayLines(in context: inout GraphicsContext, range: Range<Int>) {
        for overlay in ChartOverlay.allCases where frame.overlays.contains(overlay) {
            for (position, series) in frame.studies.series(overlay).enumerated() {
                var path = Path()
                var started = false
                for index in range where series.indices.contains(index) {
                    guard let value = series[index] else { started = false; continue }
                    let point = CGPoint(x: geometry.x(index: index), y: geometry.scale.y(value))
                    if started { path.addLine(to: point) } else { path.move(to: point); started = true }
                }
                let middleBand = overlay == .bollinger && position == 1
                let style = overlay == .vwap
                    ? StrokeStyle(lineWidth: 1.1, dash: [4, 3])
                    : StrokeStyle(lineWidth: middleBand ? 0.8 : 1.2, lineJoin: .round)
                context.stroke(path, with: .color(overlay.tint.opacity(middleBand ? 0.6 : 0.95)), style: style)
            }
        }
    }

    private func drawPane(_ pane: ChartPane, in rect: CGRect, context: inout GraphicsContext, range: Range<Int>) {
        var top = Path()
        top.move(to: CGPoint(x: 0, y: rect.minY))
        top.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        context.stroke(top, with: .color(.white.opacity(0.08)), lineWidth: 0.6)
        context.draw(
            Text(pane.caption).font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(DeskColor.nightMuted.color),
            at: CGPoint(x: 6, y: rect.minY + 5), anchor: .topLeading)

        let inner = rect.insetBy(dx: 0, dy: 6)
        switch pane {
        case .volume:
            let volumes = range.compactMap { frame.candles.indices.contains($0) ? frame.candles[$0].volume : nil }
            guard let peak = volumes.max(), peak > 0 else { return }
            for index in range where frame.candles.indices.contains(index) {
                guard let volume = frame.candles[index].volume else { continue }
                let height = CGFloat(volume / peak) * inner.height
                let x = geometry.x(index: index)
                let half = max(0.8, geometry.slotWidth * 0.36)
                let color = frame.candles[index].isRising ? DeskColor.rise.color : DeskColor.fall.color
                context.fill(Path(roundedRect: CGRect(x: x - half, y: inner.maxY - height, width: half * 2, height: height), cornerRadius: 1),
                             with: .color(color.opacity(0.55)))
            }
            let hovered = hoveredIndex.flatMap { frame.candles.indices.contains($0) ? frame.candles[$0].volume : nil } ?? volumes.last
            if let hovered {
                context.draw(
                    Text(compact(hovered)).font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(DeskColor.nightMuted.color),
                    at: CGPoint(x: rect.maxX + 6, y: rect.minY + 5), anchor: .topLeading)
            }

        case .rsi:
            let scale = ChartScale(low: 0, high: 100, logarithmic: false, top: inner.minY, height: inner.height, paddingFraction: 0)
            for level in [30.0, 70.0] {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: scale.y(level)))
                line.addLine(to: CGPoint(x: rect.maxX, y: scale.y(level)))
                context.stroke(line, with: .color(.white.opacity(0.14)), style: StrokeStyle(lineWidth: 0.6, dash: [3, 4]))
                context.draw(
                    Text(String(Int(level))).font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color),
                    at: CGPoint(x: rect.maxX + 6, y: scale.y(level)), anchor: .leading)
            }
            var path = Path()
            var started = false
            for index in range where frame.studies.rsi.indices.contains(index) {
                guard let value = frame.studies.rsi[index] else { continue }
                let point = CGPoint(x: geometry.x(index: index), y: scale.y(value))
                if started { path.addLine(to: point) } else { path.move(to: point); started = true }
            }
            context.stroke(path, with: .color(ChartOverlay.ma25.tint), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
            let shown = hoveredIndex.flatMap { frame.studies.rsi.indices.contains($0) ? frame.studies.rsi[$0] : nil } ?? frame.studies.rsi.last ?? nil
            if let shown {
                context.draw(
                    Text(String(format: "%.1f", shown)).font(.system(size: 9, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(ChartOverlay.ma25.tint),
                    at: CGPoint(x: 46, y: rect.minY + 5), anchor: .topLeading)
            }

        case .macd:
            let macd = frame.studies.macd
            var extreme = 0.0
            for index in range {
                if macd.line.indices.contains(index), let value = macd.line[index] { extreme = max(extreme, abs(value)) }
                if macd.signal.indices.contains(index), let value = macd.signal[index] { extreme = max(extreme, abs(value)) }
                if macd.histogram.indices.contains(index), let value = macd.histogram[index] { extreme = max(extreme, abs(value)) }
            }
            guard extreme > 0 else { return }
            let scale = ChartScale(low: -extreme, high: extreme, logarithmic: false, top: inner.minY, height: inner.height, paddingFraction: 0)
            let zero = scale.y(0)
            var axis = Path()
            axis.move(to: CGPoint(x: 0, y: zero))
            axis.addLine(to: CGPoint(x: rect.maxX, y: zero))
            context.stroke(axis, with: .color(.white.opacity(0.14)), lineWidth: 0.6)
            let half = max(0.8, geometry.slotWidth * 0.3)
            for index in range where macd.histogram.indices.contains(index) {
                guard let value = macd.histogram[index] else { continue }
                let y = scale.y(value)
                let previous = index > 0 ? (macd.histogram[index - 1] ?? value) : value
                let strengthening = abs(value) >= abs(previous)
                let color = value >= 0
                    ? DeskColor.rise.color.opacity(strengthening ? 0.9 : 0.45)
                    : DeskColor.fall.color.opacity(strengthening ? 0.9 : 0.45)
                let bar = CGRect(x: geometry.x(index: index) - half, y: min(y, zero), width: half * 2, height: max(1, abs(zero - y)))
                context.fill(Path(bar), with: .color(color))
            }
            for (series, tint) in [(macd.line, ChartOverlay.ema12.tint), (macd.signal, ChartOverlay.ema26.tint)] {
                var path = Path()
                var started = false
                for index in range where series.indices.contains(index) {
                    guard let value = series[index] else { continue }
                    let point = CGPoint(x: geometry.x(index: index), y: scale.y(value))
                    if started { path.addLine(to: point) } else { path.move(to: point); started = true }
                }
                context.stroke(path, with: .color(tint), style: StrokeStyle(lineWidth: 1.1, lineJoin: .round))
            }
        }
    }

    private func drawGuides(in context: inout GraphicsContext) {
        let plot = geometry.plot
        for guide in frame.guides {
            let raw = geometry.scale.y(guide.value)
            let pinnedTop = raw < plot.minY + 4
            let pinnedBottom = raw > plot.maxY - 4
            let y = min(max(raw, plot.minY + 4), plot.maxY - 4)
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.stroke(line, with: .color(guide.tint.opacity(pinnedTop || pinnedBottom ? 0.4 : 0.85)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            let caption = guide.label + (pinnedTop ? " ↑" : pinnedBottom ? " ↓" : "")
            pill(Text(caption), at: CGPoint(x: 6, y: y), tint: guide.tint, in: &context)
            axisTag(guide.text, y: y, fill: .black.opacity(0.78), text: guide.tint, in: &context)
        }
        for price in frame.alerts {
            let y = geometry.scale.y(price)
            guard y > plot.minY, y < plot.maxY else { continue }
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.stroke(line, with: .color(DeskColor.identity.color.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
            pill(Text("Alert"), at: CGPoint(x: 6, y: y), tint: DeskColor.identity.color, in: &context)
            axisTag(PriceAxis.label(price), y: y, fill: DeskColor.identity.color, text: .white, in: &context)
        }
    }

    private func drawLastPrice(in context: inout GraphicsContext) {
        guard let last = frame.candles.last else { return }
        let plot = geometry.plot
        let y = min(max(geometry.scale.y(last.close), plot.minY), plot.maxY)
        let tint = last.isRising ? DeskColor.rise.color : DeskColor.fall.color
        var line = Path()
        line.move(to: CGPoint(x: 0, y: y))
        line.addLine(to: CGPoint(x: plot.maxX, y: y))
        context.stroke(line, with: .color(tint.opacity(0.6)), style: StrokeStyle(lineWidth: 0.8, dash: [2, 3]))
        axisTag(PriceAxis.label(last.close), y: y, fill: tint, text: .black, in: &context)
    }

    private func drawDrawings(in context: inout GraphicsContext) {
        let plot = geometry.plot
        for drawing in frame.drawings {
            switch drawing.kind {
            case .level:
                let y = geometry.scale.y(drawing.a.price)
                guard y > plot.minY - 20, y < plot.maxY + 20 else { continue }
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: plot.maxX, y: y))
                context.stroke(line, with: .color(DeskColor.action.color.opacity(0.9)), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
            case .trend:
                guard let b = drawing.b, let start = point(drawing.a), let end = point(b) else { continue }
                var line = Path()
                line.move(to: start)
                line.addLine(to: end)
                context.stroke(line, with: .color(DeskColor.identity.color), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                for end in [start, end] {
                    context.fill(Path(ellipseIn: CGRect(x: end.x - 3, y: end.y - 3, width: 6, height: 6)), with: .color(DeskColor.identity.color))
                }
            }
        }
        if let pending = frame.pendingTrend, let start = point(pending) {
            context.fill(Path(ellipseIn: CGRect(x: start.x - 4, y: start.y - 4, width: 8, height: 8)), with: .color(DeskColor.identity.color))
            context.stroke(Path(ellipseIn: CGRect(x: start.x - 8, y: start.y - 8, width: 16, height: 16)), with: .color(DeskColor.identity.color.opacity(0.5)), lineWidth: 1)
        }
    }

    private func drawRuler(in context: inout GraphicsContext) {
        guard let ruler = frame.ruler, let start = point(ruler.from), let end = point(ruler.to) else { return }
        let measure = measurement(ruler)
        let rising = measure.change >= 0
        let tint = rising ? DeskColor.rise.color : DeskColor.fall.color
        let box = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        context.fill(Path(box), with: .color(tint.opacity(0.14)))
        context.stroke(Path(box), with: .color(tint.opacity(0.7)), style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
        var arrow = Path()
        arrow.move(to: CGPoint(x: box.midX, y: start.y))
        arrow.addLine(to: CGPoint(x: box.midX, y: end.y))
        context.stroke(arrow, with: .color(tint), lineWidth: 1.2)

        var caption = String(format: "%@ (%@%.2f%%), %d bars", PriceAxis.label(abs(measure.change)),
                             rising ? "+" : Direction.minus, abs(measure.percent), abs(measure.bars))
        if let duration = measure.durationText { caption += ", \(duration)" }
        if frame.leverage > 1 {
            caption += String(format: "\nat %d× ≈ %@%.1f%% on margin", frame.leverage,
                              rising ? "+" : Direction.minus, abs(measure.percent) * Double(frame.leverage))
        }
        let resolved = context.resolve(
            Text(caption).font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white))
        let textSize = resolved.measure(in: CGSize(width: 300, height: 60))
        let above = end.y <= start.y
        var origin = CGPoint(x: box.midX - textSize.width / 2 - 10, y: above ? box.minY - textSize.height - 22 : box.maxY + 8)
        origin.x = min(max(origin.x, 2), geometry.plot.maxX - textSize.width - 22)
        origin.y = min(max(origin.y, 2), geometry.plot.maxY - textSize.height - 14)
        let tag = CGRect(origin: origin, size: CGSize(width: textSize.width + 20, height: textSize.height + 12))
        context.fill(Path(roundedRect: tag, cornerRadius: 8), with: .color(Color(white: 0.16).opacity(0.96)))
        context.stroke(Path(roundedRect: tag, cornerRadius: 8), with: .color(tint.opacity(0.6)), lineWidth: 0.8)
        context.draw(resolved, at: CGPoint(x: tag.midX, y: tag.midY), anchor: .center)
    }

    func measurement(_ ruler: (from: ChartAnchor, to: ChartAnchor)) -> ChartMeasure {
        let bars = frame.interval > 0 ? Int(((ruler.to.time - ruler.from.time) / frame.interval).rounded()) : 0
        return ChartMeasure(fromPrice: ruler.from.price, toPrice: ruler.to.price, bars: bars,
                            seconds: abs(ruler.to.time - ruler.from.time))
    }

    /// The candle under the crosshair, if any.
    var hoveredIndex: Int? {
        guard let crosshair = frame.crosshair else { return nil }
        let index = frame.window.index(atSlot: geometry.slot(atX: crosshair.x))
        return frame.candles.indices.contains(index) ? index : nil
    }

    /// Where the horizontal line sits: the finger, or the nearest of the candle's four
    /// prices when the magnet is on.
    func crosshairPrice(at point: CGPoint) -> Double {
        let free = geometry.scale.value(atY: point.y)
        guard frame.magnet, let index = hoveredIndex else { return free }
        let candle = candles[index]
        return [candle.open, candle.high, candle.low, candle.close].min { abs($0 - free) < abs($1 - free) } ?? free
    }

    private func drawCrosshair(in context: inout GraphicsContext) {
        guard let crosshair = frame.crosshair else { return }
        let plot = geometry.plot
        let slot = geometry.slot(atX: min(max(crosshair.x, 0), plot.maxX - 1))
        let x = geometry.x(slot: slot)
        let price = crosshairPrice(at: crosshair)
        let y = min(max(geometry.scale.y(price), plot.minY), plot.maxY)
        var cross = Path()
        cross.move(to: CGPoint(x: x, y: 0))
        cross.addLine(to: CGPoint(x: x, y: geometry.size.height - StudioGeometry.timeAxisHeight))
        cross.move(to: CGPoint(x: 0, y: y))
        cross.addLine(to: CGPoint(x: plot.maxX, y: y))
        context.stroke(cross, with: .color(.white.opacity(0.7)), style: StrokeStyle(lineWidth: 0.8, dash: [4, 3]))
        var mark = Path()
        mark.move(to: CGPoint(x: x - 9, y: y))
        mark.addLine(to: CGPoint(x: x + 9, y: y))
        mark.move(to: CGPoint(x: x, y: y - 9))
        mark.addLine(to: CGPoint(x: x, y: y + 9))
        context.stroke(mark, with: .color(DeskColor.identity.color), lineWidth: 1.6)
        axisTag(PriceAxis.label(price), y: y, fill: .white.opacity(0.92), text: .black, in: &context)

        if let time = time(atFractionalIndex: Double(frame.window.index(atSlot: slot))) {
            let when = context.resolve(
                Text(Self.full.string(from: Date(timeIntervalSince1970: time)))
                    .font(.system(size: 10, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.black))
            let size = when.measure(in: CGSize(width: 160, height: 20))
            let width = size.width + 12
            let top = geometry.size.height - StudioGeometry.timeAxisHeight
            let tag = CGRect(x: min(max(x - width / 2, 0), plot.maxX - width), y: top + 1, width: width, height: StudioGeometry.timeAxisHeight - 3)
            context.fill(Path(roundedRect: tag, cornerRadius: 4), with: .color(.white.opacity(0.92)))
            context.draw(when, at: CGPoint(x: tag.midX, y: tag.midY), anchor: .center)
        }
    }

    private func pill(_ text: Text, at point: CGPoint, tint: Color, in context: inout GraphicsContext) {
        let resolved = context.resolve(text.font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(tint))
        let size = resolved.measure(in: CGSize(width: 200, height: 40))
        let rect = CGRect(x: point.x, y: point.y - size.height / 2 - 3, width: size.width + 12, height: size.height + 6)
        context.fill(Path(roundedRect: rect, cornerRadius: rect.height / 2), with: .color(.black.opacity(0.78)))
        context.stroke(Path(roundedRect: rect, cornerRadius: rect.height / 2), with: .color(tint.opacity(0.5)), lineWidth: 0.8)
        context.draw(resolved, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
    }

    private func axisTag(_ label: String, y: CGFloat, fill: Color, text: Color, in context: inout GraphicsContext) {
        let resolved = context.resolve(
            Text(label).font(.system(size: 10, weight: .bold, design: .rounded).monospacedDigit()).foregroundStyle(text))
        let size = resolved.measure(in: CGSize(width: 90, height: 20))
        let rect = CGRect(x: geometry.plot.maxX + 2, y: y - size.height / 2 - 3,
                          width: min(StudioGeometry.axisWidth - 4, size.width + 10), height: size.height + 6)
        context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(fill))
        context.draw(resolved, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
    }

    private func compact(_ value: Double) -> String {
        let magnitude = abs(value)
        if magnitude >= 1e9 { return String(format: "%.2fB", magnitude / 1e9) }
        if magnitude >= 1e6 { return String(format: "%.2fM", magnitude / 1e6) }
        if magnitude >= 1e3 { return String(format: "%.1fK", magnitude / 1e3) }
        return String(format: "%.0f", magnitude)
    }
}

/// The drawing alone, so a share image and the live screen render the same pixels.
struct StudioCanvas: View {
    let frame: StudioFrame

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let geometry = StudioGeometry(size: size, frame: frame)
            StudioPainter(frame: frame, geometry: geometry).draw(in: &context)
        }
    }
}

// MARK: - Screen

/// The chart at full size: history to pan and pinch through, studies, drawings that
/// persist per market, a crosshair that doubles as a ruler, and the order buttons so
/// nobody has to leave to act on what they saw. Portrait by default; a button turns it.
struct ChartStudio: View {
    let market: MarketModel
    let network: String
    var guides: [PriceGuide] = []
    /// The side of the position this chart was opened from, so a level knows whether it
    /// would be a take profit or a stop.
    var heldSide: Direction?
    var onTrade: ((Direction, TicketPreset?) -> Void)?
    var onProtect: ((_ takeProfit: String?, _ stopLoss: String?) -> Void)?
    let onClose: () -> Void

    /// What one finger is doing. Decided on the first movement, not the first touch, so
    /// a hand that rests before it drags still pans.
    private enum Touch { case undecided, pan, crosshair, ruler }

    @AppStorage("desk.chart.style") private var styleName = ChartStyle.candles.rawValue
    @AppStorage("desk.chart.overlays") private var overlayNames = "ma7,ma25,ma99"
    @AppStorage("desk.chart.panes") private var paneNames = "volume"
    @AppStorage("desk.chart.log") private var logScale = false
    @AppStorage("desk.chart.magnet") private var magnet = false

    @State private var window = ChartWindow(total: 0, visible: Self.defaultVisible)
    @State private var studies = StudySet()
    @State private var seriesFirstTime: Double?
    @State private var tool: ChartTool = .none
    @State private var crosshairMode = false
    @State private var landscape = false
    @State private var drawings: [ChartDrawing] = []
    @State private var pendingTrend: ChartAnchor?
    @State private var ruler: (from: ChartAnchor, to: ChartAnchor)?
    @State private var crosshair: CGPoint?
    @State private var touch: Touch?
    @State private var hold: Task<Void, Never>?
    @State private var rulerFrom: ChartAnchor?
    @State private var dragStart: ChartWindow?
    @State private var zoomStart: ChartWindow?
    @State private var shareImage: ShareImage?
    @State private var canvasSize: CGSize = .zero
    @State private var levelMenu: ChartDrawing?
    @State private var alertMenu: Double?
    @State private var alerts: [Double] = []

    private static let defaultVisible = 70

    private var style: ChartStyle { ChartStyle(rawValue: styleName) ?? .candles }
    private var overlays: Set<ChartOverlay> { Set(overlayNames.split(separator: ",").compactMap { ChartOverlay(rawValue: String($0)) }) }
    private var panes: [ChartPane] { ChartPane.allCases.filter { paneNames.split(separator: ",").map(String.init).contains($0.rawValue) } }
    private var drawingKey: String { ChartDrawingStore.key(market.symbol, network: network) }
    private var priceScale: Double { pow(10.0, Double(market.market?.config.priceDecimals ?? 0)) }

    /// The venue's candles with the live mark folded into the newest one, so the last
    /// bar moves with the price between candle refreshes.
    private var candles: [ChartCandle] {
        var series = market.candles.map { $0.chartCandle(scale: priceScale) }
        if let mark = market.mark.value, let last = series.last {
            let live = Double(mark.raw) / priceScale
            series[series.count - 1] = ChartCandle(
                open: last.open, high: max(last.high, live), low: min(last.low, live),
                close: live, volume: last.volume, time: last.time)
        }
        return series
    }

    private var frame: StudioFrame {
        StudioFrame(
            candles: candles, interval: Double(market.candleIntervalSeconds), window: window, style: style,
            overlays: overlays, panes: panes, logScale: logScale, guides: guides, drawings: drawings,
            pendingTrend: pendingTrend, ruler: ruler, crosshair: crosshair, magnet: magnet, studies: studies,
            alerts: alerts, leverage: Int(market.market?.config.maxLeverage ?? 1))
    }

    private var priceDecimals: Int { Int(market.market?.config.priceDecimals ?? 2) }
    private func priceText(_ price: Double) -> String { String(format: "%.\(priceDecimals)f", price) }
    private func refreshAlerts() { alerts = TradeAlerts.shared.targets(for: market.symbol).map(\.price) }

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width > proxy.size.height
            VStack(spacing: 0) {
                header(wide: wide)
                if !wide { readout.padding(.horizontal, 12).padding(.bottom, 6) }
                chart
                if wide {
                    HStack(spacing: 10) {
                        intervals
                        Spacer(minLength: 0)
                        tools
                        tradeButtons
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 46)
                } else {
                    intervals.padding(.horizontal, 10).padding(.top, 6)
                    HStack(spacing: 8) {
                        tools
                        Spacer(minLength: 0)
                        tradeButtons
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 50)
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(DeskColor.nightText.color)
        .onAppear {
            market.setCandleDepth(400)
            drawings = ChartDrawingStore.load(drawingKey)
            refreshAlerts()
            syncSeries()
        }
        .onDisappear {
            OrientationLock.request(.portrait)
            market.setCandleDepth(MarketModel.defaultCandleDepth)
        }
        .onChange(of: market.candles) { syncSeries() }
        .onChange(of: market.candleIntervalSeconds) {
            pendingTrend = nil
            ruler = nil
            window = ChartWindow(total: 0, visible: window.visible)
        }
        .onChange(of: drawings) { ChartDrawingStore.save(drawings, key: drawingKey) }
        #if DEBUG
        .task {
            // `-chart-style <name>` picks a style; `-studio-demo` puts the crosshair, a ruler,
            // a level and an alert on screen for a screenshot.
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "-chart-style"), index + 1 < arguments.count,
               ChartStyle(rawValue: arguments[index + 1]) != nil {
                styleName = arguments[index + 1]
            }
            guard arguments.contains("-studio-demo") else { return }
            while candles.count < 60 || canvasSize == .zero { try? await Task.sleep(for: .milliseconds(200)) }
            let geometry = StudioGeometry(size: canvasSize, frame: frame)
            let painter = StudioPainter(frame: frame, geometry: geometry)
            crosshairMode = true
            let from = CGPoint(x: geometry.plot.width * 0.35, y: geometry.plot.height * 0.62)
            let to = CGPoint(x: geometry.plot.width * 0.7, y: geometry.plot.height * 0.3)
            crosshair = from
            if let a = anchor(at: from, geometry: geometry, painter: painter), let b = anchor(at: to, geometry: geometry, painter: painter) {
                ruler = (a, b)
            }
            if let level = anchor(at: CGPoint(x: 10, y: geometry.plot.height * 0.78), geometry: geometry, painter: painter) {
                drawings = [ChartDrawing(id: UUID(), kind: .level, a: level, b: nil)]
                alerts = [geometry.scale.value(atY: geometry.plot.height * 0.2)]
            }
        }
        #endif
        .sheet(item: $shareImage) { shared in
            StudioActivitySheet(items: [shared.image])
                .presentationDetents([.medium, .large])
        }
        .confirmationDialog(
            levelMenu.map { "Level \(PriceAxis.label($0.a.price))" } ?? "",
            isPresented: Binding(get: { levelMenu != nil }, set: { if !$0 { levelMenu = nil } }),
            titleVisibility: .visible, presenting: levelMenu
        ) { drawing in levelActions(drawing) }
        .confirmationDialog(
            alertMenu.map { "Alert at \(PriceAxis.label($0))" } ?? "",
            isPresented: Binding(get: { alertMenu != nil }, set: { if !$0 { alertMenu = nil } }),
            titleVisibility: .visible, presenting: alertMenu
        ) { price in
            Button("Remove alert", role: .destructive) {
                for target in TradeAlerts.shared.targets(for: market.symbol) where target.price == price {
                    TradeAlerts.shared.removeTarget(target)
                }
                refreshAlerts()
            }
        }
    }

    /// What a horizontal level can become: protection on a held position, protection on a
    /// new order, or a one-time alert. Which side it protects follows from where it sits.
    @ViewBuilder private func levelActions(_ drawing: ChartDrawing) -> some View {
        let price = drawing.a.price
        let text = priceText(price)
        if let mark = candles.last?.close, price != mark {
            let above = price > mark
            if let onProtect, let heldSide {
                if (heldSide == .up) == above {
                    Button("Set take profit here") { onProtect(text, nil) }
                } else {
                    Button("Set stop loss here") { onProtect(nil, text) }
                }
            }
            if let onTrade {
                if above {
                    Button("Long, take profit here") { onTrade(.up, TicketPreset(takeProfit: text, stopLoss: nil)) }
                    Button("Short, stop loss here") { onTrade(.down, TicketPreset(takeProfit: nil, stopLoss: text)) }
                } else {
                    Button("Long, stop loss here") { onTrade(.up, TicketPreset(takeProfit: nil, stopLoss: text)) }
                    Button("Short, take profit here") { onTrade(.down, TicketPreset(takeProfit: text, stopLoss: nil)) }
                }
            }
            if !alerts.contains(price) {
                Button("Alert when price crosses \(PriceAxis.label(price))") {
                    Task {
                        if await TradeAlerts.shared.addTarget(market: market.symbol, price: price, mark: mark) { refreshAlerts() }
                    }
                }
            }
        }
        Button("Remove level", role: .destructive) { drawings.removeAll { $0.id == drawing.id } }
    }

    /// The ruler read as an order: enter now, take profit where the ruler ends.
    private struct Plan { let title: String; let symbol: String; let act: () -> Void }

    private func plan(for ruler: (from: ChartAnchor, to: ChartAnchor)) -> Plan? {
        guard ruler.to.price != ruler.from.price else { return nil }
        let side: Direction = ruler.to.price > ruler.from.price ? .up : .down
        let text = priceText(ruler.to.price)
        let shown = PriceAxis.label(ruler.to.price)
        let symbol = side == .up ? "arrow.up.right" : "arrow.down.right"
        if let onProtect, let heldSide {
            guard heldSide == side else { return nil }
            return Plan(title: "Set TP \(shown)", symbol: symbol) { onProtect(text, nil) }
        }
        if let onTrade {
            return Plan(title: "\(side == .up ? "Long" : "Short") · TP \(shown)", symbol: symbol) {
                onTrade(side, TicketPreset(takeProfit: text, stopLoss: nil))
            }
        }
        return nil
    }

    private func syncSeries() {
        let series = market.candles
        let first = series.first.map { Double($0.t) / 1_000 }
        var prepended = 0
        if let first, let previous = seriesFirstTime, first < previous {
            prepended = series.prefix { Double($0.t) / 1_000 < previous }.count
        }
        seriesFirstTime = first
        window.update(total: series.count, prepended: prepended)
        studies = StudySet(candles: series.map { $0.chartCandle(scale: priceScale) })
    }

    // MARK: Header

    private var hovered: ChartCandle? {
        guard crosshair != nil, canvasSize != .zero else { return nil }
        let painter = StudioPainter(frame: frame, geometry: StudioGeometry(size: canvasSize, frame: frame))
        guard let index = painter.hoveredIndex else { return nil }
        return (style == .heikinAshi ? studies.heikin : candles)[index]
    }

    private var change: (text: String, up: Bool)? {
        guard let listed = market.market, let mark = market.mark.value else { return nil }
        let previous = Double(listed.state.previousRaw) / priceScale
        let now = Double(mark.raw) / priceScale
        guard previous > 0 else { return nil }
        let percent = (now - previous) / previous * 100
        return (String(format: "%@%.2f%%", percent >= 0 ? "+" : Direction.minus, abs(percent)), percent >= 0)
    }

    private func header(wide: Bool) -> some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(DeskColor.nightMuted.color)
            .accessibilityLabel("Close chart")

            HStack(spacing: 8) {
                MarketTokenLogo(symbol: market.symbol, size: 22)
                Text(market.symbol)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                if wide {
                    Text(intervalLabel)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            }
            .layoutPriority(1)

            if let last = candles.last {
                let shown = hovered ?? last
                let tint = shown.isRising ? DeskColor.rise.color : DeskColor.fall.color
                HStack(spacing: 8) {
                    Text(hovered == nil
                         ? (market.mark.value?.display(fractionDigits: market.market?.config.priceDecimals ?? 2) ?? PriceAxis.label(last.close))
                         : PriceAxis.label(shown.close))
                        .font(.system(size: 16, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(tint)
                        .contentTransition(.numericText())
                    if hovered == nil, let change {
                        Text(change.text)
                            .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(change.up ? DeskColor.rise.color : DeskColor.fall.color)
                    }
                    if wide { ohlc(shown, tint: tint) }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .layoutPriority(1)
            }

            Spacer(minLength: 4)

            if wide { countdown }

            Button { turn() } label: {
                Image(systemName: "rotate.right")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(DeskColor.nightMuted.color)
            .accessibilityLabel(landscape ? "Turn upright" : "Turn sideways")

            Button { share() } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(DeskColor.nightMuted.color)
            .accessibilityLabel("Share chart")
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
    }

    /// The hovered candle's four prices, its volume, and the time left in the live one.
    private var readout: some View {
        HStack(spacing: 10) {
            if let last = candles.last {
                let shown = hovered ?? last
                ohlc(shown, tint: shown.isRising ? DeskColor.rise.color : DeskColor.fall.color)
                if let volume = shown.volume, volume > 0 {
                    HStack(spacing: 3) {
                        Text("Vol").foregroundStyle(DeskColor.nightMuted.color)
                        Text(Self.compact(volume)).foregroundStyle(DeskColor.nightText.color)
                    }
                    .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                }
            }
            Spacer(minLength: 0)
            countdown
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private func ohlc(_ candle: ChartCandle, tint: Color) -> some View {
        HStack(spacing: 8) {
            ForEach([("O", candle.open), ("H", candle.high), ("L", candle.low), ("C", candle.close)], id: \.0) { label, value in
                HStack(spacing: 3) {
                    Text(label).foregroundStyle(DeskColor.nightMuted.color)
                    Text(PriceAxis.label(value)).foregroundStyle(tint)
                }
            }
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
        .lineLimit(1)
    }

    private var intervalLabel: String {
        CandleIntervalRail.intervals.first { $0.0 == market.candleIntervalSeconds }?.1 ?? "\(market.candleIntervalSeconds)s"
    }

    /// Time left in the current candle, ticking once a second on its own.
    private var countdown: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let interval = Double(market.candleIntervalSeconds)
            let elapsed = context.date.timeIntervalSince1970.truncatingRemainder(dividingBy: interval)
            let remaining = Int(interval - elapsed)
            HStack(spacing: 4) {
                Image(systemName: "timer").font(.system(size: 10, weight: .bold))
                Text(remaining >= 3_600 ? String(format: "%d:%02d:%02d", remaining / 3_600, remaining % 3_600 / 60, remaining % 60)
                                        : String(format: "%02d:%02d", remaining / 60, remaining % 60))
                    .monospacedDigit()
            }
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(DeskColor.nightMuted.color)
        }
        .accessibilityLabel("Time until the candle closes")
    }

    private static func compact(_ value: Double) -> String {
        let magnitude = abs(value)
        if magnitude >= 1e9 { return String(format: "%.2fB", magnitude / 1e9) }
        if magnitude >= 1e6 { return String(format: "%.2fM", magnitude / 1e6) }
        if magnitude >= 1e3 { return String(format: "%.1fK", magnitude / 1e3) }
        return String(format: "%.0f", magnitude)
    }

    private func turn() {
        landscape.toggle()
        OrientationLock.request(landscape ? .landscapeRight : .portrait)
    }

    // MARK: Chart

    private var chart: some View {
        GeometryReader { proxy in
            let frame = frame
            let geometry = StudioGeometry(size: proxy.size, frame: frame)
            let painter = StudioPainter(frame: frame, geometry: geometry)
            ZStack(alignment: .topTrailing) {
                if candles.isEmpty {
                    ProgressView().tint(DeskColor.nightMuted.color)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    StudioCanvas(frame: frame)
                        .contentShape(Rectangle())
                        .gesture(dragGesture(geometry: geometry, painter: painter).simultaneously(with: zoomGesture(geometry: geometry)))
                        .simultaneousGesture(ExclusiveGesture(doubleTap, tapGesture(painter: painter)))
                }
                if !window.isAtLatest {
                    Button {
                        withAnimation(.snappy(duration: 0.25)) { window.jumpToLatest() }
                    } label: {
                        Image(systemName: "chevron.right.2")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .deskGlass(interactive: true, in: Circle())
                    .padding(.trailing, StudioGeometry.axisWidth + 8)
                    .padding(.top, 8)
                    .accessibilityLabel("Back to the latest candle")
                }
                if market.isLoadingOlderCandles {
                    ProgressView().tint(DeskColor.nightMuted.color).scaleEffect(0.7)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .padding(.leading, 8)
                }
                if let ruler, let plan = plan(for: ruler) {
                    Button(action: plan.act) {
                        HStack(spacing: 6) {
                            Image(systemName: plan.symbol).font(.system(size: 11, weight: .bold))
                            Text(plan.title).font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                        }
                        .foregroundStyle(DeskColor.nightText.color)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .deskGlass(interactive: true, in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(.leading, 8)
                    .padding(.bottom, StudioGeometry.timeAxisHeight + 8)
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: ruler != nil)
            .onAppear { canvasSize = proxy.size }
            .onChange(of: proxy.size) { canvasSize = proxy.size }
        }
        .padding(.leading, 2)
        .animation(.easeOut(duration: 0.15), value: window.isAtLatest)
    }

    /// One finger. A drag pans; a drag that begins on the crosshair measures from it; in
    /// crosshair mode a drag carries the crosshair; and a finger that rests before it
    /// moves brings the crosshair up under itself for as long as it stays down.
    private func dragGesture(geometry: StudioGeometry, painter: StudioPainter) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard zoomStart == nil else { return }
                if touch == nil { begin(at: value.startLocation, geometry: geometry, painter: painter) }
                switch touch {
                case .undecided:
                    guard hypot(value.translation.width, value.translation.height) > 8 else { return }
                    hold?.cancel()
                    touch = .pan
                    dragStart = window
                    fallthrough
                case .pan:
                    guard let dragStart else { return }
                    var moved = dragStart
                    moved.pan(bySlots: Int((value.translation.width / geometry.slotWidth).rounded()))
                    window = moved
                    if window.range.lowerBound < 30 { Task { await market.loadOlderCandles() } }
                case .crosshair:
                    place(crosshairAt: value.location, geometry: geometry, painter: painter)
                case .ruler:
                    guard let rulerFrom, let to = anchor(at: value.location, geometry: geometry, painter: painter) else { return }
                    ruler = (rulerFrom, to)
                case nil:
                    break
                }
            }
            .onEnded { _ in
                hold?.cancel()
                if touch == .crosshair, !crosshairMode { crosshair = nil }
                touch = nil
                dragStart = nil
                rulerFrom = nil
            }
    }

    private func begin(at start: CGPoint, geometry: StudioGeometry, painter: StudioPainter) {
        if crosshairMode {
            if let crosshair, hypot(crosshair.x - start.x, crosshair.y - start.y) < 36,
               let from = anchor(at: crosshair, geometry: geometry, painter: painter) {
                touch = .ruler
                rulerFrom = from
                ruler = nil
            } else {
                touch = .crosshair
                ruler = nil
                place(crosshairAt: start, geometry: geometry, painter: painter)
            }
            return
        }
        touch = .undecided
        hold = Task {
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled, touch == .undecided else { return }
            touch = .crosshair
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            place(crosshairAt: start, geometry: geometry, painter: painter)
        }
    }

    private func place(crosshairAt point: CGPoint, geometry: StudioGeometry, painter: StudioPainter) {
        let clamped = CGPoint(x: min(max(point.x, 0), geometry.plot.maxX - 1),
                              y: min(max(point.y, geometry.plot.minY), geometry.plot.maxY))
        let before = painter.hoveredIndex
        crosshair = clamped
        var probe = frame
        probe.crosshair = clamped
        if StudioPainter(frame: probe, geometry: geometry).hoveredIndex != before {
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    private func zoomGesture(geometry: StudioGeometry) -> some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.02)
            .onChanged { value in
                if zoomStart == nil {
                    hold?.cancel()
                    zoomStart = window
                    touch = nil
                    if !crosshairMode { crosshair = nil }
                }
                guard let zoomStart else { return }
                var zoomed = zoomStart
                zoomed.zoom(by: Double(value.magnification), anchorFraction: min(max(Double(value.startLocation.x / geometry.plot.width), 0), 1))
                window = zoomed
            }
            .onEnded { _ in zoomStart = nil }
    }

    private var doubleTap: some Gesture {
        SpatialTapGesture(count: 2).onEnded { _ in
            withAnimation(.snappy(duration: 0.25)) {
                window = ChartWindow(total: window.total, visible: Self.defaultVisible)
            }
        }
    }

    private func tapGesture(painter: StudioPainter) -> some Gesture {
        SpatialTapGesture().onEnded { value in
            switch tool {
            case .none:
                if let hit = nearestDrawing(to: value.location, painter: painter),
                   let drawing = drawings.first(where: { $0.id == hit }), drawing.kind == .level {
                    levelMenu = drawing
                } else if let price = alerts.min(by: { abs(painter.geometry.scale.y($0) - value.location.y) < abs(painter.geometry.scale.y($1) - value.location.y) }),
                          abs(painter.geometry.scale.y(price) - value.location.y) < 14 {
                    alertMenu = price
                } else if crosshairMode {
                    ruler = nil
                    place(crosshairAt: value.location, geometry: painter.geometry, painter: painter)
                } else {
                    crosshair = nil
                    ruler = nil
                }
            case .level:
                guard let anchor = anchor(at: value.location, geometry: painter.geometry, painter: painter) else { return }
                drawings.append(ChartDrawing(id: UUID(), kind: .level, a: anchor, b: nil))
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            case .trend:
                guard let anchor = anchor(at: value.location, geometry: painter.geometry, painter: painter) else { return }
                if let start = pendingTrend {
                    drawings.append(ChartDrawing(id: UUID(), kind: .trend, a: start, b: anchor))
                    pendingTrend = nil
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } else {
                    pendingTrend = anchor
                }
            case .erase:
                if let hit = nearestDrawing(to: value.location, painter: painter) {
                    drawings.removeAll { $0.id == hit }
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                }
            }
        }
    }

    private func anchor(at point: CGPoint, geometry: StudioGeometry, painter: StudioPainter) -> ChartAnchor? {
        guard let time = painter.time(atFractionalIndex: Double(frame.window.index(atSlot: geometry.slot(atX: point.x)))) else { return nil }
        var probe = frame
        probe.crosshair = point
        let price = StudioPainter(frame: probe, geometry: geometry).crosshairPrice(at: point)
        return ChartAnchor(time: time, price: price)
    }

    private func nearestDrawing(to point: CGPoint, painter: StudioPainter) -> UUID? {
        var best: (UUID, CGFloat)?
        for drawing in drawings {
            let distance: CGFloat
            switch drawing.kind {
            case .level:
                distance = abs(painter.geometry.scale.y(drawing.a.price) - point.y)
            case .trend:
                guard let b = drawing.b, let start = painter.point(drawing.a), let end = painter.point(b) else { continue }
                distance = Self.distance(from: point, toSegment: start, end)
            }
            if distance < 14, best.map({ distance < $0.1 }) ?? true { best = (drawing.id, distance) }
        }
        return best?.0
    }

    private static func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = min(max(((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared, 0), 1)
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }

    // MARK: Toolbar

    private var intervals: some View {
        HStack(spacing: 0) {
            ForEach(CandleIntervalRail.intervals, id: \.0) { seconds, label in
                let selected = market.candleIntervalSeconds == seconds
                Button { market.selectCandleInterval(seconds) } label: {
                    Text(label)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(selected ? DeskColor.nightText.color : DeskColor.nightMuted.color)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background(selected ? Color.white.opacity(0.14) : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var tools: some View {
        HStack(spacing: 6) {
            Button {
                crosshairMode.toggle()
                ruler = nil
                if crosshairMode {
                    if crosshair == nil, canvasSize != .zero {
                        crosshair = CGPoint(x: (canvasSize.width - StudioGeometry.axisWidth) * 0.5, y: canvasSize.height * 0.4)
                    }
                } else {
                    crosshair = nil
                }
            } label: {
                toolbarIcon("plus", active: crosshairMode, weight: .regular, size: 20)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Crosshair")

            indicatorMenu
            toolMenu
            styleMenu
            settingsMenu
        }
    }

    @ViewBuilder private var tradeButtons: some View {
        if let onTrade {
            HStack(spacing: 6) {
                tradeButton(.down, title: "Short") { onTrade($0, nil) }
                tradeButton(.up, title: "Long") { onTrade($0, nil) }
            }
        }
    }

    private func toolbarIcon(_ symbol: String, active: Bool = false, weight: Font.Weight = .semibold, size: CGFloat = 15) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(active ? DeskColor.action.color : DeskColor.nightText.color)
            .frame(width: 36, height: 32)
            .background(active ? DeskColor.action.color.opacity(0.14) : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
    }

    private var styleMenu: some View {
        Menu {
            ForEach(ChartStyle.allCases) { item in
                Button {
                    styleName = item.rawValue
                } label: {
                    if style == item { Label(item.title, systemImage: "checkmark") } else { Text(item.title) }
                }
            }
        } label: { toolbarIcon(style.symbol) }
        .accessibilityLabel("Chart style")
    }

    private var indicatorMenu: some View {
        Menu {
            Section("On the chart") {
                ForEach(ChartOverlay.allCases) { item in
                    Button { toggle(item) } label: {
                        if overlays.contains(item) { Label(item.title, systemImage: "checkmark") } else { Text(item.title) }
                    }
                }
            }
            Section("Below the chart") {
                ForEach(ChartPane.allCases) { item in
                    Button { toggle(item) } label: {
                        if panes.contains(item) { Label(item.title, systemImage: "checkmark") } else { Text(item.title) }
                    }
                }
            }
        } label: { toolbarIcon("function", active: !overlays.isEmpty || !panes.isEmpty) }
        .accessibilityLabel("Indicators")
    }

    private var toolMenu: some View {
        Menu {
            ForEach(ChartTool.allCases) { item in
                Button {
                    tool = item
                    pendingTrend = nil
                } label: {
                    if tool == item { Label(item.title, systemImage: "checkmark") } else { Label(item.title, systemImage: item.symbol) }
                }
            }
            if !drawings.isEmpty {
                Divider()
                Button(role: .destructive) { drawings.removeAll() } label: { Label("Clear drawings", systemImage: "trash") }
            }
        } label: { toolbarIcon(tool == .none ? "pencil.and.outline" : tool.symbol, active: tool != .none) }
        .accessibilityLabel("Drawing tools")
    }

    private var settingsMenu: some View {
        Menu {
            Toggle("Log scale", isOn: $logScale)
            Toggle("Magnet crosshair", isOn: $magnet)
        } label: { toolbarIcon("slider.horizontal.3", active: logScale) }
        .accessibilityLabel("Chart settings")
    }

    private func toggle(_ overlay: ChartOverlay) {
        var set = overlays
        if set.contains(overlay) { set.remove(overlay) } else { set.insert(overlay) }
        overlayNames = ChartOverlay.allCases.filter { set.contains($0) }.map(\.rawValue).joined(separator: ",")
    }

    private func toggle(_ pane: ChartPane) {
        var list = panes
        if let index = list.firstIndex(of: pane) { list.remove(at: index) } else { list.append(pane) }
        paneNames = ChartPane.allCases.filter { list.contains($0) }.map(\.rawValue).joined(separator: ",")
    }

    private func tradeButton(_ side: Direction, title: String, action: @escaping (Direction) -> Void) -> some View {
        Button { action(side) } label: {
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.black)
                .padding(.horizontal, 18)
                .frame(height: 34)
                .background(side.color.color, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Share

    private func share() {
        var still = frame
        still.crosshair = nil
        let content = VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                DeskBrandMark(size: 22)
                Text("\(market.symbol) · \(intervalLabel)")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
                Spacer()
                if let last = candles.last {
                    Text(PriceAxis.label(last.close))
                        .font(.system(size: 18, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(last.isRising ? DeskColor.rise.color : DeskColor.fall.color)
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 52)
            StudioCanvas(frame: still)
        }
        .frame(width: 1_200, height: 700)
        .background(Color.black)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        if let image = renderer.uiImage { shareImage = ShareImage(image: image) }
    }
}

private struct ShareImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

private struct StudioActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
