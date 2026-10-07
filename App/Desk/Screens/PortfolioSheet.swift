import DeskMoney
import DeskPerpl
import DeskUI
import SwiftUI

/// The desk over the chart: balances and every open position, so a trader checks the book
/// without leaving the market. A row opens the position, and closing it happens there.
struct PortfolioSheet: View {
    let model: AppModel
    let market: MarketModel

    @Environment(\.dismiss) private var dismiss
    @AppStorage("desk.hidesBalance") private var hidesBalance = false
    @State private var selectedPosition: PerplPosition?

    private var contexts: [PositionContext] { PositionContext.all(model: model, market: market) }

    var body: some View {
        ZStack {
            DeskBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    balances.padding(.top, 18)
                    positions.padding(.top, 24)
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 40)
            }
            .refreshable { await model.refreshBalances(); await market.refreshNow() }
        }
        .sheet(item: $selectedPosition) { held in
            PositionScreen(position: held, market: market, session: model.trading, model: model)
                .presentationDetents([.large])
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Your desk")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
                Text(countLine)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .deskGlass(interactive: true, in: Circle())
        }
    }

    private var countLine: String {
        let count = contexts.count
        if count == 0 { return model.hasTradingAccount ? "No open positions" : "No desk open yet" }
        return "\(count) open \(count == 1 ? "position" : "positions")"
    }

    private var balances: some View {
        HStack(spacing: 10) {
            stat("In trading", money(model.collateral.value))
            stat("Wallet", money(model.walletAUSD.value))
            stat("Open PnL", pnlText, tint: pnlTint)
        }
    }

    private var pnlText: String {
        guard let total = PositionContext.totalPnL(contexts) else { return "—" }
        if hidesBalance { return "•••••" }
        return (total.isNegative ? "" : "+") + total.display()
    }

    private var pnlTint: DeskRGB {
        guard let total = PositionContext.totalPnL(contexts) else { return DeskColor.nightText }
        return total.isNegative ? DeskColor.fall : DeskColor.rise
    }

    private func money(_ value: Money?) -> String {
        guard let value else { return Unavailable.text }
        return hidesBalance ? "•••••" : value.display()
    }

    private func stat(_ label: String, _ value: String, tint: DeskRGB = DeskColor.nightText) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(DeskColor.nightMuted.color)
                .textCase(.uppercase)
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(tint.color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var positions: some View {
        let rows = contexts
        if rows.isEmpty {
            Text(model.hasTradingAccount ? "Nothing open. Long or Short below starts one." : "Open a desk from Profile to start trading.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(DeskColor.nightMuted.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
        } else {
            VStack(spacing: 0) {
                ForEach(rows) { position in
                    row(position)
                }
            }
        }
    }

    private func row(_ position: PositionContext) -> some View {
        Button {
            market.select(position.market)
            Task { await model.trading.selectMarket(position.market) }
            selectedPosition = position.held
        } label: {
            HStack(spacing: 12) {
                MarketTokenLogo(symbol: position.market.symbol, size: 40, venue: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(position.figures.side == .long ? "Long" : "Short") \(position.market.symbol) · \(position.figures.leverageHundredths / 100)×")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                        .lineLimit(1)
                    Text(Self.liquidationLine(position.figures))
                        .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(hidesBalance ? "•••••" : (position.figures.unrealisedPnL.isNegative ? "" : "+") + position.figures.unrealisedPnL.display() + " AUSD")
                        .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle((position.figures.isProfit ? DeskColor.rise : DeskColor.fall).color)
                        .lineLimit(1)
                    Text(Percent.micros(position.figures.returnOnMarginMicros) + " on margin")
                        .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 11)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5).padding(.leading, 52)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(DeskPressStyle())
    }

    /// How far the mark is from liquidation, in the words the Profile tab uses.
    static func liquidationLine(_ figures: PositionFigures) -> String {
        guard let distance = figures.liquidationDistanceMicros else { return "Liq. \(Unavailable.text)" }
        return distance == 0 ? "At liquidation" : "Liq. \(Percent.micros(distance, signed: false)) away"
    }
}
