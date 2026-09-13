import DeskMoney
import Foundation
import Testing

@testable import DeskPerpl

@Suite("The number before the signature")
struct OrderQuoteTests {
    private func btc() throws -> Market {
        let url = try #require(Bundle.module.url(forResource: "Context-testnet", withExtension: "json"))
        let context = try JSONDecoder().decode(PerplContext.self, from: try Data(contentsOf: url))
        return try #require(context.market(id: 16))
    }

    /// 0.01 BTC long at 10x, marked at 76,719.0. Every figure computed by hand against
    /// the live market configuration and pinned here.
    private func worked() throws -> OrderQuote {
        let market = try btc()
        return try OrderQuote.forMarket(
            market, side: .long,
            size: #require(market.size(1_000)),
            price: #require(market.price(767_190)),
            leverageHundredths: 1_000,
            pricedAt: ContinuousClock.now)
    }

    @Test("Every figure on the ticket is the one that was computed by hand")
    func workedExample() throws {
        let quote = try worked()
        #expect(quote.notional.text == "767.190000")
        #expect(quote.margin.text == "76.719000")
        // 767.19 at 345 micros taker, away from zero.
        #expect(quote.fee.text == "0.264681")
        #expect(quote.total.text == "76.983681")
        #expect(quote.liquidationPrice.raw == 721_424)
    }

    @Test("The total is what leaves collateral, not the margin alone")
    func totalIncludesFee() throws {
        let quote = try worked()
        #expect(quote.total.raw == quote.margin.raw + quote.fee.raw)
        // A user shown only the margin is surprised by the difference at exactly the
        // moment they can least afford to be.
        #expect(quote.total.raw > quote.margin.raw)
    }

    @Test("The liquidation buffer at the ceiling is the 2.67% the ticket must not hide")
    func bufferAtCeiling() throws {
        let market = try btc()
        let quote = try OrderQuote.forMarket(
            market, side: .long,
            size: #require(market.size(1_000)),
            price: #require(market.price(767_190)),
            leverageHundredths: market.config.initialMarginFraction)
        #expect(quote.liquidationDistanceMicros == 26_666)
        #expect(try worked().liquidationDistanceMicros == 60_000)
    }

    @Test("Liquidation sits below entry for a long and above it for a short")
    func liquidationSide() throws {
        let market = try btc()
        let short = try OrderQuote.forMarket(
            market, side: .short,
            size: #require(market.size(1_000)),
            price: #require(market.price(767_190)),
            leverageHundredths: 1_000)
        #expect(try worked().liquidationPrice.raw < 767_190)
        #expect(short.liquidationPrice.raw > 767_190)
    }

    @Test("The fee is deducted from what backs the position, which understates headroom")
    func conservativeBacking() throws {
        // Whether the venue takes the fee from position collateral or free collateral is
        // undocumented and moves this number. Deducting it means that if we are wrong,
        // the real liquidation is further away than shown — never nearer.
        let market = try btc()
        let size = try #require(market.size(1_000))
        let price = try #require(market.price(767_190))
        let quote = try worked()
        let ignoringFee = try #require(Margin.liquidationPrice(
            entry: price, size: size, collateral: quote.margin,
            maintenanceMarginFraction: market.config.maintenanceMarginFraction, side: .long))
        #expect(quote.liquidationPrice.raw > ignoringFee.raw)
    }

    @Test("A maker quote is not a taker quote")
    func makerVersusTaker() throws {
        let market = try btc()
        let maker = try OrderQuote.forMarket(
            market, side: .long, size: #require(market.size(1_000)),
            price: #require(market.price(767_190)), leverageHundredths: 1_000, isMaker: true)
        // 45 micros against 345: quoting maker on an order that crosses understates the
        // cost by nearly eight times.
        #expect(maker.fee.text == "0.034524")
        #expect(try worked().fee.raw > maker.fee.raw * 7)
    }

    @Test("A quote expires after a minute and is re-priced rather than sent")
    func expiry() throws {
        let base = ContinuousClock.now
        let market = try btc()
        let quote = try OrderQuote.forMarket(
            market, side: .long, size: #require(market.size(1_000)),
            price: #require(market.price(767_190)), leverageHundredths: 1_000, pricedAt: base)
        #expect(quote.hasExpired(at: base.advanced(by: .seconds(59))) == false)
        #expect(quote.hasExpired(at: base.advanced(by: .seconds(60))))
        #expect(quote.age(at: base.advanced(by: .seconds(30))) == .seconds(30))
    }

    @Test("Affordability is checked against the total")
    func affordability() throws {
        let quote = try worked()
        #expect(quote.isAffordable(freeCollateral: try #require(Money(text: "77"))))
        #expect(quote.isAffordable(freeCollateral: quote.total))
        // Enough for the margin but not the fee.
        #expect(quote.isAffordable(freeCollateral: quote.margin) == false)
    }

    @Test("Inputs that cannot be quoted are refused")
    func refusals() throws {
        let market = try btc()
        let size = try #require(market.size(1_000))
        let price = try #require(market.price(767_190))

        #expect(throws: OrderQuote.Failure.leverageOutOfRange(1_600, max: 1_500)) {
            try OrderQuote.forMarket(market, side: .long, size: size, price: price, leverageHundredths: 1_600)
        }
        #expect(throws: OrderQuote.Failure.leverageOutOfRange(99, max: 1_500)) {
            try OrderQuote.forMarket(market, side: .long, size: size, price: price, leverageHundredths: 99)
        }
        #expect(throws: OrderQuote.Failure.priceMustBePositive) {
            try OrderQuote.forMarket(
                market, side: .long, size: size, price: #require(Price(raw: 0, decimals: 1)),
                leverageHundredths: 1_000)
        }
        #expect(throws: OrderQuote.Failure.scaleMismatch) {
            try OrderQuote.forMarket(
                market, side: .long, size: #require(Size(raw: 1_000, decimals: 3)), price: price,
                leverageHundredths: 1_000)
        }
    }
}
