import CoreGraphics
import Foundation

public struct PriceAxis: Sendable, Equatable {
    /// A labelled position on the axis. The label is formatted from the step every tick
    /// shares, so a column of them cannot print at mixed precision.
    public struct Tick: Sendable, Equatable {
        public let value: Double
        public let y: CGFloat
        public let label: String
    }

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

    /// A guide beyond the room `candleShare` leaves does not widen the range: it is reported
    /// off-scale so the caller pins it to the edge.
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

    public var usableHeight: CGFloat { max(height - topInset - bottomInset, 1) }

    /// Unclamped: a price outside the range maps outside the plot.
    public func y(_ value: Double) -> CGFloat {
        let span = high - low
        guard span > 0 else { return topInset }
        let fraction = (value - low) / span
        return topInset + usableHeight * CGFloat(1 - fraction)
    }

    public func place(_ value: Double) -> Placement {
        let top = topInset
        let bottom = topInset + usableHeight
        let raw = y(value)
        if raw < top - 0.5 { return Placement(y: top, offScale: .above) }
        if raw > bottom + 0.5 { return Placement(y: bottom, offScale: .below) }
        return Placement(y: raw, offScale: nil)
    }

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

    public func ticks(count: Int = 4, clearOf guides: [Double], within separation: CGFloat) -> [Tick] {
        let positions = guides.map { place($0).y }
        return ticks(count: count).filter { tick in
            !positions.contains { abs($0 - tick.y) < separation }
        }
    }

    public static func label(_ value: Double, step: Double) -> String {
        if abs(value) >= 1_000 { return grouped(value) }
        guard step > 0, step.isFinite else { return label(value) }
        let places = min(max(Int(ceil(-log10(step))) + 1, 0), 12)
        return String(format: "%.\(places)f", value)
    }

    public static func label(_ value: Double) -> String {
        let magnitude = abs(value)
        if magnitude >= 1_000 { return grouped(value) }
        if magnitude >= 1 { return String(format: "%.2f", value) }
        if magnitude >= 0.01 { return String(format: "%.4f", value) }
        if magnitude == 0 { return "0" }
        let places = min(Int(ceil(-log10(magnitude))) + 2, 12)
        return String(format: "%.\(places)f", value)
    }

    static func grouped(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.0f", value)
    }

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
