import DeskMoney
import DeskPerpl

/// An open position with the market it is on and the figures drawn from one current mark, so
/// every number in a row descends from the same price.
struct PositionContext: Identifiable {
    let held: PerplPosition
    let market: Market
    let figures: PositionFigures
    var id: String { "\(held.accountID):\(held.positionID)" }

    /// Every open position the model holds that has a listed market and a readable mark.
    @MainActor static func all(model: AppModel, market: MarketModel) -> [PositionContext] {
        model.openPositions.compactMap { held in
            guard let positionMarket = market.market(id: held.marketID),
                  let mark = market.price(for: positionMarket),
                  let figures = PositionFigures(position: held, market: positionMarket.config, mark: mark)
            else { return nil }
            return PositionContext(held: held, market: positionMarket, figures: figures)
        }
    }

    static func totalPnL(_ contexts: [PositionContext]) -> Money? {
        guard !contexts.isEmpty else { return nil }
        return contexts.reduce(.zero) { $0 + $1.figures.unrealisedPnL }
    }
}
