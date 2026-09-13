import DeskMoney
import Foundation

/// What the market is doing, read out of figures the app already fetches.
///
/// Nothing here is new data. `MarketState` carries the bid, the ask, the mid, the mark,
/// the oracle price and open interest on the same context call the price comes from — the
/// screen simply never asked what they meant together. Four readings come out of them,
/// and each is a real relationship rather than a number dressed up as an insight.
///
/// The rule for every one of them: it is `nil` when it cannot be computed. A market with
/// no bid has no spread, and inventing one — or rendering zero — would be a claim about a
/// book that is not there.
public struct MarketSignals: Sendable, Hashable {
    /// How far the perpetual is trading from the underlying, in micros of a fraction.
    ///
    /// The most informative single number on the screen. A positive premium means buyers
    /// are paying above spot to be long, which is crowd positioning — and it is what
    /// funding then charges them for.
    public let premiumMicros: Int?
    /// The gap between bid and ask as a fraction of the mid, in micros. What it costs to
    /// get in and straight back out.
    public let spreadMicros: Int?
    /// Which side the last trade went off on.
    public let lean: Lean
    /// Everything currently committed to this market, **in contracts** — at the market's
    /// size scale, not the collateral's.
    ///
    /// Verified against the live venue rather than assumed, after the first version read
    /// it as AUSD and rendered a market holding eighteen bitcoin as `1.82 AUSD`. The
    /// field name says nothing about its scale and the two differ by ten to the first
    /// here, which is small enough to look like a plausible number and therefore the
    /// dangerous kind of wrong.
    public let openInterest: Size?
    /// What that open interest is worth at the mark, which is the figure a person can
    /// actually judge. Nil when either side of the multiplication is missing.
    public let openInterestNotional: Money?

    public enum Lean: Sendable, Hashable {
        case buyers
        case sellers
        /// Inside the spread, or no book to compare against. Not a weak signal — no
        /// signal, which is a different thing and has to render differently.
        case balanced
    }

    public init(state: MarketState, priceDecimals: UInt8, sizeDecimals: UInt8) {
        // Against the oracle, which is the underlying. Against the mark it would always be
        // zero, because the mark is the number being compared.
        if state.oracleRaw > 0, state.markRaw > 0 {
            let gap = Int128(state.markRaw) - Int128(state.oracleRaw)
            premiumMicros = Int(clamping: gap * 1_000_000 / Int128(state.oracleRaw))
        } else {
            premiumMicros = nil
        }

        // A crossed book — ask below bid — is not a negative spread, it is a book in a
        // state this cannot describe. Reported as unavailable rather than as a bargain.
        if state.bidRaw > 0, state.askRaw > state.bidRaw, state.midRaw > 0 {
            let gap = Int128(state.askRaw) - Int128(state.bidRaw)
            spreadMicros = Int(clamping: gap * 1_000_000 / Int128(state.midRaw))
        } else {
            spreadMicros = nil
        }

        // A trade above the mid lifted the ask; below it hit the bid. Exactly at the mid,
        // or with no book, says nothing.
        if state.lastRaw > 0, state.midRaw > 0, state.bidRaw > 0, state.askRaw > state.bidRaw {
            lean = if state.lastRaw > state.midRaw { .buyers }
            else if state.lastRaw < state.midRaw { .sellers }
            else { .balanced }
        } else {
            lean = .balanced
        }

        let size = state.openInterestRaw > 0
            ? Size(raw: state.openInterestRaw, decimals: sizeDecimals)
            : nil
        openInterest = size
        if let size, let mark = Price(raw: state.markRaw, decimals: priceDecimals), mark.raw > 0 {
            openInterestNotional = Money.notional(price: mark, size: size, rounding: .towardZero)
        } else {
            openInterestNotional = nil
        }
    }

    /// Whether the premium is large enough to be worth a sentence.
    ///
    /// Ten basis points. Below that it is noise on a venue whose mark updates every block,
    /// and a screen that calls every flicker a signal teaches people to ignore it.
    public var premiumIsNotable: Bool {
        guard let premiumMicros else { return false }
        return abs(premiumMicros) >= 1_000
    }

    public var isEmpty: Bool {
        premiumMicros == nil && spreadMicros == nil && openInterest == nil && lean == .balanced
    }
}
