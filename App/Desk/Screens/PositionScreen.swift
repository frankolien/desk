import DeskPerpl
import DeskMoney
import DeskUI
import SwiftUI

struct PositionScreen: View {
    let position: PerplPosition
    let market: MarketModel
    let session: TradingSession
    @Environment(\.dismiss) private var dismiss
    @State private var showsClose = false
    @State private var showsProtection = false

    private var figures: PositionFigures? {
        guard position.marketID == market.market?.id,
              let config = market.market?.config,
              let mark = market.mark.value else { return nil }
        return PositionFigures(position: position, market: config, mark: mark)
    }

    private var stale: Bool { market.freshness.freezesDigits }

    var body: some View {
        NavigationStack {
            ZStack {
                DeskBackground()
                if let figures { content(figures) } else { unavailable }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $showsClose) {
                if let figures, let selected = market.market {
                    MarketCloseSheet(
                        position: position, figures: figures, market: selected,
                        session: session) { showsClose = false }
                }
            }
            .sheet(isPresented: $showsProtection) {
                if let figures, let selected = market.market {
                    PositionProtectionSheet(
                        position: position, figures: figures, market: selected,
                        session: session) { showsProtection = false }
                }
            }
        }
    }

    private func content(_ figures: PositionFigures) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    MarketTokenLogo(symbol: market.symbol, size: 34)
                    Text("\(figures.side == .long ? "Long" : "Short") \(market.symbol)")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("\(figures.leverageHundredths / 100)×")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.white.opacity(0.1), in: Capsule())
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text((figures.unrealisedPnL.isNegative ? "" : "+")
                         + figures.unrealisedPnL.display() + " AUSD")
                        .font(.system(size: 42, weight: .heavy, design: .rounded).monospacedDigit())
                        .foregroundStyle(figures.isProfit ? DeskColor.rise.color : DeskColor.fall.color)
                        .contentTransition(.numericText())
                    Text(HomeScreen.percent(figures.returnOnMarginMicros) + " on margin")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                }
                .opacity(stale ? 0.55 : 1)

                VStack(spacing: 10) {
                    ValueRow(
                        label: "Liquidation",
                        value: figures.liquidationPrice?.display(fractionDigits: figures.entry.decimals) ?? Unavailable.text,
                        detail: figures.liquidationDistanceMicros.map {
                            $0 == 0 ? "At liquidation" : HomeScreen.percent($0, signed: false) + " away"
                        }, tint: DeskColor.fall, isDimmed: stale)
                    ValueRow(
                        label: "Size",
                        value: figures.size.display(fractionDigits: figures.size.decimals) + " \(market.symbol)",
                        detail: figures.collateral.display() + " AUSD collateral")
                    ValueRow(label: "Entry", value: figures.entry.display(fractionDigits: figures.entry.decimals))
                    ValueRow(label: "Mark", value: figures.mark.display(fractionDigits: figures.mark.decimals), isDimmed: stale)
                    ValueRow(label: "Funding", value: figures.fundingSinceEntry.map { $0.display() + " AUSD" } ?? Unavailable.text,
                             detail: "since you opened")
                }

                HStack(spacing: 10) {
                    Button { showsProtection = true } label: {
                        Label("Add TP/SL", systemImage: "shield.lefthalf.filled")
                            .frame(maxWidth: .infinity)
                    }
                    .tint(DeskColor.nightChip.color)

                    Button { showsClose = true } label: {
                        Text(session.isBusy ? "Closing…" : "Close")
                            .frame(maxWidth: .infinity)
                    }
                    .tint(DeskColor.fall.color)
                }
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(session.isBusy)

                if let status = session.statusText {
                    Text(status)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(session.hasFailed ? DeskColor.fall.color : DeskColor.nightMuted.color)
                }
            }
            .foregroundStyle(DeskColor.nightText.color)
            .padding(20)
        }
    }

    private var unavailable: some View {
        ContentUnavailableView("Position unavailable", systemImage: "chart.xyaxis.line",
            description: Text("Waiting for the authenticated Perpl position stream."))
            .foregroundStyle(DeskColor.nightText.color)
    }
}

private struct MarketCloseSheet: View {
    let position: PerplPosition
    let figures: PositionFigures
    let market: Market
    let session: TradingSession
    let onDone: () -> Void
    @State private var percentage = 100

    private var closeSize: Size? {
        let raw = Int128(figures.size.raw) * Int128(percentage) / 100
        return Int64(exactly: raw).flatMap {
            Size(raw: max(1, $0), decimals: figures.size.decimals)
        }
    }

    private var closeNotional: Money? {
        closeSize.flatMap { Money.notional(price: figures.mark, size: $0, rounding: .towardZero) }
    }

