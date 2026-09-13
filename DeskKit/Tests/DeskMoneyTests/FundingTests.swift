import Foundation
import Testing

@testable import DeskMoney

@Suite("Funding")
struct FundingTests {
    @Test("The interval is forty-three minutes, not an hour")
    func interval() {
        // Annualising at 8,760 instead of 12,223 understates funding by 28.4%.
        #expect(Funding.intervalSeconds == 2_580)
        #expect(Funding.intervalsPerYear == 12_223)
        #expect(365 * 86_400 / Funding.intervalSeconds == Funding.intervalsPerYear)
        let understatement = 1.0 - Double(8_760) / Double(Funding.intervalsPerYear)
        #expect(abs(understatement - 0.284) < 0.001)
    }

    /// Every market carrying funding in the live testnet context, checked against the
    /// derived encoding. This is what establishes that `rate` is in micros.
    @Test(
        "The premium relation holds on live market data",
        arguments: [
            (name: "BTC", idx: Int64(772_281), rate: Int64(30), div: Int64(1), ppl: Int64(23)),
            (name: "ETH", idx: 252_511, rate: 0, div: 1, ppl: 0),
            (name: "SOL", idx: 10_168, rate: 0, div: 1_000, ppl: 0),
            (name: "MON", idx: 2_309, rate: 0, div: 1_000, ppl: 0),
            (name: "ZEC", idx: 1_121_464, rate: 40, div: 100, ppl: 4_485),
            (name: "LIT", idx: 421_129, rate: 0, div: 10, ppl: 0),
            (name: "PUMP", idx: 3_776, rate: 0, div: 100, ppl: 0),
        ])
    func premiumRelation(market: (name: String, idx: Int64, rate: Int64, div: Int64, ppl: Int64)) {
        #expect(
            Funding.premiumPnL(indexRaw: market.idx, rateMicros: market.rate, divisor: market.div)
                == market.ppl, "\(market.name)")
    }

    @Test("A negative rate truncates toward zero, as the wire does")
    func negativeTruncates() {
        // 772281 × -30 / 10^6 is -23.168. Truncating gives -23; flooring would give -24
        // and put the funding figure a unit out on every negative rate.
        #expect(Funding.premiumPnL(indexRaw: 772_281, rateMicros: -30, divisor: 1) == -23)
        #expect(Funding.premiumPnL(indexRaw: 1_121_464, rateMicros: -40, divisor: 100) == -4_485)
    }

    @Test("An index and rate that would overflow are refused rather than trapping")
    func overflowRefused() {
        #expect(Funding.premiumPnL(indexRaw: .max, rateMicros: .max, divisor: .max) == nil)
        #expect(Funding.annualisedMicros(perIntervalMicros: .max) == nil)
    }

    @Test("A rate annualises by the interval count")
    func annualises() {
        // BTC at 30 micros an interval: 0.003% each, about 36.7% a year.
        #expect(Funding.annualisedMicros(perIntervalMicros: 30) == 366_690)
        #expect(Funding.annualisedMicros(perIntervalMicros: 0) == 0)
        #expect(Funding.annualisedMicros(perIntervalMicros: -30) == -366_690)
    }

    @Test("Funding since entry is a subtraction")
    func accumulator() {
        #expect(Funding.accumulatorDelta(entrySum: 107_377, exitSum: 107_624) == 247)
        #expect(Funding.accumulatorDelta(entrySum: 107_624, exitSum: 107_377) == -247)
        #expect(Funding.accumulatorDelta(entrySum: .min, exitSum: .max) == nil)
    }
}
