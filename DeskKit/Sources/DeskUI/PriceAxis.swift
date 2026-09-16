import CoreGraphics
import Foundation

/// The vertical scale of a price chart: the range it covers, where a price lands inside
/// it, and the ticks that label it.
///
/// One mapping, in one place. Every chart defect so far has been two pieces of arithmetic
/// disagreeing about where a price belongs — a grid row against a candle, a clamped guide
/// against a tick — and each was invisible until it was drawn. Here it can be tested.
public struct PriceAxis: Sendable, Equatable {
    /// A labelled position on the axis. The label is formatted from the step every tick
    /// shares, so a column of them cannot print at mixed precision.
    public struct Tick: Sendable, Equatable {
        public let value: Double
        public let y: CGFloat
        public let label: String
    }

    /// Where a price sits, and whether it is outside the range entirely.
    public struct Placement: Sendable, Equatable {
        public let y: CGFloat
        public let offScale: OffScale?

        public var isOffScale: Bool { offScale != nil }
    }

    public enum OffScale: Sendable, Equatable { case above, below }

    public let low: Double
    public let high: Double
    public let height: CGFloat
    public let topInset: CGFloat
    public let bottomInset: CGFloat

    /// Builds a range that covers the candles and gives guides whatever room is left.
    ///
    /// `candleShare` is the fraction of the plot the candles keep. A guide further away
    /// than the remaining budget does not widen the range: it is reported as off-scale so
    /// the caller can pin it to the edge, which keeps the price action readable no matter
    /// how far a liquidation sits from the market.
    public init(
        candleLow: Double,
        candleHigh: Double,
        guides: [Double] = [],
        height: CGFloat,
        topInset: CGFloat = 0,
        bottomInset: CGFloat = 0,
        candleShare: Double = 0.72
    ) {
        let observedLow = min(candleLow, candleHigh)
        let observedHigh = max(candleLow, candleHigh)
        // A market that has not moved inside the window still needs a range to draw in,
        // so a flat series is padded either side rather than left with no height.
        let span = max(observedHigh - observedLow, max(abs(observedHigh), 1) * 0.0001)
        let padding = (span - (observedHigh - observedLow)) / 2
        let lowest = observedLow - padding
        let highest = observedHigh + padding
        let share = min(max(candleShare, 0.05), 1)
        let budget = span / share - span

        var below = 0.0
        var above = 0.0
        for guide in guides where guide.isFinite {
            below = max(below, lowest - guide)
            above = max(above, guide - highest)
        }
        let needed = below + above
        let granted = needed > budget ? budget / needed : 1

        self.low = lowest - below * granted
        self.high = highest + above * granted
        self.height = height
        self.topInset = topInset
        self.bottomInset = bottomInset
    }

    /// Height available to the range itself, once the insets are taken.
    public var usableHeight: CGFloat { max(height - topInset - bottomInset, 1) }

    /// Unclamped: a price outside the range maps outside the plot.
    public func y(_ value: Double) -> CGFloat {
        let span = high - low
        guard span > 0 else { return topInset }
        let fraction = (value - low) / span
        return topInset + usableHeight * CGFloat(1 - fraction)
    }

    /// Clamped to the plot, saying which edge it was pulled to.
    public func place(_ value: Double) -> Placement {
        let top = topInset
        let bottom = topInset + usableHeight
        let raw = y(value)
        if raw < top - 0.5 { return Placement(y: top, offScale: .above) }
        if raw > bottom + 0.5 { return Placement(y: bottom, offScale: .below) }
        return Placement(y: raw, offScale: nil)
    }

    /// Ticks on round numbers rather than on an even division of the range.
    ///
    /// An even division produces values like 77.19K and 76.15K, which carry no meaning and
    /// land wherever the range happens to start. Round steps are both readable and far
    /// less likely to collide with a guide, whose price is arbitrary.
    public func ticks(count: Int = 4) -> [Tick] {
        guard count >= 2, high > low else { return [] }
        let step = Self.niceStep((high - low) / Double(count - 1))
        guard step > 0 else { return [] }

        var values: [Double] = []
        var value = (low / step).rounded(.up) * step
        // A bounded walk: a step that underflowed would otherwise never reach `high`.
        while value <= high + step * 1e-9, values.count <= count * 4 {
            values.append(value)
            value += step
        }
        return values.map { Tick(value: $0, y: y($0), label: Self.label($0, step: step)) }
    }

    /// Ticks with any that would crowd a guide removed.
    ///
    /// Guides are placed, not raw, so a guide pinned to an edge suppresses the tick beside
    /// that edge too — which is the case where two prices a hair apart used to be printed
    /// on top of each other.
    public func ticks(count: Int = 4, clearOf guides: [Double], within separation: CGFloat) -> [Tick] {
        let positions = guides.map { place($0).y }
        return ticks(count: count).filter { tick in
            !positions.contains { abs($0 - tick.y) < separation }
        }
    }

    /// A label whose precision comes from the axis step rather than from the value.
    ///
    /// Derived per value, neighbouring ticks printed at different widths: a spot token's
    /// axis read "0.000100" above "0.0000500". One step, one precision.
    public static func label(_ value: Double, step: Double) -> String {
        if abs(value) >= 1_000 { return String(format: "%.2fK", value / 1_000) }
        guard step > 0, step.isFinite else { return label(value) }
        let places = min(max(Int(ceil(-log10(step))) + 1, 0), 12)
        return String(format: "%.\(places)f", value)
    }

    /// A tick label that survives the range of things Desk charts.
    ///
    /// The perpetual markets print in thousands and the spot tokens in millionths. A
    /// single fixed format cannot show both: two decimals renders a token at 0.0000761
    /// as "0.00", and eight renders Bitcoin as a wall of zeroes.
    public static func label(_ value: Double) -> String {
        let magnitude = abs(value)
        if magnitude >= 1_000 { return String(format: "%.2fK", value / 1_000) }
        if magnitude >= 1 { return String(format: "%.2f", value) }
        if magnitude >= 0.01 { return String(format: "%.4f", value) }
        if magnitude == 0 { return "0" }
        // Two digits past the first significant one, so neighbouring ticks differ.
        let places = min(Int(ceil(-log10(magnitude))) + 2, 12)
        return String(format: "%.\(places)f", value)
    }

    /// The 1, 2, 5, 10 ladder every axis uses.
    static func niceStep(_ raw: Double) -> Double {
        guard raw > 0, raw.isFinite else { return 0 }
        let magnitude = pow(10, log10(raw).rounded(.down))
        switch raw / magnitude {
        case ..<1.5: return magnitude
        case ..<3: return 2 * magnitude
        case ..<7: return 5 * magnitude
        default: return 10 * magnitude
        }
    }
}
