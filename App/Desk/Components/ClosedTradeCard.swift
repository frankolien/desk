import DeskMoney
import DeskPerpl
import DeskUI
import SwiftUI

/// A closed trade in the open position's card: every figure is Perpl's record of the position at
/// close, so nothing here moves with the market.
struct ClosedTradeCard: View {
    let trade: ClosedTrade
    let symbol: String
    let market: Market?

    private var pnl: Money? { trade.realisedPnLRaw.flatMap { Money(raw: $0) } }
    private var collateral: Money? { Money(raw: trade.collateralRaw) }

    private func price(_ raw: Int64?) -> Price? {
        guard let raw, let decimals = market?.config.priceDecimals else { return nil }
        return Price(raw: raw, decimals: decimals)
    }

    private var size: Size? {
        guard trade.sizeRaw > 0, let decimals = market?.config.sizeDecimals else { return nil }
        return Size(raw: trade.sizeRaw, decimals: decimals)
    }

    private var exitValue: Money? {
        guard let exit = price(trade.exitRaw), let size else { return nil }
        return Money.notional(price: exit, size: size, rounding: .towardZero)
    }

    private var returnOnMargin: String? {
        guard let raw = trade.realisedPnLRaw, trade.collateralRaw > 0 else { return nil }
        return Percent.micros(Int(Int128(raw) * 1_000_000 / Int128(trade.collateralRaw))) + " on margin"
    }

    /// How far the market itself moved between entry and exit, before leverage.
    private var move: String? {
        guard let exitRaw = trade.exitRaw, trade.entryRaw > 0 else { return nil }
        return Percent.micros(Int(Int128(exitRaw - trade.entryRaw) * 1_000_000 / Int128(trade.entryRaw)))
    }

    private func signed(_ money: Money) -> String { (money.isNegative ? "" : "+") + money.display() + " AUSD" }

    var body: some View {
        let decimals = market?.config.priceDecimals ?? 2
        PositionCard(
            symbol: symbol,
            sideText: "\(trade.leverageHundredths / 100)× \(trade.isLong ? "Long" : "Short")",
            isLong: trade.isLong,
            rows: [
                (PositionCardMetric(label: "Value at exit", value: exitValue.map { DisplayCurrency.shared.format($0) } ?? Unavailable.text),
                 PositionCardMetric(label: "Realised PnL", value: pnl.map(signed) ?? Unavailable.text, detail: returnOnMargin,
                                    tint: (pnl?.isNegative ?? false) ? DeskColor.fall : DeskColor.rise)),
                (PositionCardMetric(label: "Entry / Exit",
                                    value: (price(trade.entryRaw)?.display(fractionDigits: decimals) ?? Unavailable.text) + " / "
                                        + (price(trade.exitRaw)?.display(fractionDigits: decimals) ?? Unavailable.text)),
                 PositionCardMetric(label: "Price move", value: move ?? Unavailable.text, detail: "\(symbol) entry to exit")),
                (PositionCardMetric(label: "Size", value: size.map { $0.display(fractionDigits: $0.decimals) + " " + symbol } ?? Unavailable.text),
                 PositionCardMetric(label: "Collateral", value: collateral.map { $0.display() + " AUSD" } ?? Unavailable.text)),
                (PositionCardMetric(label: "Funding", value: trade.realisedFundingRaw.flatMap { Money(raw: $0) }.map { $0.display() + " AUSD" } ?? Unavailable.text,
                                    detail: "over the trade"),
                 PositionCardMetric(label: "Fees", value: Money(raw: trade.feeRaw).map { $0.display() + " AUSD" } ?? Unavailable.text,
                                    detail: "entry and exit")),
            ]) {
            Text(trade.closedAt.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(DeskColor.nightMuted.color)
        }
    }
}
