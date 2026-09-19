import DeskPerpl
import Foundation
import WidgetKit

/// Keeps the Portfolio and Watchlist widgets in step with what Home and Watchlist show.
///
/// Called on a slow loop rather than on every tick, because a widget reload is not free:
/// WidgetKit budgets them, and a price that moves several times a second would spend
/// the day's budget before lunch. Each glance is only written when something in it
/// changed, so a quiet market costs nothing.
@MainActor
final class HomeGlancePublisher {
    private var lastPortfolio: PortfolioGlance?
    private var lastWatchlist: WatchlistGlance?

    func publish(model: AppModel, market: MarketModel) {
        if var portfolio = Self.portfolio(model: model, market: market) {
            portfolio.updatedAt = lastPortfolio?.updatedAt ?? portfolio.updatedAt
            if portfolio != lastPortfolio {
                portfolio.updatedAt = .now
                lastPortfolio = portfolio
                portfolio.save()
                WidgetCenter.shared.reloadTimelines(ofKind: PortfolioGlance.widgetKind)
            }
        }
        if var watchlist = Self.watchlist(market: market) {
            watchlist.updatedAt = lastWatchlist?.updatedAt ?? watchlist.updatedAt
            if watchlist != lastWatchlist {
                watchlist.updatedAt = .now
                lastWatchlist = watchlist
                watchlist.save()
                WidgetCenter.shared.reloadTimelines(ofKind: WatchlistGlance.widgetKind)
            }
        }
    }

    /// Nil until the exchange balance has arrived: a glance written from a still-loading
    /// balance would put "--" on the Home Screen as if it were the figure.
    private static func portfolio(model: AppModel, market: MarketModel) -> PortfolioGlance? {
        guard model.address != nil, let collateral = model.collateral.value else { return nil }
        // The same derivation Home uses, so the two never disagree on a figure.
        let positions = model.openPositions.compactMap { held -> PortfolioGlance.Position? in
            guard let item = market.market(id: held.marketID),
                  let mark = market.price(for: item),
                  let figures = PositionFigures(position: held, market: item.config, mark: mark)
            else { return nil }
            return PortfolioGlance.Position(
                id: "\(held.accountID):\(held.positionID)",
                symbol: item.symbol,
                isLong: figures.side == .long,
                leverage: figures.leverageHundredths / 100,
                pnl: Double(figures.unrealisedPnL.raw) / 1_000_000,
                pnlText: (figures.unrealisedPnL.isNegative ? "" : "+") + figures.unrealisedPnL.display(),
                returnOnMarginMicros: figures.returnOnMarginMicros)
        }
        return PortfolioGlance(
            addressShort: model.addressShort,
            network: model.network.name,
            collateralText: DisplayCurrency.shared.format(collateral),
            positions: positions,
            updatedAt: .now)
    }

    /// Nil until the venue's market list has arrived. An empty saved list is a real
    /// state and is written as one, so the widget can say so.
    private static func watchlist(market: MarketModel) -> WatchlistGlance? {
        guard !market.allMarkets.isEmpty else { return nil }
        let saved = Set((UserDefaults.standard.string(forKey: "desk.watchlist") ?? "")
            .split(separator: ",").compactMap { UInt32($0) })
        let rows = market.allMarkets.filter { saved.contains($0.id) }.compactMap { item -> WatchlistGlance.Row? in
            guard let price = market.price(for: item) else { return nil }
            return WatchlistGlance.Row(
                id: item.id,
                symbol: item.symbol,
                priceText: "$" + price.display(fractionDigits: item.config.priceDecimals),
                changePercent: market.changePercent(for: item))
        }
        return WatchlistGlance(rows: rows, updatedAt: .now)
    }
}
