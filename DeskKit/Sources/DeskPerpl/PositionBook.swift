import Foundation

/// Message 27 is a delta keyed by position id. The exchange holds one open position per account per
/// market, so a newer row on a market retires any other open row there — even under a different id.
public enum PositionBook {
    /// Folds a delta into the book and drops the rows the delta proves are out of date.
    ///
    /// Rows superseded this way are removed rather than rewritten as closed: the app does
    /// not know their exit price or realised result, and inventing either would put a
    /// figure in the history that the venue never sent. The closed row the venue did send
    /// is already in the result.
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
