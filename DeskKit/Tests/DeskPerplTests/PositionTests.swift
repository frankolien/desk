import DeskMoney
import Foundation
import Testing

@testable import DeskPerpl

/// A position frame shaped the way the venue sends one: two-letter keys, amounts as
/// strings of raw scaled integers, small numbers as JSON numbers.
private func positionJSON(
    side: Int = 1,
    collateral: String = "10000000000",
    entry: Int64 = 1_000_000,
    residue: Int? = nil,
    size: Int64 = 1_000_000,
    leverage: Int = 1000,
    exit: Int64? = nil
) -> Data {
    var fields: [String] = [
        #""mkt":16"#, #""acc":42"#, #""pid":"7""#, #""sd":\#(side)"#,
        #""c":"\#(collateral)""#, #""ep":\#(entry)"#, #""s":\#(size)"#,
        #""lv":\#(leverage)"#, #""efs":"0""#, #""xfs":"0""#, #""fee":"0""#, #""st":1"#,
    ]
    if let residue { fields.append(#""epr":\#(residue)"#) }
    if let exit { fields.append(#""xp":\#(exit)"#) }
    return Data("{\(fields.joined(separator: ","))}".utf8)
}

private let btc = MarketConfig(
    isOpen: true, priceDecimals: 1, sizeDecimals: 5,
    initialMarginFraction: 1500, maintenanceMarginFraction: 2500,
    makerFeeMicros: 0, takerFeeMicros: 0, makerFeeTiersMicros: [], takerFeeTiersMicros: [])

@Suite("Decoding a position")
struct PerplPositionTests {
    /// The trap in the venue's own wording. It calls these fields "decimal string", which
    /// reads as "a number with a point in it". They are raw integers at the collateral's
    /// six decimals, so `"100000000"` is one hundred AUSD — not one hundred million.
    /// Reading it the other way is wrong by a factor of a million, which would show a
    /// liquidated account as solvent.
    @Test("An amount string is raw units, not a decimal figure")
    func amountsAreRawUnits() throws {
        let position = try JSONDecoder().decode(
            PerplPosition.self, from: positionJSON(collateral: "100000000"))
        #expect(position.collateralRaw == 100_000_000)
        #expect(Money(raw: position.collateralRaw)?.display() == "100.00")
    }

    @Test("Side one is long and side two is short")
    func sides() throws {
        let long = try JSONDecoder().decode(PerplPosition.self, from: positionJSON(side: 1))
        let short = try JSONDecoder().decode(PerplPosition.self, from: positionJSON(side: 2))
        #expect(long.side == .long)
        #expect(short.side == .short)
    }

    /// `PositionStatus`'s numeric values are not published, so openness is keyed on the
    /// exit price — which is only written when a position closes. Marked here because it
    /// is the one inference in the decoder and it must not become folklore.
    @Test("A position with an exit price is closed")
    func openness() throws {
        let open = try JSONDecoder().decode(PerplPosition.self, from: positionJSON())
        let closed = try JSONDecoder().decode(PerplPosition.self, from: positionJSON(exit: 990_000))
        #expect(open.isOpen)
        #expect(!closed.isOpen)
    }

    @Test("A frame with no positions decodes as none, not as a failure")
    func emptyFrame() throws {
        let frame = try JSONDecoder().decode(PositionsFrame.self, from: Data(#"{"mt":26}"#.utf8))
        #expect(frame.positions.isEmpty)
    }

    @Test("A snapshot carries its array")
    func snapshot() throws {
        let body = Data(#"{"mt":26,"d":[\#(String(decoding: positionJSON(), as: UTF8.self))]}"#.utf8)
        let frame = try JSONDecoder().decode(PositionsFrame.self, from: body)
        #expect(frame.positions.count == 1)
        #expect(frame.positions.first?.marketID == 16)
    }

    /// `b` is the balance and `lb` the part locked behind open positions, so what is free
    /// is the difference. Rendering `b` as "available" overstates it by exactly the margin
    /// backing the user's own position.
    @Test("Free collateral is balance less locked")
    func accountFreeBalance() throws {
        let body = Data(#"{"mt":21,"in":12,"id":42,"fw":true,"fr":false,"b":"1500000000","lb":"500000000"}"#.utf8)
        let account = try JSONDecoder().decode(PerplAccount.self, from: body)
        #expect(account.balance?.display() == "1,500.00")
        #expect(account.locked?.display() == "500.00")
        #expect(account.free?.display() == "1,000.00")
        #expect(account.allowsForwarding)
    }
}

@Suite("Position figures")
struct PositionFiguresTests {
    private func figures(
        side: Int = 1,
        entry: Int64 = 1_000_000,
        residue: Int? = nil,
        markRaw: Int64,
        collateral: String = "10000000000",
        size: Int64 = 100_000
    ) throws -> PositionFigures {
        let position = try JSONDecoder().decode(
            PerplPosition.self,
            from: positionJSON(side: side, collateral: collateral, entry: entry,
                               residue: residue, size: size))
        let mark = try #require(Price(raw: markRaw, decimals: btc.priceDecimals))
        return try #require(PositionFigures(position: position, market: btc, mark: mark))
    }

    @Test("A long in profit reports a profit, and a short the opposite")
    func directionOfProfit() throws {
        let long = try figures(side: 1, markRaw: 1_100_000)
        let short = try figures(side: 2, markRaw: 1_100_000)
        #expect(long.isProfit)
        #expect(!short.isProfit)
        #expect(long.unrealisedPnL.raw == -short.unrealisedPnL.raw)
    }

    /// The residue is a Q16 fraction of one tick. Ignoring it does not average out — it
    /// leans the same way on every position, which reads to a user as the app being wrong
    /// rather than as rounding.
    @Test("The entry residue moves the figure, and in the right direction")
    func residueIsApplied() throws {
        let without = try figures(markRaw: 1_100_000)
        // Half a tick further up means the long entered higher, so it has made less.
        let with = try figures(residue: 32_768, markRaw: 1_100_000)
        #expect(with.unrealisedPnL < without.unrealisedPnL)
    }

    @Test("A zero residue agrees with the plain calculation")
    func residueZeroMatches() throws {
        let entry = try #require(Price(raw: 1_000_000, decimals: btc.priceDecimals))
        let mark = try #require(Price(raw: 1_100_000, decimals: btc.priceDecimals))
        let size = try #require(Size(raw: 100_000, decimals: btc.sizeDecimals))
        let plain = Margin.unrealisedPnL(entry: entry, mark: mark, size: size, side: .long)
        let withResidue = Margin.unrealisedPnL(
            entry: entry, residueQ16: 0, mark: mark, size: size, side: .long)
        #expect(plain == withResidue)
    }

    /// The number that matters once someone is in a position: not how much room they had
    /// at entry, but how much is left now.
    @Test("Liquidation distance shrinks as the price moves against the position")
    func distanceShrinks() throws {
        let comfortable = try figures(markRaw: 1_050_000)
        let uncomfortable = try figures(markRaw: 970_000)
        let a = try #require(comfortable.liquidationDistanceMicros)
        let b = try #require(uncomfortable.liquidationDistanceMicros)
        #expect(b < a)
    }

    /// A mark already past the liquidation price is no room at all. A negative distance
    /// rendered as "-3% away" is a sentence with no meaning.
    @Test("Past the liquidation price the distance is zero, never negative")
    func neverNegative() throws {
        let figures = try figures(markRaw: 1_000)
        #expect(figures.liquidationDistanceMicros == 0)
    }

    @Test("Return is measured against the collateral backing this position")
    func returnOnMargin() throws {
        // 1 BTC-equivalent at 100,000.0 entry, 10,000 AUSD collateral. A move to 110,000.0
        // on a size of 1.00000 is 10,000 AUSD of profit, which is 100% on margin.
        let figures = try figures(
            entry: 1_000_000, markRaw: 1_100_000, collateral: "10000000000", size: 100_000)
        #expect(figures.unrealisedPnL.display() == "10,000.00")
        #expect(figures.returnOnMarginMicros == 1_000_000)
    }

    /// Perpl's own published worked example: a $100,000 BTC long at 10x with 4%
    /// maintenance liquidates at $94,000. Pinned so a change to the margin formula fails
    /// here rather than on a user's position.
    @Test("The venue's published liquidation example still holds")
    func publishedExample() throws {
        let figures = try figures(
            entry: 1_000_000, markRaw: 1_000_000, collateral: "10000000000", size: 100_000)
        let liquidation = try #require(figures.liquidationPrice)
        #expect(liquidation.raw == 940_000)
    }

    @Test("A position with no size yields no figures rather than a fabricated one")
    func zeroSize() throws {
        let position = try JSONDecoder().decode(PerplPosition.self, from: positionJSON(size: 0))
        let mark = try #require(Price(raw: 1_000_000, decimals: btc.priceDecimals))
        #expect(PositionFigures(position: position, market: btc, mark: mark) == nil)
    }

    /// Mark, PnL and liquidation distance all descend from one price. Derived separately
    /// in a view they can come from two different ticks, and the screen then shows a PnL
    /// that does not match the mark above it.
    @Test("Every figure descends from the mark it was given")
    func figuresShareOneTick() throws {
        let figures = try figures(markRaw: 1_050_000)
        #expect(figures.mark.raw == 1_050_000)
    }
}

/// A position frame with the market, account and position id under the caller's control,
/// so a book can be built out of several of them.
private func bookJSON(
    market: Int = 16, account: Int = 42, id: Int64 = 7,
    size: Int64 = 1_000_000, exit: Int64? = nil
) -> Data {
    var fields: [String] = [
        #""mkt":\#(market)"#, #""acc":\#(account)"#, #""pid":"\#(id)""#, #""sd":1"#,
        #""c":"10000000000""#, #""ep":1000000"#, #""s":\#(size)"#,
        #""lv":1000"#, #""efs":"0""#, #""xfs":"0""#, #""fee":"0""#, #""st":1"#,
    ]
    if let exit { fields.append(#""xp":\#(exit)"#) }
    return Data("{\(fields.joined(separator: ","))}".utf8)
}

private func position(
    market: Int = 16, account: Int = 42, id: Int64 = 7,
    size: Int64 = 1_000_000, exit: Int64? = nil
) throws -> PerplPosition {
    try JSONDecoder().decode(
        PerplPosition.self, from: bookJSON(market: market, account: account, id: id, size: size, exit: exit))
}

@Suite("Folding position deltas into the book")
struct PositionBookTests {
    @Test("An update to one market leaves the others alone")
    func otherMarketsSurvive() throws {
        let btcRow = try position(market: 16, id: 7)
        let ethRow = try position(market: 20, id: 8)
        let merged = PositionBook.merging(existing: [btcRow, ethRow], updates: [try position(market: 20, id: 8, size: 2_000_000)])
        #expect(merged.count == 2)
        #expect(merged.contains { $0.marketID == 16 && $0.positionID == 7 })
        #expect(merged.first { $0.marketID == 20 }?.sizeRaw == 2_000_000)
    }

    @Test("An update under the same id replaces the row it names")
    func sameIdReplaces() throws {
        let open = try position(id: 7)
        let closed = try position(id: 7, exit: 1_200_000)
        let merged = PositionBook.merging(existing: [open], updates: [closed])
        #expect(merged.count == 1)
        #expect(merged[0].isOpen == false)
    }

    /// The reported bug: a position closed on the venue, reported under a new id, left
    /// the old row on screen still marked open. Closing it again sent an order with
    /// nothing to match, which came back as expired.
    @Test("A close reported under a new id retires the row it replaces")
    func closeUnderNewIdRetiresTheOldRow() throws {
        let held = try position(id: 7)
        let closedElsewhere = try position(id: 9, exit: 1_200_000)
        let merged = PositionBook.merging(existing: [held], updates: [closedElsewhere])
        #expect(merged.count == 1)
        #expect(merged[0].positionID == 9)
        #expect(merged.contains { $0.isOpen } == false)
    }

    @Test("Reopening a market under a new id retires the row it replaces")
    func reopenRetiresTheOldRow() throws {
        let held = try position(id: 7)
        let merged = PositionBook.merging(existing: [held], updates: [try position(id: 11)])
        #expect(merged.map(\.positionID) == [11])
    }

    /// Only the same account on the same market. Two people, or two markets, are not
    /// evidence about each other.
    @Test("Another account's position on the same market is untouched")
    func otherAccountsSurvive() throws {
        let mine = try position(account: 42, id: 7)
        let theirs = try position(account: 99, id: 8)
        let merged = PositionBook.merging(existing: [mine, theirs], updates: [try position(account: 42, id: 12, exit: 1_200_000)])
        #expect(merged.contains { $0.accountID == 99 && $0.isOpen })
        #expect(merged.filter { $0.accountID == 42 }.allSatisfy { !$0.isOpen })
    }

    /// A closed row is history, and history does not get retired by what comes after it.
    @Test("A closed row on the market stays in the book")
    func closedRowsAreKept() throws {
        let past = try position(id: 3, exit: 900_000)
        let merged = PositionBook.merging(existing: [past], updates: [try position(id: 7)])
        #expect(merged.count == 2)
        #expect(merged.contains { $0.positionID == 3 })
    }
}
