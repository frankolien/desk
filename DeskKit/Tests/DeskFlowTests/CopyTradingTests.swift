import DeskMoney
import DeskPerpl
import Foundation
import Testing

@testable import DeskFlow

private func market(_ id: UInt32) throws -> Market {
    let url = try #require(Bundle.module.url(forResource: "Context-testnet", withExtension: "json"))
    let context = try JSONDecoder().decode(PerplContext.self, from: Data(contentsOf: url))
    return try #require(context.market(id: id))
}

private func btc(_ side: Side = .long, entry: Double = 60_000, leverage: Double? = 7.6, collateral: Double = 0) -> ObservedPosition {
    ObservedPosition(symbol: "btc", side: side, size: 0.5, entry: entry, mark: 60_000, collateral: collateral, leverage: leverage)
}

private func money(_ whole: Int64) -> Money? { Money(raw: whole * 1_000_000) }

private func plan(
    _ position: ObservedPosition, rules: CopyRules = CopyRules(mode: .live), guards: CopyGuards = CopyGuards(),
    free: Money? = money(1_000), open: [CopyExposure] = [], today: Money? = nil, portfolio: Double? = nil
) throws -> Result<CopyPlan, CopySkip> {
    CopyPlanner.plan(
        copying: position, traderPortfolio: portfolio, rules: rules, guards: guards, market: try market(16),
        mark: try #require(Price(raw: 600_000, decimals: 1)), free: free, openCopies: open,
        realisedToday: today ?? .zero)
}

private func skip(_ result: Result<CopyPlan, CopySkip>) -> CopySkip? {
    if case .failure(let reason) = result { return reason }
    return nil
}

@Suite("Copy trading")
struct CopyTradingTests {
    @Test("Entries, flips and exits are moves; resizing is not")
    func moves() {
        let long = btc()
        #expect(CopyPlanner.moves(before: [:], after: ["BTC": long]) == [.opened(long)])
        #expect(CopyPlanner.moves(before: ["BTC": long], after: [:]) == [.closed(long)])
        let short = btc(.short)
        #expect(CopyPlanner.moves(before: ["BTC": long], after: ["BTC": short]) == [.flipped(short)])
        let bigger = ObservedPosition(symbol: "BTC", side: .long, size: 2, entry: 61_000, leverage: 3)
        #expect(CopyPlanner.moves(before: ["BTC": long], after: ["BTC": bigger]).isEmpty)
    }

    @Test("A copy is sized from the copier's margin at the capped leverage, with venue-held protection")
    func sizing() throws {
        let rules = CopyRules(mode: .live, marginPerTrade: 10, maxLeverage: 5, stopLossPercent: 25, takeProfitPercent: 50)
        let result = try plan(btc(), rules: rules).get()
        #expect(result.side == .long)
        #expect(result.draft.leverageHundredths == 500)
        // 10 AUSD × 5 ÷ 60,000 = 0.000833 BTC, truncated to five decimals.
        #expect(result.draft.size.raw == 83)
        #expect(result.draft.protection?.stopLoss?.raw == 570_000)
        #expect(result.draft.protection?.takeProfit?.raw == 660_000)
    }

    @Test("Fading takes the other side, with its stop above the mark")
    func fade() throws {
        let result = try plan(btc(entry: 60_000), rules: CopyRules(direction: .fade)).get()
        #expect(result.side == .short)
        #expect(result.draft.side == .short)
        #expect(result.draft.protection?.stopLoss?.raw == 630_000)
    }

    @Test("Conviction scales margin by the share of their account behind the trade, within half and double")
    func conviction() throws {
        #expect(CopyPlanner.conviction(collateral: 1_000, portfolio: 10_000) == 1)
        #expect(CopyPlanner.conviction(collateral: 5_000, portfolio: 10_000) == 2)
        #expect(CopyPlanner.conviction(collateral: 100, portfolio: 10_000) == 0.5)
        #expect(CopyPlanner.conviction(collateral: 100, portfolio: nil) == 1)
        let rules = CopyRules(sizing: .conviction, marginPerTrade: 10)
        let heavy = try plan(btc(collateral: 3_000), rules: rules, portfolio: 10_000).get()
        #expect(heavy.margin == 20)
    }

    @Test("The exposure guard trims a copy to the market's room and refuses one that would offset another")
    func exposure() throws {
        let guards = CopyGuards(maxMarketExposure: 80)
        let open = [CopyExposure(symbol: "BTC", side: .long, notional: 50)]
        let trimmed = try plan(btc(), rules: CopyRules(marginPerTrade: 10, maxLeverage: 5), guards: guards, open: open).get()
        #expect(trimmed.margin == 6)
        #expect(skip(try plan(btc(), guards: CopyGuards(maxMarketExposure: 52), open: open)) == .exposureLimit(52))
        #expect(skip(try plan(btc(.short), open: open)) == .offsetsOpenCopy)
    }

