import CoreGraphics
import Foundation

/// The arithmetic behind every study the chart can draw. Pure functions over closes and
/// candles: the view decides colour and placement, nothing here does.
///
/// Every series is returned aligned to its input, with `nil` where the study has not yet
/// had enough bars to say anything. A moving average that started at zero would draw a
/// line diving in from the corner; a `nil` leaves the first bars honestly blank.
public enum ChartStudies {
    public static func sma(_ values: [Double], period: Int) -> [Double?] {
        guard period > 0, values.count >= period else { return Array(repeating: nil, count: values.count) }
        var result = [Double?](repeating: nil, count: values.count)
        var sum = values[..<period].reduce(0, +)
        result[period - 1] = sum / Double(period)
        for index in period..<values.count {
            sum += values[index] - values[index - period]
            result[index] = sum / Double(period)
        }
        return result
    }

    /// Seeded with the simple average of the first `period` bars, the way every terminal
    /// does it, so the line agrees with what a trader sees elsewhere.
    public static func ema(_ values: [Double], period: Int) -> [Double?] {
        guard period > 0, values.count >= period else { return Array(repeating: nil, count: values.count) }
        var result = [Double?](repeating: nil, count: values.count)
        let weight = 2 / Double(period + 1)
        var current = values[..<period].reduce(0, +) / Double(period)
        result[period - 1] = current
        for index in period..<values.count {
            current = (values[index] - current) * weight + current
            result[index] = current
        }
        return result
    }

    public struct Bands: Sendable, Equatable {
        public let upper: [Double?]
        public let middle: [Double?]
        public let lower: [Double?]

        public init(upper: [Double?], middle: [Double?], lower: [Double?]) {
            self.upper = upper
            self.middle = middle
            self.lower = lower
        }
    }

    /// Population deviation, as TradingView and Binance compute it.
    public static func bollinger(_ values: [Double], period: Int = 20, width: Double = 2) -> Bands {
        let middle = sma(values, period: period)
        var upper = [Double?](repeating: nil, count: values.count)
        var lower = [Double?](repeating: nil, count: values.count)
        guard period > 0 else { return Bands(upper: upper, middle: middle, lower: lower) }
        for index in values.indices where index >= period - 1 {
            guard let mean = middle[index] else { continue }
            let window = values[(index - period + 1)...index]
            let variance = window.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(period)
            let deviation = variance.squareRoot()
            upper[index] = mean + width * deviation
            lower[index] = mean - width * deviation
        }
        return Bands(upper: upper, middle: middle, lower: lower)
    }

    /// Wilder's smoothing. A market that only rose reads 100, one that only fell reads 0.
    public static func rsi(_ closes: [Double], period: Int = 14) -> [Double?] {
        guard period > 0, closes.count > period else { return Array(repeating: nil, count: closes.count) }
        var result = [Double?](repeating: nil, count: closes.count)
        var gain = 0.0
        var loss = 0.0
        for index in 1...period {
            let move = closes[index] - closes[index - 1]
            if move >= 0 { gain += move } else { loss -= move }
        }
        var averageGain = gain / Double(period)
        var averageLoss = loss / Double(period)
        result[period] = strength(averageGain, averageLoss)
        for index in (period + 1)..<closes.count {
            let move = closes[index] - closes[index - 1]
            averageGain = (averageGain * Double(period - 1) + max(move, 0)) / Double(period)
            averageLoss = (averageLoss * Double(period - 1) + max(-move, 0)) / Double(period)
            result[index] = strength(averageGain, averageLoss)
        }
        return result
    }

    private static func strength(_ gain: Double, _ loss: Double) -> Double {
        guard loss > 0 else { return 100 }
        return 100 - 100 / (1 + gain / loss)
    }

    public struct MACD: Sendable, Equatable {
        public let line: [Double?]
        public let signal: [Double?]
        public let histogram: [Double?]

        public init(line: [Double?], signal: [Double?], histogram: [Double?]) {
            self.line = line
            self.signal = signal
            self.histogram = histogram
        }
    }

