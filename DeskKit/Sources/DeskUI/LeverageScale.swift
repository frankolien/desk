import CoreGraphics
import Foundation

public struct LeverageScale: Sendable, Equatable {
    public let maximum: Int
    public let tickCount: Int

    public init(maximum: Int, tickCount: Int = 41) {
        self.maximum = max(1, maximum)
        self.tickCount = max(2, tickCount)
    }

    public func value(atFraction fraction: Double) -> Int {
        guard maximum > 1 else { return 1 }
        let clamped = min(max(fraction, 0), 1)
        return 1 + Int((clamped * Double(maximum - 1)).rounded())
    }

    public func fraction(of value: Int) -> Double {
        guard maximum > 1 else { return 0 }
        let clamped = min(max(value, 1), maximum)
        return Double(clamped - 1) / Double(maximum - 1)
    }

    public func tickFraction(_ index: Int) -> Double {
        Double(min(max(index, 0), tickCount - 1)) / Double(tickCount - 1)
    }

    public func isMajor(tick index: Int) -> Bool {
        index == 0 || index == tickCount - 1 || index % 5 == 0
    }

    public func isFilled(tick index: Int, at value: Int) -> Bool {
        tickFraction(index) <= fraction(of: value) + 1e-9
    }

    public var labelledValues: [Int] {
        guard maximum > 2 else { return Array(1...maximum) }
        return [1, 1 + (maximum - 1) / 2, maximum]
    }
}
