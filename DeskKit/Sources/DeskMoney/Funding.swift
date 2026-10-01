import Foundation

public enum Funding {
    /// Two thousand five hundred and eighty seconds. Forty-three minutes, not an hour.
    /// Annualising at 8,760 intervals instead of 12,223 understates funding by 28.4%.
    public static let intervalSeconds = 2_580

    public static let intervalsPerYear = 12_223

    /// `ppl = trunc(idx × rate × div / 10^6)`, derived from live markets rather than documented.
    /// It is what shows `rate` is in micros, despite the contract's name `fundingRatePct100k`.
    public static func premiumPnL(indexRaw: Int64, rateMicros: Int64, divisor: Int64) -> Int64? {
        let (scaled, overflowed) = Int128(indexRaw).multipliedReportingOverflow(by: Int128(rateMicros))
        guard !overflowed else { return nil }
        let (product, secondOverflow) = scaled.multipliedReportingOverflow(by: Int128(divisor))
        guard !secondOverflow else { return nil }
        let result = product / 1_000_000
        guard let narrowed = Int64(exactly: result) else { return nil }
        return narrowed
    }

    public static func annualisedMicros(perIntervalMicros: Int64) -> Int64? {
        let (product, overflowed) = perIntervalMicros.multipliedReportingOverflow(by: Int64(intervalsPerYear))
        return overflowed ? nil : product
    }

    public static func accumulatorDelta(entrySum: Int64, exitSum: Int64) -> Int64? {
        let (difference, overflowed) = exitSum.subtractingReportingOverflow(entrySum)
        return overflowed ? nil : difference
    }
}

// Deliberately absent: "funding paid" or "received". The sign of `premiumPnlCNS` is
// unresolved until observed on a settled interval. See docs/04-algorithms.md §6.
