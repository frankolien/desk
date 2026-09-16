import Foundation
import Testing

@testable import DeskUI

/// The rail's arithmetic, which decides how much leverage an order carries and was
/// previously done inline inside a drag handler with nothing asserting it.
@Suite("Leverage scale")
struct LeverageScaleTests {
    @Test("The ends of the rail are the ends of the range")
    func endsMapToEnds() {
        let scale = LeverageScale(maximum: 15)
        #expect(scale.value(atFraction: 0) == 1)
        #expect(scale.value(atFraction: 1) == 15)
        #expect(scale.fraction(of: 1) == 0)
        #expect(scale.fraction(of: 15) == 1)
    }

    @Test("The middle of a five times rail is three")
    func middleOfShortRange() {
        let scale = LeverageScale(maximum: 5)
        #expect(scale.value(atFraction: 0.5) == 3)
    }

    /// A thumb dragged past either end must clamp rather than produce leverage the venue
    /// would refuse, or none at all.
    @Test("A drag beyond the rail clamps", arguments: [-3.0, -0.2, 1.4, 12.0])
    func clampsOutsideTheRail(fraction: Double) {
        let scale = LeverageScale(maximum: 10)
        let value = scale.value(atFraction: fraction)
        #expect(value >= 1 && value <= 10)
    }

    /// A market capped at one times still has to draw and still has to answer.
    @Test("A single-step rail does not divide by zero")
    func degenerateRange() {
        let scale = LeverageScale(maximum: 1)
        #expect(scale.value(atFraction: 0.5) == 1)
        #expect(scale.fraction(of: 1) == 0)
        #expect(scale.fraction(of: 9) == 0)
    }

    @Test("Value and fraction are inverses at every step")
    func roundTrip() {
        for maximum in [2, 5, 15, 50] {
            let scale = LeverageScale(maximum: maximum)
            for value in 1...maximum {
                #expect(scale.value(atFraction: scale.fraction(of: value)) == value)
            }
        }
    }

    /// Tick density is fixed, so a five times market and a fifty times market draw the
    /// same rail rather than five marks against fifty.
    @Test("Tick density does not follow the leverage range")
    func densityIsIndependent() {
        #expect(LeverageScale(maximum: 5).tickCount == LeverageScale(maximum: 50).tickCount)
    }

    @Test("The rail fills up to the selected value")
    func fillsToValue() {
        let scale = LeverageScale(maximum: 10)
        let middle = scale.value(atFraction: 0.5)
        #expect(scale.isFilled(tick: 0, at: middle))
        #expect(!scale.isFilled(tick: scale.tickCount - 1, at: middle))
        #expect(scale.isFilled(tick: scale.tickCount - 1, at: 10))
    }

    @Test("Labelled stops stay inside the range")
    func labelledStops() {
        for maximum in [1, 2, 3, 5, 15] {
            let scale = LeverageScale(maximum: maximum)
            #expect(scale.labelledValues.first == 1)
            #expect(scale.labelledValues.last == maximum)
            for value in scale.labelledValues {
                #expect(value >= 1 && value <= maximum)
            }
        }
    }
}
