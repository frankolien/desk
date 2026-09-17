import DeskMoney
import Foundation
import Testing

@testable import DeskFlow

private func position(
    _ symbol: String, _ side: Side = .long, notional: Double = 1_000, margin: Double = 100,
    mark: Double = 100, liquidation: Double? = nil, unrealised: Double = 0,
    source: RiskPosition.Source = .yours
) -> RiskPosition {
    RiskPosition(id: "\(symbol)-\(side)-\(notional)", symbol: symbol, side: side, notional: notional,
                 margin: margin, mark: mark, liquidation: liquidation, unrealised: unrealised, source: source)
}

@Suite("Risk book")
struct RiskBookTests {
    @Test("Equity is free collateral, what is committed, and what the book is up")
    func equity() {
        let book = RiskBook(positions: [position("BTC", margin: 100, unrealised: 25)], free: 400)
        #expect(book.equity == 525)
        #expect(book.margin == 100)
    }

    @Test("Gross exposure counts both sides, net cancels them")
    func exposure() {
        let book = RiskBook(
            positions: [position("BTC", .long, notional: 1_000), position("ETH", .short, notional: 600)],
            free: 500)
        #expect(book.grossNotional == 1_600)
        #expect(book.netNotional == 400)
        #expect(book.accountLeverage == 1_600 / book.equity)
    }

    @Test("A market held on both sides is reported as hedged rather than as double exposure")
    func hedged() throws {
        let book = RiskBook(
            positions: [position("BTC", .long, notional: 800), position("BTC", .short, notional: 500)],
            free: 100)
        let btc = try #require(book.exposures.first)
        #expect(btc.isHedged)
        #expect(btc.gross == 1_300)
        #expect(btc.net == 300)
    }

    @Test("Concentration and copy share are fractions of gross exposure")
    func concentrationAndCopies() throws {
        let book = RiskBook(positions: [
            position("BTC", notional: 750, source: .copy(trader: "0xa")),
            position("ETH", notional: 250),
        ], free: 0)
        #expect(try #require(book.concentration) == 0.75)
        #expect(try #require(book.copyShare) == 0.75)
        #expect(try #require(book.heaviestTrader).trader == "0xa")
    }

    @Test("The tightest position is the one with least room left, not the largest")
    func tightest() throws {
        let book = RiskBook(positions: [
            position("BTC", notional: 5_000, mark: 100, liquidation: 80),
            position("ETH", notional: 200, mark: 100, liquidation: 96),
        ], free: 0)
        #expect(try #require(book.tightest).symbol == "ETH")
        #expect(try #require(book.tightest?.roomToLiquidation) == 0.04)
    }

    @Test("A short gains when the market falls")
    func shortGains() {
        let book = RiskBook(positions: [position("BTC", .short, notional: 1_000, mark: 100, liquidation: 150)], free: 500)
        #expect(book.stress(move: -0.1).pnl == 100)
        #expect(book.stress(move: 0.1).pnl == -100)
    }

    @Test("A position cannot lose more than the collateral behind it")
    func lossIsCapped() {
        let book = RiskBook(
            positions: [position("BTC", .long, notional: 1_000, margin: 100, mark: 100, liquidation: 90)],
            free: 400)
        let crash = book.stress(move: -0.5)
        #expect(crash.pnl == -100)
        #expect(crash.liquidated.count == 1)
        #expect(crash.equity == 400)
    }

    @Test("A move that reaches the liquidation price liquidates, one that stops short does not")
    func liquidationBoundary() {
        let book = RiskBook(
            positions: [position("BTC", .long, notional: 1_000, margin: 100, mark: 100, liquidation: 90)],
            free: 0)
        #expect(!book.stress(move: -0.09).liquidates)
        #expect(book.stress(move: -0.10).liquidates)
    }

    @Test("The survivable fall stops at the first position that would liquidate")
    func survivable() throws {
        let book = RiskBook(positions: [
            position("BTC", .long, notional: 1_000, margin: 100, mark: 100, liquidation: 90),
            position("ETH", .long, notional: 500, margin: 100, mark: 100, liquidation: 60),
        ], free: 0)
        let fall = try #require(book.survivableFall())
        #expect(abs(fall - 0.099) < 0.0011)
    }

    @Test("An empty book has no leverage, no concentration and nothing to survive")
    func empty() {
        let book = RiskBook(positions: [], free: 250)
        #expect(book.isEmpty)
        #expect(book.accountLeverage == nil)
        #expect(book.concentration == nil)
        #expect(book.survivableFall() == nil)
        #expect(book.stress(move: -0.2).equity == 250)
    }
}
