import Foundation

/// Message 27 is a delta keyed by position id. The exchange holds one open position per account per
/// market, so a newer row on a market retires any other open row there — even under a different id.
public enum PositionBook {
    /// Superseded rows are removed, not rewritten as closed: their exit price and realised result
    /// are unknown, and inventing either would put a figure in history the venue never sent.
    public static func merging(
        existing: [PerplPosition], updates: [PerplPosition]
    ) -> [PerplPosition] {
        var result = existing
        for update in updates {
            if let index = result.firstIndex(where: {
                $0.accountID == update.accountID && $0.positionID == update.positionID
            }) {
                result[index] = update
            } else {
                result.append(update)
            }
            result.removeAll { other in
                other.accountID == update.accountID
                    && other.marketID == update.marketID
                    && other.positionID != update.positionID
                    && other.isOpen
            }
        }
        return result
    }

    /// A position can appear more than once in history. Only rows the venue marks Closed,
    /// Liquidated, Deleveraged or Unwound end one; the latest such row per position is kept.
    public static func closedRows(in history: [PerplPosition]) -> [PerplPosition] {
        var latest: [Int64: PerplPosition] = [:]
        var order: [Int64] = []
        for row in history where (2...5).contains(row.statusCode) && !row.isOpen {
            guard let kept = latest[row.positionID] else {
                latest[row.positionID] = row
                order.append(row.positionID)
                continue
            }
            if (row.updatedBlock ?? 0) > (kept.updatedBlock ?? 0) { latest[row.positionID] = row }
        }
        return order.compactMap { latest[$0] }
    }
}
