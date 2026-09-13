import Testing
@testable import DeskMoney

/// One test per finding from the adversarial audit of 13 September 2026. The original
/// suite passed 19 of 19 while every case below was broken.
@Suite("Audit regressions")
struct AuditRegressionTests {

    // MARK: S1 — a crash reachable from the iOS emoji keyboard

    @Test("digits carrying combining scalars are rejected, not crashed on")
    func graphemeClustersAreRejected() {
        #expect(DecimalText.parse("5\u{FE0F}\u{20E3}", decimals: 2, rounding: .towardZero) == nil)
        #expect(Money(text: "12\u{FE0F}.5") == nil)
        for combining in ["\u{0300}", "\u{0308}", "\u{0489}", "\u{20E3}", "\u{200D}", "\u{1AB0}"] {
            #expect(DecimalText.parse("5" + combining, decimals: 2, rounding: .towardZero) == nil)
        }
    }

    @Test("alternate digit sets stay rejected")
    func alternateDigitSetsRejected() {
        for digits in ["٥", "５", "५", "๕"] {
            #expect(DecimalText.parse(digits, decimals: 2, rounding: .towardZero) == nil)
        }
    }

    // MARK: S2 — notional overflow on the mainnet-ETH shape

    @Test("a notional too large to represent declines instead of trapping")
    func notionalOverflowDeclines() throws {
        let price = try #require(Price(raw: Price.maxRaw, decimals: 2))
        let size = try #require(Size(raw: Size.maxRaw, decimals: 3))
        #expect(Money.notional(price: price, size: size, rounding: .towardZero) == nil)
    }

    @Test("decimals beyond what the module can compute with are refused at the door")
    func outOfRangeDecimalsRefused() {
        #expect(Price(raw: 1, decimals: 25) == nil)
        #expect(Size(raw: 1, decimals: 19) == nil)
        #expect(Price(raw: 1, decimals: 18) != nil)
    }

    // MARK: S3 — Int64.min and Int64.max reaching arithmetic

    @Test("wire values outside the safe range are refused")
    func extremeWireValuesRefused() {
        #expect(Money(raw: Int64.min) == nil)
        #expect(Money(raw: Int64.max) == nil)
        #expect(Money(raw: Money.maxRaw) != nil)
        #expect(Money(raw: -Money.maxRaw) != nil)
        #expect(Money(raw: Money.maxRaw + 1) == nil)
        #expect(Price(raw: Int64.min, decimals: 4) == nil)
    }

    @Test("the parser cannot mint a value the arithmetic would trap on")
    func parserCannotMintUnsafeValues() {
        #expect(Money(text: "-9223372036854.775808") == nil)
        #expect(Money(text: "9223372036854.775807") == nil)
    }

    @Test("arithmetic at the bound does not trap")
    func arithmeticAtTheBoundIsTotal() throws {
        let big = try #require(Money(raw: Money.maxRaw))
        _ = big + big
        _ = -big
        _ = Money.zero - big
        let price = try #require(Price(raw: Price.maxRaw, decimals: 4))
        _ = price + price
        _ = -price
    }

    // MARK: S4 — rescaling overflow

    @Test("widening that cannot fit declines instead of trapping")
    func rescaleWideningDeclines() throws {
        let small = try #require(Price(raw: 2, decimals: 0))
        #expect(small.rescaled(to: 18, rounding: .towardZero) == nil)

        let big = try #require(Price(raw: Price.maxRaw, decimals: 0))
        #expect(big.rescaled(to: 1, rounding: .towardZero) == nil)
    }

    @Test("a target scale out of range declines instead of trapping")
    func rescaleTargetOutOfRange() throws {
        let price = try #require(Price(raw: 125, decimals: 2))
        #expect(price.rescaled(to: 200, rounding: .towardZero) == nil)
        #expect(price.rescaled(to: 19, rounding: .towardZero) == nil)
    }

