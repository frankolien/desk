import Foundation

/// The book the app holds, kept in step with a stream that only ever sends what changed.
///
/// Message 26 is a snapshot and 27 is a delta, so between snapshots the app's copy is
/// whatever it has managed to fold in. Two things make that harder than appending:
///
///   1. A delta names only the positions that moved. Replacing the array with an ETH
///      update once made an open BTC position vanish until the socket reconnected.
///   2. A position that closes is not always restated under the id the app is holding.
///      When the venue reports the close under a new position id, a merge keyed only on
///      the id keeps the old row, still marked open, for a position the account no longer
///      holds — and the screen offers to close something that is already closed. That
///      close then sits unmatched until its deadline and comes back as "expired", which
///      reads as a fault in the app rather than as the position being long gone.
///
/// The second is fixed by an invariant the exchange itself enforces: one account holds at
/// most one open position per market. `getPositionV2` takes a market and an account and
/// returns a single row, so any other row still marked open on that market is stale the
/// moment a newer one arrives for it.
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
