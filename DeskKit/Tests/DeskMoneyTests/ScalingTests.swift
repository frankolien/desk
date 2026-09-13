import Testing
@testable import DeskMoney

/// The scaling rules from docs/04-algorithms.md.
@Suite("Scaling")
struct ScalingTests {

    // MARK: - The trap that costs a factor of ten

    @Test("notional is exact when the decimals sum to six")
    func notionalWhenDecimalsSumToSix() throws {
        let price = try #require(Price(text: "67412.3", decimals: 1, rounding: .towardZero))
        let size = try #require(Size(text: "0.01480", decimals: 5, rounding: .towardZero))

        let notional = try #require(Money.notional(price: price, size: size, rounding: .towardZero))

        // 67412.3 * 0.0148 = 997.70204
        #expect(notional.text == "997.702040")
        #expect(notional.raw == price.raw * size.raw) // the shortcut, only valid here
    }

    @Test("notional corrects when the decimals sum to five")
    func notionalWhenDecimalsSumToFive() throws {
        let price = try #require(Price(text: "2466.40", decimals: 2, rounding: .towardZero))
        let size = try #require(Size(text: "1.500", decimals: 3, rounding: .towardZero))

        let notional = try #require(Money.notional(price: price, size: size, rounding: .towardZero))

        // 2466.40 * 1.5 = 3699.60
        #expect(notional.text == "3699.600000")
        // And the shortcut everyone reaches for is ten times too small.
        #expect(notional.raw == price.raw * size.raw * 10)
    }

    @Test("notional corrects when the decimals exceed six")
    func notionalWhenDecimalsExceedSix() throws {
        let price = try #require(Price(text: "1.23456", decimals: 5, rounding: .towardZero))
        let size = try #require(Size(text: "2.0000", decimals: 4, rounding: .towardZero))

        let notional = try #require(Money.notional(price: price, size: size, rounding: .towardZero))
        #expect(notional.text == "2.469120")
    }

    @Test("notional is signed correctly for a short")
    func notionalOfNegativeSize() throws {
        let price = try #require(Price(text: "100.0", decimals: 1, rounding: .towardZero))
        let size = try #require(Size(text: "-2.50000", decimals: 5, rounding: .towardZero))

        let notional = try #require(Money.notional(price: price, size: size, rounding: .towardZero))
        #expect(notional.text == "-250.000000")
    }

    // MARK: - Rounding, including the floor-versus-truncate trap

    @Test("floor and towardZero differ below zero")
    func floorVersusTruncateOnNegatives() {
        #expect(DecimalText.parse("-1.5", decimals: 0, rounding: .towardZero) == -1)
        #expect(DecimalText.parse("-1.5", decimals: 0, rounding: .floor) == -2)
        #expect(DecimalText.parse("-1.5", decimals: 0, rounding: .ceiling) == -1)
        #expect(DecimalText.parse("-1.5", decimals: 0, rounding: .awayFromZero) == -2)

        #expect(DecimalText.parse("1.5", decimals: 0, rounding: .towardZero) == 1)
        #expect(DecimalText.parse("1.5", decimals: 0, rounding: .floor) == 1)
        #expect(DecimalText.parse("1.5", decimals: 0, rounding: .ceiling) == 2)
        #expect(DecimalText.parse("1.5", decimals: 0, rounding: .awayFromZero) == 2)
    }

    @Test("rounding a magnitude smaller than one unit keeps its sign")
    func roundingBelowOneUnit() {
        #expect(DecimalText.parse("-0.4", decimals: 0, rounding: .floor) == -1)
        #expect(DecimalText.parse("-0.4", decimals: 0, rounding: .ceiling) == 0)
        #expect(DecimalText.parse("0.4", decimals: 0, rounding: .ceiling) == 1)
        #expect(DecimalText.parse("0.4", decimals: 0, rounding: .floor) == 0)
    }

    @Test("an exact value is untouched by every rounding mode")
    func exactValuesAreStable() {
        for mode in Rounding.allCases {
            #expect(DecimalText.parse("-2.500", decimals: 3, rounding: mode) == -2500)
            #expect(DecimalText.parse("2.5", decimals: 1, rounding: mode) == 25)
        }
    }

    // MARK: - Text, in both directions

    @Test("rendering keeps every decimal place the scale carries")
    func renderingIsExact() {
        #expect(DecimalText.render(raw: 50, decimals: 6) == "0.000050")
        #expect(DecimalText.render(raw: -50, decimals: 6) == "-0.000050")
        #expect(DecimalText.render(raw: 674123, decimals: 1) == "67412.3")
        #expect(DecimalText.render(raw: 0, decimals: 6) == "0.000000")
        #expect(DecimalText.render(raw: 0, decimals: 0) == "0")
        #expect(DecimalText.render(raw: -7, decimals: 0) == "-7")
        #expect(DecimalText.render(raw: 1, decimals: 1) == "0.1")
    }

    @Test("the prices a Double pipeline loses a tick on survive exactly")
    func pricesThatBreakFloatingPoint() {
        #expect(DecimalText.parse("0.29", decimals: 2, rounding: .towardZero) == 29)
        #expect(DecimalText.parse("4.35", decimals: 2, rounding: .towardZero) == 435)
        #expect(DecimalText.parse("0.07", decimals: 2, rounding: .towardZero) == 7)
        #expect(DecimalText.parse("1.005", decimals: 3, rounding: .towardZero) == 1005)
        #expect(DecimalText.parse("8.165", decimals: 3, rounding: .towardZero) == 8165)
    }