    public static func macd(_ closes: [Double], fast: Int = 12, slow: Int = 26, signal signalPeriod: Int = 9) -> MACD {
        let fastLine = ema(closes, period: fast)
        let slowLine = ema(closes, period: slow)
        var line = [Double?](repeating: nil, count: closes.count)
        for index in closes.indices {
            if let quick = fastLine[index], let steady = slowLine[index] { line[index] = quick - steady }
        }
        // The signal is an EMA of the MACD line where it exists, so it starts later still.
        let defined = line.compactMap { $0 }
        let firstDefined = line.firstIndex { $0 != nil } ?? closes.count
        let signalDefined = ema(defined, period: signalPeriod)
        var signal = [Double?](repeating: nil, count: closes.count)
        var histogram = [Double?](repeating: nil, count: closes.count)
        for (offset, value) in signalDefined.enumerated() {
            let index = firstDefined + offset
            guard index < closes.count, let value, let macd = line[index] else { continue }
            signal[index] = value
            histogram[index] = macd - value
        }
        return MACD(line: line, signal: signal, histogram: histogram)
    }

    /// Volume-weighted average price, restarting at each UTC day when the candles carry
    /// a time. Candles without volume contribute nothing and inherit the running value.
    public static func vwap(_ candles: [ChartCandle]) -> [Double?] {
        var result = [Double?](repeating: nil, count: candles.count)
        var weighted = 0.0
        var volume = 0.0
        var day: Int?
        for (index, candle) in candles.enumerated() {
            if let time = candle.time {
                let current = Int((time / 86_400).rounded(.down))
                if day != current { day = current; weighted = 0; volume = 0 }
            }
            if let share = candle.volume, share > 0 {
                weighted += (candle.high + candle.low + candle.close) / 3 * share
                volume += share
            }
            result[index] = volume > 0 ? weighted / volume : nil
        }
        return result
    }

    /// Smoothed candles that show the trend rather than each bar's noise.
    public static func heikinAshi(_ candles: [ChartCandle]) -> [ChartCandle] {
        var result: [ChartCandle] = []
        result.reserveCapacity(candles.count)
        var previous: ChartCandle?
        for candle in candles {
            let close = (candle.open + candle.high + candle.low + candle.close) / 4
            let open = previous.map { ($0.open + $0.close) / 2 } ?? (candle.open + candle.close) / 2
            let smoothed = ChartCandle(
                open: open, high: max(candle.high, open, close), low: min(candle.low, open, close),
                close: close, volume: candle.volume, time: candle.time)
            result.append(smoothed)
            previous = smoothed
        }
        return result
    }
}

/// Which candles are on screen. Pans and zooms move this rather than the data, so the
/// series can grow at either end without the view jumping.
public struct ChartWindow: Sendable, Equatable {
    public static let minimumVisible = 8
    public static let maximumVisible = 500

    public private(set) var total: Int
    public private(set) var visible: Int
    /// Exclusive index of the last slot on screen. It may run past `total` so the newest
    /// candle can sit clear of the price axis; the slots after it are empty.
    public private(set) var end: Int

    public init(total: Int, visible: Int = 90, rightGap: Int? = nil) {
        self.total = max(total, 0)
        self.visible = min(max(visible, Self.minimumVisible), Self.maximumVisible)
        self.end = self.total + (rightGap ?? Self.defaultGap(for: self.visible))
        clamp()
    }

    static func defaultGap(for visible: Int) -> Int { max(3, visible / 8) }

    /// The empty slots allowed past the newest candle.
    public var maximumGap: Int { max(3, visible / 3) }
    public var range: Range<Int> { max(end - visible, 0)..<min(end, total) }
    public var leadingSlots: Int { max(0, visible - end) }
    public var isAtLatest: Bool { end >= total }
    /// Slot index (0 = leftmost on screen) of the candle at `index` in the series.
    public func slot(of index: Int) -> Int { index - (end - visible) }
    public func index(atSlot slot: Int) -> Int { slot + end - visible }

    public mutating func pan(bySlots delta: Int) {
        end -= delta
        clamp()
    }

    /// Zooms so the candle under `anchorFraction` of the width stays under the finger.
    public mutating func zoom(by factor: Double, anchorFraction: Double) {
        guard factor > 0, factor.isFinite else { return }
        let anchorIndex = Double(end - visible) + Double(visible) * anchorFraction
        let target = min(max(Int((Double(visible) / factor).rounded()), Self.minimumVisible), Self.maximumVisible)
        guard target != visible else { return }
        visible = target
        end = Int((anchorIndex + Double(visible) * (1 - anchorFraction)).rounded())
        clamp()
    }

