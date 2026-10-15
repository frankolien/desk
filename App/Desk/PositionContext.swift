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

    /// What the open positions would hand back if closed at the current mark: each one's margin
    /// and what it is up or down, never below nothing. One without a readable mark counts at its
    /// margin, so a missing price can't make money vanish from the total.
    @MainActor static func openValue(model: AppModel, market: MarketModel) -> Money {
        model.openPositions.reduce(.zero) { sum, held in
            let margin = Money(raw: held.collateralRaw) ?? .zero
            guard let item = market.market(id: held.marketID),
                  let mark = market.price(for: item),
                  let figures = PositionFigures(position: held, market: item.config, mark: mark)
            else { return sum + margin }
            let value = figures.collateral + figures.unrealisedPnL
            return sum + (value.isNegative ? .zero : value)
        }
    }

    /// Everything the wallet holds through Desk: AUSD free to trade, AUSD in the wallet, the open
    /// positions at their current value, and tokens bought here (in dollars). Opening a trade
    /// moves money into a position; it doesn't take it out of this figure.
    @MainActor static func worth(model: AppModel, market: MarketModel, tokensUSD: Double = 0) -> Money? {
        guard let free = model.collateral.value else { return nil }
        let tokens = Money(raw: Int64((tokensUSD * 1_000_000).rounded())) ?? .zero
        return free + (model.walletAUSD.value ?? .zero) + openValue(model: model, market: market) + tokens
    }
}
