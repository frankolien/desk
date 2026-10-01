import Testing
@testable import DeskMoney

@Suite("Margin")
struct MarginTests {
    let priceDecimals: UInt8 = 1
    let sizeDecimals: UInt8 = 5

    func price(_ text: String) throws -> Price {
        try #require(Price(text: text, decimals: priceDecimals, rounding: .towardZero))
    }
    func size(_ text: String) throws -> Size {
        try #require(Size(typed: text, decimals: sizeDecimals))
    }
    func money(_ text: String) throws -> Money {
        try #require(Money(text: text))
    }

    // Perpl's example: a $100,000 BTC long at 10x with 4% maintenance liquidates at $94,000; the
    // mark-based form their prose implies gives $93,750, which is how the two are told apart.
    @Test("Perpl's published example lands on 94,000")
    func perplWorkedExample() throws {
        let liquidation = try #require(Margin.liquidationPrice(
            entry: price("100000.0"),
            size: size("1.00000"),
            collateral: money("10000.0"),
            maintenanceMarginFraction: 2500,
            side: .long))
        #expect(liquidation.text == "94000.0")
        #expect(liquidation.text != "93750.0")
    }

    @Test("a short liquidates symmetrically above entry")
    func shortIsSymmetric() throws {
        let liquidation = try #require(Margin.liquidationPrice(
            entry: price("100000.0"),
            size: size("1.00000"),
            collateral: money("10000.0"),
            maintenanceMarginFraction: 2500,
            side: .short))
        #expect(liquidation.text == "106000.0")
    }

    // Does not divide exactly, so it pins the rounding direction: a short's liquidation price rounds
    // down (§9), so the screen never shows more room than the position has.
    @Test("a remainder rounds against the trader on both sides")
    func roundingIsAlwaysAgainstTheTrader() throws {
        let entry = try #require(Price(raw: 767_190, decimals: 1))
        let held = try #require(Size(raw: 1_000, decimals: 5))
        let backing = try #require(Money(raw: 76_454_319))
        let short = try #require(Margin.liquidationPrice(
            entry: entry, size: held, collateral: backing,
            maintenanceMarginFraction: 2500, side: .short))
        #expect(short.raw == 812_956)
        #expect(short.raw != 812_958)

        let long = try #require(Margin.liquidationPrice(
            entry: entry, size: held, collateral: backing,
            maintenanceMarginFraction: 2500, side: .long))
        #expect(long.raw == 721_424)
    }

    @Test("liquidation distance is one over leverage minus maintenance")
    func distanceCollapses() {
        #expect(Margin.liquidationDistanceMicros(
            leverageHundredths: 1000, maintenanceMarginFraction: 2500) == 60_000)
        #expect(Margin.liquidationDistanceMicros(
            leverageHundredths: 1500, maintenanceMarginFraction: 2500) == 26_666)
        #expect(Margin.liquidationDistanceMicros(
            leverageHundredths: 100, maintenanceMarginFraction: 2500) == 960_000)
    }

    @Test("the distance agrees with the liquidation price it implies")
    func distanceAgreesWithPrice() throws {
        let entry = try price("100000.0")
        let liquidation = try #require(Margin.liquidationPrice(
            entry: entry, size: try size("1.00000"), collateral: try money("10000.0"),
            maintenanceMarginFraction: 2500, side: .long))
        let micros = try #require(Margin.liquidationDistanceMicros(
            leverageHundredths: 1000, maintenanceMarginFraction: 2500))
        #expect(entry.raw - liquidation.raw == entry.raw * Int64(micros) / 1_000_000)
    }

    @Test("leverage beyond the market's ceiling leaves no room at all")
    func leverageBeyondCeiling() {
        #expect(Margin.liquidationDistanceMicros(
            leverageHundredths: 2500, maintenanceMarginFraction: 2500) == nil)
        #expect(Margin.liquidationDistanceMicros(
            leverageHundredths: 5000, maintenanceMarginFraction: 2500) == nil)
    }

    @Test("initial margin rounds up so it never understates what is needed")
    func initialMargin() throws {
        #expect(try #require(Margin.initialMargin(
            notional: money("1000.0"), leverageHundredths: 1000)).text == "100.000000")
        #expect(try #require(Margin.initialMargin(
            notional: money("1000.0"), leverageHundredths: 100)).text == "1000.000000")
        #expect(try #require(Margin.initialMargin(
            notional: money("1000.0"), leverageHundredths: 1500)).text == "66.666667")
    }

    @Test("a short's margin is taken on the magnitude")
    func marginOfShort() throws {
        #expect(try #require(Margin.initialMargin(
            notional: money("-1000.0"), leverageHundredths: 1000)).text == "100.000000")
    }

    @Test("unrealised profit uses the mark and carries its sign")
    func unrealisedPnL() throws {
        let entry = try price("66980.1")
        let mark = try price("67412.3")
        let size = try size("0.01480")

        let long = try #require(Margin.unrealisedPnL(
            entry: entry, mark: mark, size: size, side: .long))
        #expect(long.display() == "6.39")

        let short = try #require(Margin.unrealisedPnL(
            entry: entry, mark: mark, size: size, side: .short))
        #expect(short.isNegative)
        #expect(short == -long)
    }

    @Test("degenerate inputs decline rather than trap")
    func degenerateInputs() throws {
        #expect(Margin.liquidationPrice(
            entry: try price("100.0"), size: try size("0.00000"),
            collateral: try money("10.0"), maintenanceMarginFraction: 2500, side: .long) == nil)
        #expect(Margin.liquidationPrice(
            entry: try price("100.0"), size: try size("1.00000"),
            collateral: try money("10.0"), maintenanceMarginFraction: 0, side: .long) == nil)
        #expect(Margin.initialMargin(notional: try money("10.0"), leverageHundredths: 0) == nil)
        #expect(Margin.liquidationPrice(
            entry: try price("100.0"), size: try size("1.00000"),
            collateral: try money("1000.0"), maintenanceMarginFraction: 2500, side: .long) == nil)
    }
}
