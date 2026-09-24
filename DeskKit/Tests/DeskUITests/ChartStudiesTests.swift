import Foundation
import Testing

@testable import DeskUI

@Suite("Chart studies")
struct ChartStudiesTests {
    @Test("A moving average is blank until it has enough bars, then averages the window")
    func simpleAverage() {
        let values: [Double] = [1, 2, 3, 4, 5, 6]
        let average = ChartStudies.sma(values, period: 3)
        #expect(average[0] == nil && average[1] == nil)
        #expect(average[2] == 2)
        #expect(average[5] == 5)
    }

    @Test("An EMA starts at the simple average and leans toward new values")
    func exponentialAverage() {
        let values: [Double] = [10, 10, 10, 20]
        let average = ChartStudies.ema(values, period: 3)
        #expect(average[2] == 10)
        // weight 0.5: (20 - 10) * 0.5 + 10
        #expect(average[3] == 15)
    }

    @Test("Bollinger bands sit symmetric about the average")
    func bollinger() {
        let values: [Double] = [2, 4, 4, 4, 5, 5, 7, 9]
        let bands = ChartStudies.bollinger(values, period: 8, width: 2)
        // Population deviation of this classic set is exactly 2.
        #expect(bands.middle[7] == 5)
        #expect(bands.upper[7] == 9)
        #expect(bands.lower[7] == 1)
        #expect(bands.upper[6] == nil)
    }

    @Test("RSI reads 100 for a market that only rose and 0 for one that only fell")
    func relativeStrengthExtremes() {
        let rising = (0..<20).map(Double.init)
        let falling = rising.reversed()
        #expect(ChartStudies.rsi(rising, period: 14)[19] == 100)
        #expect(ChartStudies.rsi(Array(falling), period: 14)[19] == 0)
        #expect(ChartStudies.rsi(rising, period: 14)[13] == nil)
    }

    @Test("MACD of a flat series is zero everywhere it is defined")
    func flatMACD() {
        let flat = [Double](repeating: 50, count: 60)
        let macd = ChartStudies.macd(flat)
        #expect(macd.line[25] == 0)
        #expect(macd.line[24] == nil)
        #expect(macd.signal[33] == 0)
        #expect(macd.signal[32] == nil)
        #expect(macd.histogram[59] == 0)
    }

    @Test("VWAP weights by volume and restarts each UTC day")
    func vwapRestarts() {
        let day = 86_400.0
        let candles = [
            ChartCandle(open: 1, high: 10, low: 10, close: 10, volume: 1, time: 0),
            ChartCandle(open: 1, high: 20, low: 20, close: 20, volume: 3, time: 3_600),
            ChartCandle(open: 1, high: 40, low: 40, close: 40, volume: 1, time: day + 60),
        ]
        let vwap = ChartStudies.vwap(candles)
        #expect(vwap[0] == 10)
        #expect(vwap[1] == 17.5)
        #expect(vwap[2] == 40)
    }

    @Test("Heikin-Ashi closes at the bar's average and opens at the previous body's middle")
    func heikinAshi() {
        let candles = [
            ChartCandle(open: 10, high: 14, low: 8, close: 12),
            ChartCandle(open: 12, high: 16, low: 11, close: 15),
        ]
        let smoothed = ChartStudies.heikinAshi(candles)
        #expect(smoothed[0].close == 11)
        #expect(smoothed[0].open == 11)
        #expect(smoothed[1].open == 11)
        #expect(smoothed[1].close == 13.5)
        #expect(smoothed[1].high == 16)
    }
}

@Suite("Chart window")
struct ChartWindowTests {
    @Test("A fresh window shows the newest candles with a small gap on the right")
    func startsAtLatest() {
        let window = ChartWindow(total: 300, visible: 80)
        #expect(window.isAtLatest)
        #expect(window.range == 230..<300)
        #expect(window.end == 310)
    }

    @Test("Panning into history stops at the oldest candle")
    func panClamps() {
        var window = ChartWindow(total: 100, visible: 40)
        window.pan(bySlots: 1_000)
        #expect(window.range == 0..<40)
        #expect(!window.isAtLatest)
        window.pan(bySlots: -1_000)
        #expect(window.isAtLatest)
        #expect(window.end <= 100 + window.maximumGap)
    }

    @Test("Zooming keeps the anchored candle under the finger")
    func zoomKeepsAnchor() {
        var window = ChartWindow(total: 500, visible: 100, rightGap: 0)
        window.pan(bySlots: 100)
        let anchored = window.index(atSlot: 50)
        window.zoom(by: 2, anchorFraction: 0.5)
        #expect(window.visible == 50)
        #expect(window.index(atSlot: 25) == anchored)
    }

    @Test("New candles keep a live window at the latest and leave a history view in place")
    func growth() {
        var live = ChartWindow(total: 100, visible: 30)
        live.update(total: 101)
        #expect(live.isAtLatest)
        #expect(live.range.upperBound == 101)

        var history = ChartWindow(total: 100, visible: 30, rightGap: 0)
        history.pan(bySlots: 50)
        let shown = history.range
        history.update(total: 200, prepended: 100)
        #expect(history.range == (shown.lowerBound + 100)..<(shown.upperBound + 100))
    }

    @Test("A short series is right-aligned with empty leading slots")
    func shortSeries() {
        let window = ChartWindow(total: 5, visible: 40, rightGap: 0)
        #expect(window.leadingSlots == 35)
        #expect(window.slot(of: 4) == 39)
    }
}

@Suite("Chart scale")
struct ChartScaleTests {
    @Test("A linear scale maps the top of the range to the top of the plot")
    func linear() {
        let scale = ChartScale(low: 100, high: 200, logarithmic: false, top: 10, height: 100, paddingFraction: 0)
        #expect(scale.y(200) == 10)
        #expect(scale.y(100) == 110)
        #expect(abs(scale.value(atY: 60) - 150) < 1e-9)
    }

    @Test("A log scale puts the geometric middle at the visual middle")
    func logarithmic() {
        let scale = ChartScale(low: 1, high: 100, logarithmic: true, top: 0, height: 100, paddingFraction: 0)
        #expect(abs(scale.y(10) - 50) < 1e-9)
        #expect(scale.ticks(count: 3).count == 3)
    }

    @Test("A log scale falls back to linear when the range touches zero")
    func logNeedsPositives() {
        let scale = ChartScale(low: 0, high: 10, logarithmic: true, top: 0, height: 100)
        #expect(!scale.logarithmic)
    }

    @Test("A ruler reads the move in price, percent and time")
    func measure() {
        let measure = ChartMeasure(fromPrice: 100, toPrice: 125, bars: 4, seconds: 4 * 3_600)
        #expect(measure.change == 25)
        #expect(measure.percent == 25)
        #expect(measure.durationText == "4h")
        #expect(ChartMeasure(fromPrice: 1, toPrice: 1, bars: 1, seconds: 90 * 60).durationText == "1h 30m")
        #expect(ChartMeasure(fromPrice: 1, toPrice: 1, bars: 1, seconds: 3 * 86_400).durationText == "3d")
    }
}