    /// Snaps back to the newest candle, keeping the current zoom.
    public mutating func jumpToLatest() {
        end = total + Self.defaultGap(for: visible)
        clamp()
    }

    /// The series grew or was replaced. A window that was at the latest stays there;
    /// one that had panned into history keeps the same candles on screen when the
    /// growth was on the left (`prepended` older candles), and stays put otherwise.
    public mutating func update(total newTotal: Int, prepended: Int = 0) {
        let wasAtLatest = isAtLatest
        total = max(newTotal, 0)
        if wasAtLatest { end = total + Self.defaultGap(for: visible) } else { end += prepended }
        clamp()
    }

    private mutating func clamp() {
        visible = min(max(visible, Self.minimumVisible), Self.maximumVisible)
        end = min(max(end, min(visible, total)), total + maximumGap)
    }
}

/// A vertical scale that can be linear or logarithmic and knows how to label itself.
public struct ChartScale: Sendable, Equatable {
    public struct Tick: Sendable, Equatable {
        public let value: Double
        public let y: CGFloat
        public let label: String
    }

    public let low: Double
    public let high: Double
    public let logarithmic: Bool
    public let top: CGFloat
    public let height: CGFloat

    /// `low`/`high` are prices. A log scale needs positives; anything else is linear.
    public init(low: Double, high: Double, logarithmic: Bool, top: CGFloat, height: CGFloat, paddingFraction: Double = 0.06) {
        let lowest = min(low, high)
        let highest = max(low, high)
        let useLog = logarithmic && lowest > 0
        let span = max(highest - lowest, max(abs(highest), 1) * 0.0001)
        let pad = span * paddingFraction
        self.low = useLog ? max(lowest - pad, lowest * 0.999) : lowest - pad
        self.high = highest + pad
        self.logarithmic = useLog
        self.top = top
        self.height = max(height, 1)
    }

    private func transform(_ value: Double) -> Double { logarithmic ? log10(max(value, .leastNonzeroMagnitude)) : value }
    private func inverse(_ value: Double) -> Double { logarithmic ? pow(10, value) : value }

    public func y(_ value: Double) -> CGFloat {
        let lo = transform(low)
        let hi = transform(high)
        guard hi > lo else { return top }
        let fraction = (transform(value) - lo) / (hi - lo)
        return top + height * CGFloat(1 - fraction)
    }

    public func value(atY y: CGFloat) -> Double {
        let lo = transform(low)
        let hi = transform(high)
        let fraction = 1 - Double((y - top) / height)
        return inverse(lo + (hi - lo) * fraction)
    }

    /// Round-number ticks on a linear scale; evenly spaced ticks on a log one, since
    /// round numbers bunch up at the bottom of a log axis.
    public func ticks(count: Int = 5) -> [Tick] {
        guard count >= 2, high > low else { return [] }
        if logarithmic {
            return (0..<count).map { step in
                let y = top + height * CGFloat(step) / CGFloat(count - 1)
                let price = value(atY: y)
                return Tick(value: price, y: y, label: PriceAxis.label(price))
            }
        }
        let step = PriceAxis.niceStep((high - low) / Double(count - 1))
        guard step > 0 else { return [] }
        var values: [Double] = []
        var next = (low / step).rounded(.up) * step
        while next <= high + step * 1e-9, values.count <= count * 4 {
            values.append(next)
            next += step
        }
        return values.map { Tick(value: $0, y: y($0), label: PriceAxis.label($0, step: step)) }
    }
}

/// What a ruler dragged between two candles reads.
public struct ChartMeasure: Sendable, Equatable {
    public let fromPrice: Double
    public let toPrice: Double
    public let bars: Int
    public let seconds: Double?

    public init(fromPrice: Double, toPrice: Double, bars: Int, seconds: Double?) {
        self.fromPrice = fromPrice
        self.toPrice = toPrice
        self.bars = bars
        self.seconds = seconds
    }

    public var change: Double { toPrice - fromPrice }
    public var percent: Double { fromPrice == 0 ? 0 : change / fromPrice * 100 }

    public var durationText: String? {
        guard let seconds, seconds > 0 else { return nil }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 48 { return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m" }
        let days = hours / 24
        return hours % 24 == 0 ? "\(days)d" : "\(days)d \(hours % 24)h"
    }
}
