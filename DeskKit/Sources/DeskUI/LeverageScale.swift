import CoreGraphics
import Foundation

/// The mapping between a leverage value and a position along its rail.
///
/// Extracted for the same reason the price axis was: the drag rounded a fraction into a
/// value inline, nothing asserted it, and the tick density was tied to the leverage range
/// so a five times market drew five marks and a fifteen times market drew fifteen.
public struct LeverageScale: Sendable, Equatable {
    public let maximum: Int
    /// Marks drawn across the rail, independent of the leverage range.
    public let tickCount: Int

    public init(maximum: Int, tickCount: Int = 41) {
        self.maximum = max(1, maximum)
        self.tickCount = max(2, tickCount)
    }

    /// Leverage at a position along the rail, clamped to the ends.
    public func value(atFraction fraction: Double) -> Int {
        guard maximum > 1 else { return 1 }
        let clamped = min(max(fraction, 0), 1)
        return 1 + Int((clamped * Double(maximum - 1)).rounded())
    }

    /// Where a leverage value sits along the rail.
    public func fraction(of value: Int) -> Double {
        guard maximum > 1 else { return 0 }
        let clamped = min(max(value, 1), maximum)
        return Double(clamped - 1) / Double(maximum - 1)
    }

    public func tickFraction(_ index: Int) -> Double {
        Double(min(max(index, 0), tickCount - 1)) / Double(tickCount - 1)
    }

    /// Whether a mark carries emphasis. Every fifth, plus both ends.
    public func isMajor(tick index: Int) -> Bool {
        index == 0 || index == tickCount - 1 || index % 5 == 0
    }

    /// Whether a mark falls at or below the selected value, so the rail reads as filled.
    public func isFilled(tick index: Int, at value: Int) -> Bool {
        tickFraction(index) <= fraction(of: value) + 1e-9
    }

    /// The stops worth labelling: the ends, and the middle when there is room for one.
    public var labelledValues: [Int] {
        guard maximum > 2 else { return Array(1...maximum) }
        return [1, 1 + (maximum - 1) / 2, maximum]
    }
}
