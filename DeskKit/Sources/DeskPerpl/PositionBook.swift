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
}
