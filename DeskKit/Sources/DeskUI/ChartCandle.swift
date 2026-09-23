import CoreGraphics
import Foundation

public struct ChartCandle: Sendable, Equatable {
    public let open: Double
    public let high: Double
    public let low: Double
    public let close: Double
    /// Absent where the feed does not publish it, which is most spot tokens.
    public let volume: Double?
    /// Seconds since 1970 at the candle's open, when the feed says.
    public let time: Double?

    public init(open: Double, high: Double, low: Double, close: Double, volume: Double? = nil, time: Double? = nil) {
        self.open = open
        self.high = high
        self.low = low
        self.close = close
        self.volume = volume
        self.time = time
    }

    public var isRising: Bool { close >= open }
}

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