    var body: some View {
        VStack(spacing: 20) {
            Capsule().fill(DeskColor.nightMuted.color.opacity(0.5)).frame(width: 44, height: 5)
            Text("Market Close").font(DeskType.title)
            VStack(spacing: 8) {
                Text("Close size").font(DeskType.caption).foregroundStyle(DeskColor.nightMuted.color)
                Text(closeNotional.map { "$" + $0.display() } ?? Unavailable.text)
                    .font(.system(size: 42, weight: .bold, design: .rounded).monospacedDigit())
                Text("\(percentage)% of \(figures.side == .long ? "Long" : "Short") \(market.symbol)")
                    .font(DeskType.caption).foregroundStyle(DeskColor.nightMuted.color)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 28)
            .background(DeskColor.nightChip.color, in: RoundedRectangle(cornerRadius: 20))

            VStack(spacing: 12) {
                Slider(value: Binding(get: { Double(percentage) }, set: { percentage = Int($0.rounded()) }),
                       in: 1...100, step: 1)
                    .tint(DeskColor.fall.color)
                HStack(spacing: 8) {
                    ForEach([25, 50, 75, 100], id: \.self) { value in
                        Button(value == 100 ? "MAX" : "\(value)%") { percentage = value }
                            .font(DeskType.caption)
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .background(percentage == value ? DeskColor.fall.color.opacity(0.22) : DeskColor.nightChip.color)
                            .clipShape(Capsule())
                    }
                }
            }

            VStack(spacing: 10) {
                ValueRow(label: "Position size", value: figures.size.display(fractionDigits: figures.size.decimals) + " " + market.symbol)
                ValueRow(label: "Closing", value: closeSize?.display(fractionDigits: figures.size.decimals) ?? Unavailable.text)
                ValueRow(label: "Mark", value: figures.mark.display(fractionDigits: figures.mark.decimals))
            }
            .padding(16).background(DeskColor.nightChip.color, in: RoundedRectangle(cornerRadius: 18))
            Spacer()
            Button {
                guard let closeSize else { return }
                Task {
                    await session.closePosition(
                        position, size: closeSize,
                        slippageBps: min(50, market.maxMarketSlippageBps))
                    if !session.hasFailed { onDone() }
                }
            } label: {
                Text(session.isBusy ? "Closing…" : "Close \(percentage)%")
                    .font(DeskType.label).frame(maxWidth: .infinity).frame(height: 52)
            }
            .buttonStyle(.borderedProminent).tint(DeskColor.fall.color).disabled(session.isBusy)
        }
        .padding(20).foregroundStyle(DeskColor.nightText.color).background(DeskColor.night.color)
        .presentationDetents([.large]).presentationDragIndicator(.hidden)
    }
}

private struct PositionProtectionSheet: View {
    let position: PerplPosition
    let figures: PositionFigures
    let market: Market
    let session: TradingSession
    let onDone: () -> Void
    @State private var takeProfit = ""
    @State private var stopLoss = ""

    private var tp: Price? {
        takeProfit.isEmpty ? nil : Price(buying: takeProfit, decimals: market.config.priceDecimals)
    }
    private var sl: Price? {
        stopLoss.isEmpty ? nil : Price(selling: stopLoss, decimals: market.config.priceDecimals)
    }
    private var valid: Bool {
        guard tp != nil || sl != nil else { return false }
        if let tp, figures.side == .long ? tp <= figures.mark : tp >= figures.mark { return false }
        if let sl, figures.side == .long ? sl >= figures.mark : sl <= figures.mark { return false }
        return true
    }

    var body: some View {
        VStack(spacing: 20) {
            Capsule().fill(DeskColor.nightMuted.color.opacity(0.5)).frame(width: 44, height: 5)
            Text("Add TP/SL").font(DeskType.title)
            VStack(spacing: 12) {
                HStack {
                    MarketTokenLogo(symbol: market.symbol, size: 32)
                    Text(market.symbol).font(DeskType.title)
                    Text("\(figures.leverageHundredths / 100)× \(figures.side == .long ? "Long" : "Short")")
                        .font(DeskType.caption).foregroundStyle(DeskColor.rise.color)
                    Spacer()
                }
                ValueRow(label: "Entry / Mark", value: figures.entry.display(fractionDigits: figures.entry.decimals) + " / " + figures.mark.display(fractionDigits: figures.mark.decimals))
                ValueRow(label: "Position", value: figures.size.display(fractionDigits: figures.size.decimals) + " " + market.symbol)
            }
            .padding(16).background(DeskColor.nightChip.color, in: RoundedRectangle(cornerRadius: 18))

            triggerField("Take profit", text: $takeProfit, tint: DeskColor.rise)
            triggerField("Stop loss", text: $stopLoss, tint: DeskColor.fall)
            Text("Perpl watches mark price and keeps these triggers active when Desk is closed.")
                .font(DeskType.caption).foregroundStyle(DeskColor.nightMuted.color)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
            Button {
                Task {
                    let saved = await session.protectPosition(
                        position, stopLoss: sl, takeProfit: tp,
                        slippageBps: min(50, market.maxMarketSlippageBps))
                    if saved { onDone() }
                }
            } label: {
                Text("Save protection").font(DeskType.label).frame(maxWidth: .infinity).frame(height: 52)
            }
            .buttonStyle(.borderedProminent).tint(DeskColor.rise.color).disabled(!valid)
        }
        .padding(20).foregroundStyle(DeskColor.nightText.color).background(DeskColor.night.color)
        .presentationDetents([.large]).presentationDragIndicator(.hidden)
    }

    private func triggerField(_ label: String, text: Binding<String>, tint: DeskRGB) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(DeskType.label)
            TextField("Price", text: text)
                .keyboardType(.decimalPad).font(DeskType.title).monospacedDigit()
                .padding(.horizontal, 16).frame(height: 56)
                .background(DeskColor.nightChip.color, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(tint.color.opacity(0.55)))
        }
    }
}

/// A position is identified by the venue's own position id, so a sheet can be presented
/// from the value itself rather than from a flag beside it.
extension PerplPosition: @retroactive Identifiable {
    public var id: Int64 { positionID }
}
