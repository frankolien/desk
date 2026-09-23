import Foundation
import Testing

@testable import DeskUI

/// The parts of a chart that are arithmetic rather than drawing.
@Suite("Chart candles")
struct ChartCandleTests {
    /// A short series is pushed to the right against a reserved density, instead of each
    /// candle expanding to fill the width.
    @Test("A sparse series keeps candle-sized candles")
    func sparseSeriesIsRightAligned() {
        let layout = CandleLayout(count: 2, width: 240, minimumSlots: 24)
        #expect(layout.slots == 24)
        #expect(layout.leading == 22)
        #expect(layout.step == 10)
        // Both candles sit at the right-hand end, where the newest data belongs.
        #expect(layout.x(0) == 225)
        #expect(layout.x(1) == 235)
    }

    @Test("A full series uses every slot")
    func fullSeriesFillsWidth() {
        let layout = CandleLayout(count: 30, width: 300, minimumSlots: 24)
        #expect(layout.slots == 30)
        #expect(layout.leading == 0)
        #expect(layout.x(0) == 5)
    }

    /// An empty series must still produce a usable step rather than dividing by zero.
    @Test("An empty series does not divide by zero")
    func emptySeries() {
        let layout = CandleLayout(count: 0, width: 240)
        #expect(layout.slots == 24)
        #expect(layout.step.isFinite)
        #expect(layout.step > 0)
    }

    /// Both surfaces share one label, and their prices are four orders of magnitude
    /// apart: a perpetual at 76,000 and a spot token at 0.0000761 on the same axis code.
    @Test("Labels adapt to the magnitude they are given", arguments: [
        (76_182.6, "76,183"),
        (1_000.0, "1,000"),
        (97.66, "97.66"),
        (1.0, "1.00"),
        (0.0325, "0.0325"),
        (0.0, "0"),
    ])
    func labelsByMagnitude(value: Double, expected: String) {
        #expect(PriceAxis.label(value) == expected)
    }

    /// The case a fixed two-decimal format destroyed: every spot token in the feed.
    @Test("A millionth-scale price keeps its significant digits")
    func tinyPricesKeepDigits() {
        let label = PriceAxis.label(0.0000761)
        #expect(label != "0.00")
        #expect(Double(label).map { abs($0 - 0.0000761) < 0.0000001 } == true)
    }

    /// A spot token's axis printed "0.000100" directly above "0.0000500" — the same
    /// column at two different widths, because precision came from each value rather than
    /// from the step they share.
    @Test("Every tick on one axis prints at the same precision")
    func ticksSharePrecision() {
        let axis = PriceAxis(
            candleLow: 0.0000488, candleHigh: 0.0001021,
            height: 250, topInset: 7, bottomInset: 7)
        let ticks = axis.ticks()
        #expect(ticks.count >= 2)
        let widths = Set(ticks.map { $0.label.split(separator: ".").last?.count ?? 0 })
        #expect(widths.count == 1, "labels: \(ticks.map(\.label))")
    }

    /// The perpetual case must keep reading as whole grouped prices rather than
    /// inheriting the step's decimal places.
    @Test("A thousands-scale axis labels whole grouped prices")
    func thousandsKeepGroupedLabels() {
        let axis = PriceAxis(
            candleLow: 74_940, candleHigh: 77_190,
            height: 250, topInset: 7, bottomInset: 7)
        for tick in axis.ticks() {
            #expect(tick.label.contains(","), "unexpected label \(tick.label)")
            #expect(!tick.label.contains("."), "unexpected label \(tick.label)")
        }
    }

    @Test("Rising is decided by the close against the open")
    func rising() {
        #expect(ChartCandle(open: 1, high: 2, low: 0.5, close: 1.5).isRising)
        #expect(!ChartCandle(open: 2, high: 2, low: 0.5, close: 1.5).isRising)
    }
}
