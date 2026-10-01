import DeskMoney
import Foundation
import Testing

@testable import DeskPerpl

private func state(
    oracle: Int64 = 770_000,
    mark: Int64 = 770_000,
    last: Int64 = 770_000,
    mid: Int64 = 770_000,
    bid: Int64 = 769_900,
    ask: Int64 = 770_100,
    openInterest: Int64 = 1_000_000_000
) throws -> MarketState {
    let body = Data(#"""
    {"at":{"b":1,"t":1789300800000},"orl":\#(oracle),"mrk":\#(mark),"lst":\#(last),
     "mid":\#(mid),"bid":\#(bid),"ask":\#(ask),"prv":\#(mark),"oi":"\#(openInterest)"}
    """#.utf8)
    return try JSONDecoder().decode(MarketState.self, from: body)
}

@Suite("Reading the market")
struct MarketSignalsTests {
    @Test("A perpetual above spot reports a positive premium")
    func premiumAboveSpot() throws {
        let signals = MarketSignals(
            state: try state(oracle: 770_000, mark: 771_540), priceDecimals: 1, sizeDecimals: 5)
        #expect(signals.premiumMicros == 2_000)
        #expect(signals.premiumIsNotable)
    }

    @Test("Below spot the premium is negative")
    func premiumBelowSpot() throws {
        let signals = MarketSignals(
            state: try state(oracle: 770_000, mark: 768_460), priceDecimals: 1, sizeDecimals: 5)
        #expect(signals.premiumMicros == -2_000)
        #expect(signals.premiumIsNotable)
    }

    @Test("A premium under ten basis points is not worth saying")
    func smallPremiumIsNoise() throws {
        let signals = MarketSignals(
            state: try state(oracle: 770_000, mark: 770_030), priceDecimals: 1, sizeDecimals: 5)
        #expect(signals.premiumMicros == 38)
        #expect(!signals.premiumIsNotable)
    }

    @Test("The spread is the bid-ask gap over the mid")
    func spread() throws {
        let signals = MarketSignals(
            state: try state(mid: 770_000, bid: 769_615, ask: 770_385), priceDecimals: 1, sizeDecimals: 5)
        // 770 ticks over 770,000 is exactly 0.1%.
        #expect(signals.spreadMicros == 1_000)
    }

    @Test("A crossed book has no spread rather than a negative one")
    func crossedBook() throws {
        let signals = MarketSignals(
            state: try state(bid: 770_500, ask: 769_500), priceDecimals: 1, sizeDecimals: 5)
        #expect(signals.spreadMicros == nil)
    }

    @Test("An empty book has no spread")
    func emptyBook() throws {
        let signals = MarketSignals(state: try state(bid: 0, ask: 0), priceDecimals: 1, sizeDecimals: 5)
        #expect(signals.spreadMicros == nil)
        #expect(signals.lean == .balanced)
    }

    @Test("The last trade says which side was in a hurry", arguments: [
        (Int64(770_090), MarketSignals.Lean.buyers),
        (Int64(769_910), MarketSignals.Lean.sellers),
        (Int64(770_000), MarketSignals.Lean.balanced),
    ])
    func lean(last: Int64, expected: MarketSignals.Lean) throws {
        let signals = MarketSignals(
            state: try state(last: last, mid: 770_000, bid: 769_900, ask: 770_100),
            priceDecimals: 1, sizeDecimals: 5)
        #expect(signals.lean == expected)
    }

    /// `oi` is in contracts at the market's size scale, not AUSD: read as collateral, eighteen
    /// bitcoin renders as `1.82 AUSD`. Pinned to the live venue's figures of 13 September.
    @Test("Open interest is contracts, not collateral")
    func openInterestIsSize() throws {
        let signals = MarketSignals(
            state: try state(mark: 770_282, openInterest: 1_820_224),
            priceDecimals: 1, sizeDecimals: 5)
        #expect(signals.openInterest?.display(fractionDigits: 5) == "18.20224")
        // 18.20224 BTC at 77,028.2: 1,402,085.783… truncated toward zero, never rounded up,
        // computed from the raw integers.
        let notional = try #require(signals.openInterestNotional)
        #expect(notional.display() == "1,402,085.78")
    }

    @Test("A market with nothing in it reports nothing, not zeroes")
    func emptyMarket() throws {
        let signals = MarketSignals(
            state: try state(oracle: 0, mark: 0, last: 0, mid: 0, bid: 0, ask: 0, openInterest: 0),
            priceDecimals: 1, sizeDecimals: 5)
        #expect(signals.premiumMicros == nil)
        #expect(signals.spreadMicros == nil)
        #expect(signals.openInterest == nil)
        #expect(signals.isEmpty)
    }

    @Test("The pinned testnet market produces usable readings")
    func againstThePinnedContext() throws {
        let url = try #require(Bundle.module.url(forResource: "Context-testnet", withExtension: "json"))
        let context = try JSONDecoder().decode(PerplContext.self, from: Data(contentsOf: url))
        let market = try #require(context.market(id: 16))
        let signals = MarketSignals(
            state: market.state,
            priceDecimals: market.config.priceDecimals,
            sizeDecimals: market.config.sizeDecimals)
        #expect(signals.premiumMicros != nil)
        #expect(!signals.isEmpty)
    }
}
