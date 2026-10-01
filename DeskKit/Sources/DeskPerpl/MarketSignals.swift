import DeskMoney
import Foundation

public struct MarketSignals: Sendable, Hashable {
    /// How far the perpetual is trading from the underlying, in micros of a fraction.
    public let premiumMicros: Int?
    /// The gap between bid and ask as a fraction of the mid, in micros.
    public let spreadMicros: Int?
    public let lean: Lean
    /// Open interest **in contracts**, at the market's size scale, not the collateral's.
    /// The field name says nothing about its scale, and AUSD would look plausible.
    public let openInterest: Size?
    public let openInterestNotional: Money?

    public enum Lean: Sendable, Hashable {
        case buyers
        case sellers
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

    public var premiumIsNotable: Bool {
        guard let premiumMicros else { return false }
        return abs(premiumMicros) >= 1_000
    }

    public var isEmpty: Bool {
        premiumMicros == nil && spreadMicros == nil && openInterest == nil && lean == .balanced
    }
}
