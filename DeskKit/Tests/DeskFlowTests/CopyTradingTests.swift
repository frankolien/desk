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

private func btc(_ side: Side = .long, entry: Double = 60_000, leverage: Double? = 7.6) -> ObservedPosition {
    ObservedPosition(symbol: "btc", side: side, size: 0.5, entry: entry, leverage: leverage)
}

private func money(_ whole: Int64) -> Money? { Money(raw: whole * 1_000_000) }

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
        let btcMarket = try market(16)
        let mark = try #require(Price(raw: 600_000, decimals: 1))
        let rules = CopyRules(marginPerTrade: 10, maxLeverage: 5, stopLossPercent: 25, takeProfitPercent: 50)
        let draft = try CopyPlanner.draft(
            copying: btc(), rules: rules, guards: CopyGuards(), market: btcMarket, mark: mark,
            free: money(100), openCopies: 0, realisedToday: try #require(money(0))).get()
        #expect(draft.side == .long)
        #expect(draft.leverageHundredths == 500)
        // 10 AUSD × 5 ÷ 60,000 = 0.000833 BTC, truncated to five decimals.
        #expect(draft.size.raw == 83)
        #expect(draft.protection?.stopLoss?.raw == 570_000)
        #expect(draft.protection?.takeProfit?.raw == 660_000)
    }

    @Test("A short's stop sits above the mark and every trigger rounds away from firing early")
    func triggers() throws {
        let mark = try #require(Price(raw: 600_001, decimals: 1))
        #expect(CopyPlanner.trigger(mark: mark, side: .long, percent: -25, leverage: 5)?.raw == 570_000)
        #expect(CopyPlanner.trigger(mark: mark, side: .short, percent: -25, leverage: 5)?.raw == 630_002)
        #expect(CopyPlanner.trigger(mark: mark, side: .long, percent: -600, leverage: 5) == nil)
    }

    @Test("Guards and chasing turn a copy into a stated skip")
    func skips() throws {
        let btcMarket = try market(16)
        let mark = try #require(Price(raw: 600_000, decimals: 1))
        let zero = try #require(money(0))
        func plan(_ position: ObservedPosition, free: Money? = money(100), open: Int = 0, today: Money? = nil) -> CopySkip? {
            if case .failure(let skip) = CopyPlanner.draft(
                copying: position, rules: CopyRules(), guards: CopyGuards(maxOpenCopies: 3, dailyLossLimit: 50),
                market: btcMarket, mark: mark, free: free, openCopies: open, realisedToday: today ?? zero) { return skip }
            return nil
        }
        #expect(plan(btc(), open: 3) == .openCopiesLimit(3))
        #expect(plan(btc(), today: Money(raw: -50_000_000)) == .dailyLossLimit(50))
        #expect(plan(btc(), free: money(5)) == .insufficientBalance)
        #expect(plan(btc(entry: 59_000)) == .chased(bps: 169))
        #expect(plan(btc(.short, entry: 59_000)) == nil)
        #expect(plan(btc(), today: Money(raw: -49_000_000)) == nil)
    }

    @Test("Leverage follows the trader within both the copier's and the market's cap")
    func leverage() throws {
        let btcMarket = try market(16)
        #expect(CopyPlanner.leverage(for: btc(leverage: 2.4), rules: CopyRules(maxLeverage: 5), market: btcMarket) == 2)
        #expect(CopyPlanner.leverage(for: btc(leverage: 40), rules: CopyRules(maxLeverage: 50), market: btcMarket) == 15)
        #expect(CopyPlanner.leverage(for: btc(leverage: nil), rules: CopyRules(), market: btcMarket) == 1)
    }
}