    @Test("text survives a round trip at every scale it can hold")
    func roundTrip() throws {
        for decimals in UInt8(0)...UInt8(9) {
            for raw in [Int64(0), 1, -1, 999_999, -999_999, 1_234_567_890] {
                let rendered = DecimalText.render(raw: raw, decimals: decimals)
                let parsed = DecimalText.parse(rendered, decimals: decimals, rounding: .towardZero)
                #expect(parsed == raw, "round trip failed for \(raw) at \(decimals) decimals")
            }
        }
    }

    @Test("forms a person or a venue actually sends are accepted")
    func acceptedForms() {
        #expect(DecimalText.parse("0.", decimals: 2, rounding: .towardZero) == 0)
        #expect(DecimalText.parse(".5", decimals: 2, rounding: .towardZero) == 50)
        #expect(DecimalText.parse("5", decimals: 2, rounding: .towardZero) == 500)
        #expect(DecimalText.parse("+5", decimals: 2, rounding: .towardZero) == 500)
        #expect(DecimalText.parse("  5.25  ", decimals: 2, rounding: .towardZero) == 525)
        #expect(DecimalText.parse("0005.25", decimals: 2, rounding: .towardZero) == 525)
        #expect(DecimalText.parse("-0", decimals: 2, rounding: .towardZero) == 0)
    }

    @Test("malformed text is rejected rather than coerced to zero")
    func rejectedForms() {
        // Hex that fails to parse must never become zero: a zero here is a number
        // nobody agreed to. Same rule as failable hex decoding on the chain layer.
        #expect(DecimalText.parse("", decimals: 2, rounding: .towardZero) == nil)
        #expect(DecimalText.parse(".", decimals: 2, rounding: .towardZero) == nil)
        #expect(DecimalText.parse("-", decimals: 2, rounding: .towardZero) == nil)
        #expect(DecimalText.parse("1.2.3", decimals: 2, rounding: .towardZero) == nil)
        #expect(DecimalText.parse("1e5", decimals: 2, rounding: .towardZero) == nil)
        #expect(DecimalText.parse("0x10", decimals: 2, rounding: .towardZero) == nil)
        #expect(DecimalText.parse("abc", decimals: 2, rounding: .towardZero) == nil)
        #expect(DecimalText.parse("1,000", decimals: 2, rounding: .towardZero) == nil)
        #expect(DecimalText.parse("NaN", decimals: 2, rounding: .towardZero) == nil)
        #expect(DecimalText.parse("Infinity", decimals: 2, rounding: .towardZero) == nil)
    }

    @Test("a value too large for the storage is refused, not wrapped")
    func overflowIsRefused() {
        #expect(DecimalText.parse("99999999999999999999", decimals: 6, rounding: .towardZero) == nil)
        // Beyond the wire bound of 10^18 raw, which is a trillion AUSD.
        #expect(Money(text: "10000000000000.000000") == nil)
        #expect(Money(text: "1000000000000.000000") != nil)
    }

    // MARK: - Fees

    @Test("a taker fee in micros")
    func takerFee() throws {
        let notional = try #require(Money(text: "1000.000000"))
        // 1000 * 345/1_000_000 = 0.345
        #expect(try #require(notional.fee(rateInMicros: 345)).text == "0.345000")
        // Mainnet taker 690 -> 6.9 bps
        #expect(try #require(notional.fee(rateInMicros: 690)).text == "0.690000")
        // Testnet maker 45 -> 0.45 bps
        #expect(try #require(notional.fee(rateInMicros: 45)).text == "0.045000")
    }

    @Test("a fee is never understated, however small")
    func feeIsNeverUnderstated() throws {
        let dust = try #require(Money(text: "0.000001"))
        // A hair of a fee is still a fee: it rounds away from zero, not to nothing.
        #expect(try #require(dust.fee(rateInMicros: 345)).raw == 1)
    }

    // MARK: - Display

    @Test("display groups thousands and trims to the requested places")
    func display() throws {
        let amount = try #require(Money(text: "1282.187654"))
        #expect(amount.display(fractionDigits: 2) == "1,282.18")
        #expect(amount.display(fractionDigits: 0) == "1,282")
        #expect(amount.display(fractionDigits: 2, grouping: " ", point: ",") == "1 282,18")

        let negative = try #require(Money(text: "-1234567.5"))
        #expect(negative.display(fractionDigits: 2) == "-1,234,567.50")

        let small = try #require(Money(text: "0.5"))
        #expect(small.display(fractionDigits: 2) == "0.50")
    }

    @Test("a displayed gain is never rounded up")
    func displayedGainNeverFlatters() throws {
        let gain = try #require(Money(text: "42.189999"))
        #expect(gain.display(fractionDigits: 2) == "42.18")
    }

    // MARK: - Scale mechanics

    @Test("rescaling widens exactly and narrows by the given rule")
    func rescaling() throws {
        let price = try #require(Price(text: "1.25", decimals: 2, rounding: .towardZero))
        #expect(price.rescaled(to: 5, rounding: .towardZero)?.text == "1.25000")
        #expect(price.rescaled(to: 1, rounding: .towardZero)?.text == "1.2")
        #expect(price.rescaled(to: 1, rounding: .ceiling)?.text == "1.3")
        #expect(price.rescaled(to: 2, rounding: .towardZero)?.raw == price.raw)
    }

    @Test("arithmetic holds within one scale")
    func arithmetic() throws {
        let a = try #require(Size(text: "1.50000", decimals: 5, rounding: .towardZero))
        let b = try #require(Size(text: "0.25000", decimals: 5, rounding: .towardZero))
        #expect((a + b).text == "1.75000")
        #expect((a - b).text == "1.25000")
        #expect((-a).text == "-1.50000")
        #expect(b < a)
        #expect(a.zeroed().isZero)
    }
}