    @Test("narrowing always succeeds because the magnitude only shrinks")
    func rescaleNarrowingAlwaysWorks() throws {
        let big = try #require(Price(raw: Price.maxRaw, decimals: 18))
        #expect(big.rescaled(to: 0, rounding: .towardZero) != nil)
    }

    // MARK: S5 — a fabricated fee

    @Test("a fee rate outside nought to one hundred percent is refused")
    func nonsenseFeeRateRefused() throws {
        let notional = try #require(Money(text: "1000.000000"))
        #expect(notional.fee(rateInMicros: 2_000_000) == nil)
        #expect(notional.fee(rateInMicros: -1) == nil)
        #expect(notional.fee(rateInMicros: 1_000_000) != nil)
        #expect(notional.fee(rateInMicros: 0)?.isZero == true)
    }

    // MARK: S6 — a real balance displayed as zero

    @Test("display never renders a real balance as zero")
    func displayNeverFabricatesZero() throws {
        let million = try #require(Money(text: "1000000.000000"))
        #expect(million.display(fractionDigits: 13).hasPrefix("1,000,000."))
        #expect(million.display(fractionDigits: 18).hasPrefix("1,000,000."))

        // The live case: a Scaled with small decimals, a large raw, default precision.
        let price = try #require(Price(raw: Price.maxRaw, decimals: 0))
        #expect(price.display(fractionDigits: 2) == "1,000,000,000,000,000,000.00")
    }

    @Test("display pads rather than recomputing when asked for more places")
    func displayWidensByPadding() throws {
        let amount = try #require(Money(text: "1.5"))
        #expect(amount.display(fractionDigits: 8) == "1.50000000")
        let whole = try #require(Size(raw: 7, decimals: 0))
        #expect(whole.display(fractionDigits: 3) == "7.000")
    }

    // MARK: S7 — a fee that flattered the short

    @Test("a short and a long pay the same fee on the same notional")
    func feeIsSymmetricAcrossSides() throws {
        let price = try #require(Price(text: "2466.40", decimals: 2, rounding: .towardZero))
        let long = try #require(Size(text: "1.503", decimals: 3, rounding: .towardZero))
        let short = try #require(Size(text: "-1.503", decimals: 3, rounding: .towardZero))

        let longNotional = try #require(Money.notional(price: price, size: long, rounding: .towardZero))
        let shortNotional = try #require(Money.notional(price: price, size: short, rounding: .towardZero))
        #expect(shortNotional.isNegative)

        let longFee = try #require(longNotional.fee(rateInMicros: 690))
        let shortFee = try #require(shortNotional.fee(rateInMicros: 690))

        #expect(longFee == shortFee)
        #expect(!shortFee.isNegative)
        // 3706.999200 * 690/1e6 = 2.557829448, taken away from zero so the venue's
        // fee is never quoted lower than it will be.
        #expect(longFee.text == "2.557830")
    }

    // MARK: S8 — the rule belongs to the operation

    @Test("a typed size can only round toward zero")
    func typedSizeTruncates() throws {
        let long = try #require(Size(typed: "0.0150009", decimals: 5))
        #expect(long.text == "0.01500")
        let short = try #require(Size(typed: "-0.0150009", decimals: 5))
        #expect(short.text == "-0.01500")   // not -0.01501: floor would grow the short
    }

    @Test("a buy price rounds down to the grid and a sell price rounds up")
    func buyAndSellPricesRoundAgainstTheTrader() throws {
        #expect(try #require(Price(buying: "67412.37", decimals: 1)).text == "67412.3")
        #expect(try #require(Price(selling: "67412.31", decimals: 1)).text == "67412.4")
    }

    // MARK: S9 — leading zeros consuming the width budget

    @Test("a zero-padded field is parsed by its value, not its width")
    func leadingZerosDoNotConsumeTheBudget() {
        let padded = String(repeating: "0", count: 40) + "1"
        #expect(DecimalText.parse(padded, decimals: 6, rounding: .towardZero) == 1_000_000)
    }
}
