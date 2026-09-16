import CoreGraphics
import Foundation

/// One candle, as a chart needs it.
///
/// Deliberately neutral. The perps series arrives as integers at a market's price
/// decimals and the spot series as doubles from a market-data feed; a chart that took
/// either one directly is a chart only one screen can use. Converting here is for drawing
/// only — every figure that decides a position stays an integer.
public struct ChartCandle: Sendable, Equatable {
    public let open: Double
    public let high: Double
    public let low: Double
    public let close: Double
    /// Absent where the feed does not publish it, which is most spot tokens.
    public let volume: Double?

    public init(open: Double, high: Double, low: Double, close: Double, volume: Double? = nil) {
        self.open = open
        self.high = high
        self.low = low
        self.close = close
        self.volume = volume
    }

    public var isRising: Bool { close >= open }
}

/// Where candles sit across the width, including the empty room in front of a short
/// series.
///
/// An illiquid token truthfully returns two or three buckets. Spread across the full
/// width those become slabs half a phone wide, which reads as a market with enormous
/// candles rather than one with almost no trades, so a minimum density is reserved and
/// the series is right-aligned against it.
public struct CandleLayout: Sendable, Equatable {
    public let slots: Int
    public let leading: Int
    public let step: CGFloat

    public init(count: Int, width: CGFloat, minimumSlots: Int = 24) {
        let slots = max(count, minimumSlots, 1)
        self.slots = slots
        self.leading = slots - count
        self.step = width / CGFloat(slots)
    }

    /// Centre of the candle at `index` within the series.
    public func x(_ index: Int) -> CGFloat {
        (CGFloat(leading + index) + 0.5) * step
    }
}