    @Test("What is left of the chase allowance bounds the order's slippage")
    func priceProtection() throws {
        let rules = CopyRules(maxChaseBps: 100)
        #expect(try plan(btc(entry: 59_700), rules: rules).get().draft.slippageBps == 50)
        #expect(try plan(btc(entry: 59_600), rules: rules).get().draft.slippageBps == 33)
        #expect(skip(try plan(btc(entry: 59_000), rules: rules)) == .chased(bps: 169))
        #expect(CopyPlanner.chaseBps(entry: 59_000, mark: 60_000, side: .short) == -169)
    }

    @Test("A figure the server should never send is clamped, not trapped")
    func chaseSurvivesGarbage() {
        // A denormal entry makes the ratio exceed every integer type. `Int(_:)` would trap,
        // and the position it came from is persisted, so the crash would repeat every launch.
        #expect(CopyPlanner.chaseBps(entry: 1e-300, mark: 60_000, side: .long) == Int.max)
        #expect(CopyPlanner.chaseBps(entry: 1e-300, mark: 60_000, side: .short) == Int.min)
        #expect(CopyPlanner.chaseBps(entry: .nan, mark: 60_000, side: .long) == 0)
        #expect(CopyPlanner.chaseBps(entry: 60_000, mark: .infinity, side: .long) == 0)
        #expect(CopyPlanner.chaseBps(entry: .infinity, mark: 60_000, side: .long) == 0)
        #expect(CopyPlanner.clampedInt(.nan) == 0)
        #expect(CopyPlanner.clampedInt(-.infinity) == Int.min)
        #expect(CopyPlanner.clampedInt(12.4) == 12)
    }

    @Test("A short's stop sits above the mark and every trigger rounds away from firing early")
    func triggers() throws {
        let mark = try #require(Price(raw: 600_001, decimals: 1))
        #expect(CopyPlanner.trigger(mark: mark, side: .long, percent: -25, leverage: 5)?.raw == 570_000)
        #expect(CopyPlanner.trigger(mark: mark, side: .short, percent: -25, leverage: 5)?.raw == 630_002)
        #expect(CopyPlanner.trigger(mark: mark, side: .long, percent: -600, leverage: 5) == nil)
    }

    @Test("Guards turn a copy into a stated skip")
    func skips() throws {
        let guards = CopyGuards(maxOpenCopies: 3, dailyLossLimit: 50)
        let three = Array(repeating: CopyExposure(symbol: "ETH", side: .long, notional: 1), count: 3)
        #expect(skip(try plan(btc(), guards: guards, open: three)) == .openCopiesLimit(3))
        #expect(skip(try plan(btc(), guards: guards, today: Money(raw: -50_000_000))) == .dailyLossLimit(50))
        #expect(skip(try plan(btc(), free: money(5))) == .insufficientBalance)
        #expect(skip(try plan(btc(), guards: guards, today: Money(raw: -49_000_000))) == nil)
    }

    @Test("Leverage follows the trader within both the copier's and the market's cap")
    func leverage() throws {
        let btcMarket = try market(16)
        #expect(CopyPlanner.leverage(for: btc(leverage: 2.4), rules: CopyRules(maxLeverage: 5), market: btcMarket) == 2)
        #expect(CopyPlanner.leverage(for: btc(leverage: 40), rules: CopyRules(maxLeverage: 50), market: btcMarket) == 15)
        #expect(CopyPlanner.leverage(for: btc(leverage: nil), rules: CopyRules(), market: btcMarket) == 1)
    }

    @Test("A shadow fill pays slippage and fees both ways and fires the stop a live copy would")
    func shadow() throws {
        let rules = CopyRules(marginPerTrade: 10, maxLeverage: 5, stopLossPercent: 25, takeProfitPercent: 50)
        let fill = ShadowFill(mark: 60_000, plan: try plan(btc(), rules: rules).get(), takerFeeMicros: 345, rules: rules)
        #expect(abs(fill.entry - 60_018) < 0.001)
        #expect(abs(fill.fees - 0.01725) < 0.00001)
        // Flat price: the round trip costs slippage and two fees.
        #expect(fill.pnl(at: 60_000, takerFeeMicros: 345) < 0)
        #expect(fill.trigger(at: 57_000) == fill.stop)
        #expect(fill.trigger(at: 66_100) == fill.take)
        #expect(fill.trigger(at: 60_500) == nil)
        // A loss is never more than the margin behind it.
        #expect(fill.pnl(at: 1, takerFeeMicros: 345) == -10)
    }

    @Test("Rules saved before modes existed stay live, followed and fixed")
    func legacyRules() throws {
        let old = #"{"marginPerTrade":10,"maxLeverage":5,"stopLossPercent":25,"closeWithTrader":true,"maxChaseBps":100}"#
        let rules = try JSONDecoder().decode(CopyRules.self, from: Data(old.utf8))
        #expect(rules.mode == .live && rules.direction == .follow && rules.sizing == .fixed)
        let guards = try JSONDecoder().decode(CopyGuards.self, from: Data(#"{"maxOpenCopies":3,"dailyLossLimit":50}"#.utf8))
        #expect(guards.maxMarketExposure == 250)
    }
}
