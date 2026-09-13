import Foundation

/// Perpl's funding, which is not any other venue's funding.
public enum Funding {
    /// Two thousand five hundred and eighty seconds. Forty-three minutes, not an hour.
    /// Annualising at 8,760 intervals instead of 12,223 understates funding by 28.4%.
    public static let intervalSeconds = 2_580

    /// `365 × 86,400 / 2,580`, truncated.
    public static let intervalsPerYear = 12_223

    /// `ppl = trunc(idx × rate × div / 10^6)`.
    ///
    /// Derived rather than documented, and reproduced on every live market on both
    /// networks including negative rates. It is the only thing that establishes `rate`
    /// is in micros, which no field name reveals — the contract calls it
    /// `fundingRatePct100k`. Kept here so that a change in the encoding fails a test
    /// rather than quietly rescaling every funding figure in the app.
    public static func premiumPnL(indexRaw: Int64, rateMicros: Int64, divisor: Int64) -> Int64? {
        let (scaled, overflowed) = Int128(indexRaw).multipliedReportingOverflow(by: Int128(rateMicros))
        guard !overflowed else { return nil }
        let (product, secondOverflow) = scaled.multipliedReportingOverflow(by: Int128(divisor))
        guard !secondOverflow else { return nil }
        // Truncating, which is what `Int128` division does and what the wire shows for
        // negative rates.
        let result = product / 1_000_000
        guard let narrowed = Int64(exactly: result) else { return nil }
        return narrowed
    }

    /// A per-interval rate, annualised. Still micros of a fraction, not a percentage.
    public static func annualisedMicros(perIntervalMicros: Int64) -> Int64? {
        let (product, overflowed) = perIntervalMicros.multipliedReportingOverflow(by: Int64(intervalsPerYear))
        return overflowed ? nil : product
    }

    /// Funding since entry is a subtraction, not something to accumulate client-side:
    /// funding settles virtually through an accumulator and positions carry their entry
    /// and exit sums.
    public static func accumulatorDelta(entrySum: Int64, exitSum: Int64) -> Int64? {
        let (difference, overflowed) = exitSum.subtractingReportingOverflow(entrySum)
        return overflowed ? nil : difference
    }
}

// Deliberately absent: anything that turns an accumulator delta into "funding paid" or
// "funding received". The sign of `premiumPnlCNS` is unresolved — Perpl's prose and its
// formula disagree, and the ABI type name favours positive meaning received. Nothing
// here may claim a direction until a real position has settled an interval and the sign
// has been observed. See docs/04-algorithms.md §6.
