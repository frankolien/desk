import Testing
@testable import DeskMoney

/// Checked against Perpl's own published worked example, which its prose contradicts.
@Suite("Margin")
struct MarginTests {
    // BTC on testnet.
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

    // Perpl's example: a $100,000 BTC long at 10x ($10,000 margin) with 4% maintenance
    // liquidates on a 6% drop, at $94,000. The mark-based form their prose implies gives
    // $93,750 — which is how you tell the two apart.
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

    // Both worked examples above divide exactly, so neither can see which way a remainder
    // goes. This one does not divide, and the direction is the whole point: §9 says a
    // short's liquidation price rounds down, because for a short a lower price is less
    // headroom, and the screen must never show more room than the position has.
    @Test("a remainder rounds against the trader on both sides")
    func roundingIsAlwaysAgainstTheTrader() throws {
        // 0.01 BTC short at 76,719.0 against 76.454319 AUSD, 4% maintenance.
        let entry = try #require(Price(raw: 767_190, decimals: 1))
        let held = try #require(Size(raw: 1_000, decimals: 5))
        let backing = try #require(Money(raw: 76_454_319))
        let short = try #require(Margin.liquidationPrice(
            entry: entry, size: held, collateral: backing,
            maintenanceMarginFraction: 2500, side: .short))
        // E - ceil(E*100/mm) + floor(C/S) = 767190 - 30688 + 76454.
        #expect(short.raw == 812_956)
        #expect(short.raw != 812_958)

        // The long of the same shape still rounds up, towards the mark.
        let long = try #require(Margin.liquidationPrice(
            entry: entry, size: held, collateral: backing,
            maintenanceMarginFraction: 2500, side: .long))
        #expect(long.raw == 721_424)
    }

    // C/(S*E) is exactly 1/L, so the distance collapses to 1/L - mm.
    @Test("liquidation distance is one over leverage minus maintenance")
    func distanceCollapses() {
        // 10x with 4% maintenance: 10% - 4% = 6%.
        #expect(Margin.liquidationDistanceMicros(
            leverageHundredths: 1000, maintenanceMarginFraction: 2500) == 60_000)
        // BTC's 15x ceiling: 6.667% - 4% = 2.67%. The number the ticket must not hide.
        #expect(Margin.liquidationDistanceMicros(
            leverageHundredths: 1500, maintenanceMarginFraction: 2500) == 26_666)
        // 1x is a long way from trouble.
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
        // 6% of 100,000 is 6,000, so 94,000.
        #expect(entry.raw - liquidation.raw == entry.raw * Int64(micros) / 1_000_000)
    }

    @Test("leverage beyond the market's ceiling leaves no room at all")
    func leverageBeyondCeiling() {
        // 25x against a 4% maintenance is already inside the liquidation band.
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
        // 1000/15 is 66.666..., which must round up.
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
        // Collateral larger than the position means no liquidation price exists.
        #expect(Margin.liquidationPrice(
            entry: try price("100.0"), size: try size("1.00000"),
            collateral: try money("1000.0"), maintenanceMarginFraction: 2500, side: .long) == nil)
    }
}
