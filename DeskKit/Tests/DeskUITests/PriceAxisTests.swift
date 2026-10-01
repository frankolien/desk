import Foundation
import Testing

@testable import DeskUI

@Suite("Price axis")
struct PriceAxisTests {
    private func sample(
        guides: [Double] = [], height: CGFloat = 190, share: Double = 0.72
    ) -> PriceAxis {
        PriceAxis(
            candleLow: 96.28, candleHigh: 101.33, guides: guides,
            height: height, topInset: 7, bottomInset: 7, candleShare: share)
    }

    @Test("The range ends land on the insets")
    func endsOnInsets() {
        let axis = sample()
        #expect(abs(axis.y(axis.high) - 7) < 0.0001)
        #expect(abs(axis.y(axis.low) - (190 - 7)) < 0.0001)
    }

    @Test("Every tick sits where the mapping puts its own value")
    func ticksAgreeWithMapping() {
        for guides in [[], [92.74], [97.66, 92.74]] {
            let axis = sample(guides: guides)
            for tick in axis.ticks() {
                #expect(abs(axis.y(tick.value) - tick.y) < 0.0001)
            }
        }
    }

    @Test("Ticks stay inside the range")
    func ticksInRange() {
        let axis = sample(guides: [92.74])
        for tick in axis.ticks() {
            #expect(tick.value >= axis.low - 0.0001)
            #expect(tick.value <= axis.high + 0.0001)
        }
    }

    @Test("Steps come off the 1, 2, 5, 10 ladder", arguments: [
        (0.9, 1.0), (1.0, 1.0), (1.4, 1.0), (1.6, 2.0), (2.9, 2.0),
        (3.1, 5.0), (6.9, 5.0), (7.1, 10.0), (23.0, 20.0), (0.026, 0.02),
    ])
    func niceSteps(raw: Double, expected: Double) {
        #expect(abs(PriceAxis.niceStep(raw) - expected) < 1e-9)
    }

    @Test("Candles keep their share when a guide is far away")
    func farGuideKeepsCandleShare() {
        let axis = sample(guides: [92.74])
        let candleShare = (101.33 - 96.28) / (axis.high - axis.low)
        #expect(abs(candleShare - 0.72) < 0.005)
        #expect(axis.low > 92.74)
        #expect(axis.place(92.74).offScale == .below)
    }

    @Test("A guide within budget is placed rather than clamped")
    func nearGuideIsPlaced() {
        let axis = sample(guides: [95.5])
        #expect(abs(axis.low - 95.5) < 0.0001)
        #expect(axis.place(95.5).offScale == nil)
    }

    @Test("A clamped guide clears the tick beside its edge")
    func clampedGuideSuppressesNeighbouringTick() {
        let axis = sample(guides: [92.74])
        let edge = axis.place(92.74).y
        let ticks = axis.ticks(clearOf: [92.74], within: 11)
        #expect(!ticks.isEmpty)
        for tick in ticks {
            #expect(abs(tick.y - edge) >= 11)
        }
    }

    @Test("A placed guide clears the tick it sits on")
    func placedGuideSuppressesTick() {
        let axis = sample(guides: [95.5])
        let placed = axis.place(95.5).y
        for tick in axis.ticks(clearOf: [95.5], within: 11) {
            #expect(abs(tick.y - placed) >= 11)
        }
    }

    @Test("A flat series does not divide by zero")
    func flatSeries() {
        let axis = PriceAxis(
            candleLow: 100, candleHigh: 100, height: 190, topInset: 7, bottomInset: 7)
        #expect(axis.high > axis.low)
        #expect(axis.y(100).isFinite)
        for tick in axis.ticks() {
            #expect(tick.y.isFinite)
        }
    }

    @Test("A guide above the market reports the top edge")
    func guideAboveClamps() {
        let axis = sample(guides: [140])
        #expect(axis.place(140).offScale == .above)
        #expect(abs(axis.place(140).y - 7) < 0.0001)
    }
}
