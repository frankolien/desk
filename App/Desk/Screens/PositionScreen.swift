import DeskPerpl
import DeskMoney
import DeskUI
import SwiftUI

/// One held position, in full.
///
/// The chart comes first and carries the position on it: entry, liquidation, and the
/// mark moving between them. A row of figures can say the liquidation price is 75,080,
/// but only the chart says whether the last hour has been walking toward it — and that
/// is the question someone opens a position they already hold to answer.
struct PositionScreen: View {
    let position: PerplPosition
    let market: MarketModel
    let session: TradingSession
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showsClose = false
    @State private var showsProtection = false
    @State private var tab: PositionTab = .positions
    /// Which position the screen is showing. Starts at the one that was tapped.
    @State private var focusedID: Int64?

    private var active: PerplPosition {
        model.openPositions.first { $0.positionID == focusedID } ?? position
    }

    private var others: [PerplPosition] {
        model.openPositions.filter { $0.positionID != active.positionID }
    }

    private var figures: PositionFigures? {
        guard active.marketID == market.market?.id,
              let config = market.market?.config,
              let mark = market.mark.value else { return nil }
        return PositionFigures(position: active, market: config, mark: mark)
    }

    private var stale: Bool { market.freshness.freezesDigits }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let figures { content(figures) } else { unavailable }
            }
            // Dismissal lives in the heading instead.
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showsClose) {
                if let figures, let selected = market.market {
                    MarketCloseSheet(
                        position: active, figures: figures, market: selected,
                        session: session) { showsClose = false }
                }
            }
            .sheet(isPresented: $showsProtection) {
                if let figures, let selected = market.market {
                    PositionProtectionSheet(
                        position: active, figures: figures, market: selected,
                        session: session) { showsProtection = false }
                }
            }
        }
    }

    /// Actions stay pinned: closing is what a person opens a held position to do, and the
    /// figures alone are taller than the screen.
    private func content(_ figures: PositionFigures) -> some View {
        ZStack(alignment: .bottom) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    heading
                    priceBlock.padding(.top, 20)
                    chart(figures).padding(.top, 20)
                    CandleIntervalRail(market: market).padding(.top, 14)
                    tabStrip.padding(.top, 20)
                    tabContent(figures).padding(.top, 16)

                    if let status = session.statusText {
                        Text(status)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(session.hasFailed ? DeskColor.fall.color : DeskColor.nightMuted.color)
                            .padding(.top, 14)
                    }
                }
                .foregroundStyle(DeskColor.nightText.color)
                .padding(.horizontal, 16)
                .padding(.bottom, tab == .positions ? 104 : 28)
            }

            // A close button has nothing to act on outside the positions tab.
            if tab == .positions { actionBar }
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 0) {
            ForEach(PositionTab.allCases) { item in
                Button { withAnimation(.easeOut(duration: 0.18)) { tab = item } } label: {
                    Text(title(for: item))
                        .font(.system(size: 13, weight: tab == item ? .bold : .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(tab == item ? Color.white.opacity(0.24) : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.11), in: Capsule())
    }

    private func title(for item: PositionTab) -> String {
        switch item {
        case .positions:
            let count = model.openPositions.count
            return count > 0 ? "Positions (\(count))" : "Positions"
        case .orders: return "Open Orders"
        case .history: return "History"
        }
    }

    @ViewBuilder
    private func tabContent(_ figures: PositionFigures) -> some View {
        switch tab {
        case .positions: positions(figures)
        case .orders: orders
        case .history: history
        }
    }

    /// The focused position in full, then the rest of the account's. The tab counts them
    /// all, so it has to show them all.
    private func positions(_ figures: PositionFigures) -> some View {
        VStack(spacing: 12) {
            card(figures)
            ForEach(others, id: \.positionID) { held in
                if let itsMarket = market.market(id: held.marketID),
                   let mark = market.price(for: itsMarket),
                   let itsFigures = PositionFigures(
                    position: held, market: itsMarket.config, mark: mark) {
                    OpenPositionCard(
                        figures: itsFigures, symbol: itsMarket.symbol, isStale: stale
                    ) {
                        focusedID = held.positionID
                        market.select(itsMarket)
                        Task { await session.selectMarket(itsMarket) }
                    }
                }
            }
        }
    }

    // MARK: Open orders

    /// Desk has no resting-order feed: order frames are read only to correlate an order
    /// with its outcome, and triggers are held by the venue. An empty table would claim
    /// the account has none, which Desk cannot know.
    private var orders: some View {
        VStack(spacing: 12) {
            if let status = session.statusText, session.isBusy {
                HStack(spacing: 12) {
                    ProgressView().tint(DeskColor.nightMuted.color)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Order in flight")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                        Text(status)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(DeskColor.nightMuted.color)
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(DeskColor.nightMuted.color)
                    Text("Nothing resting")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("Desk sends market orders, which fill or fail straight away. "
                         + "Take profit and stop loss are held by Perpl, not listed here yet.")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
                .padding(.horizontal, 20)
            }
        }
        .deskGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    // MARK: History

    private var history: some View {
        VStack(spacing: 0) {
            if model.closedPositions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(DeskColor.nightMuted.color)
                    Text("No closed positions")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("Positions you close appear here with what they made or lost.")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
                .padding(.horizontal, 20)
            } else {
                ForEach(Array(model.closedPositions.enumerated()), id: \.element.positionID) { index, closed in
                    ClosedPositionRow(
                        position: closed,
                        symbol: market.market(id: closed.marketID)?.symbol ?? Unavailable.text,
                        priceDecimals: market.market(id: closed.marketID)?.config.priceDecimals)
                    if index < model.closedPositions.count - 1 {
                        Divider().overlay(Color.white.opacity(0.08)).padding(.horizontal, 16)
                    }
                }
            }
        }
        .deskGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            actionButton("Add TP/SL", tint: DeskColor.nightText) { showsProtection = true }
            actionButton(session.isBusy ? "Closing…" : "Close", tint: DeskColor.fall) {
                showsClose = true
            }
        }
        .disabled(session.isBusy)
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
        .background {
            // The card passes under this bar as it scrolls. Without a fade its figures
            // show through the glass and read as colliding with the buttons rather than
            // sitting behind them.
            LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0.9), .black],
                startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
        }
    }

    // MARK: Heading

    private var heading: some View {
        HStack(spacing: 11) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .deskGlass(interactive: true, in: Circle())
            .accessibilityLabel("Close")

            VStack(alignment: .leading, spacing: 3) {
                Text("\(market.symbol)-PERP")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                Text("Your position")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
            Spacer(minLength: 8)
        }
        .padding(.top, 10)
    }

    private func sideTint(_ figures: PositionFigures) -> DeskRGB {
        figures.side == .long ? DeskColor.rise : DeskColor.fall
    }

    private var priceBlock: some View {
        VStack(alignment: .leading, spacing: 7) {
            AmountText(market.markText == "—" ? "—" : "$" + market.markText, size: 38)
                .contentTransition(.numericText())
            HStack(spacing: 8) {
                Text(market.changePercentText ?? "—")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(market.trend.color)
                Text(stale ? "LAST KNOWN" : "LIVE")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.16)))
            }
        }
        .opacity(stale ? 0.7 : 1)
    }

    // MARK: Chart

    /// Amber under five percent of room, red under two: the same thresholds the position
    /// rows use, so a line and a row never disagree about how close it is.
    private func liquidationTint(_ figures: PositionFigures) -> DeskRGB {
        guard let distance = figures.liquidationDistanceMicros else { return DeskColor.nightMuted }
        switch distance {
        case ..<20_000: return DeskColor.fall
        case ..<50_000: return DeskColor.action
        default: return DeskColor.nightMuted
        }
    }

    private func guides(_ figures: PositionFigures) -> [PriceGuide] {
        var guides = [PriceGuide(
            label: "Entry",
            raw: figures.entry.raw,
            text: figures.entry.display(fractionDigits: figures.entry.decimals),
            tint: DeskColor.nightText.color)]
        if let liquidation = figures.liquidationPrice {
            guides.append(PriceGuide(
                label: "\(figures.side == .long ? "Long" : "Short") Liq.",
                raw: liquidation.raw,
                text: liquidation.display(fractionDigits: figures.entry.decimals),
                tint: liquidationTint(figures).color))
        }
        return guides
    }

    @ViewBuilder
    private func chart(_ figures: PositionFigures) -> some View {
        if !market.candles.isEmpty, let config = market.market?.config {
            CandlestickChart(
                candles: market.candles,
                priceDecimals: Int(config.priceDecimals),
                guides: guides(figures))
                .frame(height: 250)
                .overlay(alignment: .bottom) { Divider().overlay(Color.white.opacity(0.12)) }
        } else {
            VStack(spacing: 18) {
                SkeletonRow(widthFraction: 0.88)
                SkeletonRow(widthFraction: 0.64)
                SkeletonRow(widthFraction: 0.76)
            }
            .frame(height: 250)
        }
    }

    // MARK: Figures

    /// What the position is worth at the current mark. Not the collateral, and not the
    /// size: the number a person means when they ask how big the position is.
    private func value(_ figures: PositionFigures) -> Money? {
        Money.notional(price: figures.mark, size: figures.size, rounding: .towardZero)
    }

    private func card(_ figures: PositionFigures) -> some View {
        VStack(spacing: 0) {
            cardHeader(figures)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 14)

            VStack(spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    metric("Value", value(figures).map { "$" + $0.display() } ?? Unavailable.text,
                           isDimmed: stale)
                    metric("PnL",
                           (figures.unrealisedPnL.isNegative ? "" : "+")
                               + figures.unrealisedPnL.display() + " AUSD",
                           detail: HomeScreen.percent(figures.returnOnMarginMicros) + " on margin",
                           tint: figures.isProfit ? DeskColor.rise : DeskColor.fall,
                           alignment: .trailing, isDimmed: stale)
                }
                HStack(alignment: .top, spacing: 12) {
                    metric("Entry / Mark",
                           figures.entry.display(fractionDigits: figures.entry.decimals)
                               + " / " + figures.mark.display(fractionDigits: figures.mark.decimals),
                           isDimmed: stale)
                    metric("Liq. Price",
                           figures.liquidationPrice?.display(fractionDigits: figures.entry.decimals)
                               ?? Unavailable.text,
                           detail: figures.liquidationDistanceMicros.map {
                               $0 == 0 ? "At liquidation" : HomeScreen.percent($0, signed: false) + " away"
                           },
                           tint: liquidationTint(figures),
                           alignment: .trailing, isDimmed: stale)
                }
                HStack(alignment: .top, spacing: 12) {
                    metric("Size",
                           figures.size.display(fractionDigits: figures.size.decimals)
                               + " " + market.symbol)
                    metric("Collateral", figures.collateral.display() + " AUSD",
                           alignment: .trailing)
                }
                HStack(alignment: .top, spacing: 12) {
                    metric("Funding",
                           figures.fundingSinceEntry.map { $0.display() + " AUSD" } ?? Unavailable.text,
                           detail: "since you opened")
                    metric("Fees",
                           Money(raw: active.feeRaw).map { $0.display() + " AUSD" }
                               ?? Unavailable.text,
                           detail: "charged so far",
                           alignment: .trailing)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .deskGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    /// The market, the side and the size of the bet, above the figures — so the card can
    /// be read on its own once the History tab has scrolled the heading away.
    private func cardHeader(_ figures: PositionFigures) -> some View {
        HStack(spacing: 9) {
            MarketTokenLogo(symbol: market.symbol, size: 30)
            Text(market.symbol)
                .font(.system(size: 15, weight: .bold, design: .rounded))
            Text("\(figures.leverageHundredths / 100)× \(figures.side == .long ? "Long" : "Short")")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(sideTint(figures).color)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(sideTint(figures).color.opacity(0.14), in: Capsule())
            Spacer(minLength: 8)
            // Not a button yet: a control that looks live and answers nothing is worse.
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(DeskColor.nightMuted.color)
                .frame(width: 30, height: 30)
                .background(Color.white.opacity(0.08), in: Circle())
                .accessibilityHidden(true)
        }
    }

    private func metric(
        _ label: String,
        _ value: String,
        detail: String? = nil,
        tint: DeskRGB = DeskColor.nightText,
        alignment: HorizontalAlignment = .leading,
        isDimmed: Bool = false
    ) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(DeskColor.nightMuted.color)
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(tint.color)
                .contentTransition(.numericText())
            if let detail {
                Text(detail)
                    .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
        }
        .frame(maxWidth: .infinity,
               alignment: alignment == .leading ? .leading : .trailing)
        .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
        .opacity(isDimmed ? 0.55 : 1)
        .accessibilityElement(children: .combine)
    }

    private func actionButton(
        _ title: String,
        tint: DeskRGB,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(tint.color)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
        }
        .buttonStyle(.plain)
        .deskGlass(interactive: true, in: Capsule())
    }

    private var unavailable: some View {
        ContentUnavailableView("Position unavailable", systemImage: "chart.xyaxis.line",
            description: Text("Waiting for the authenticated Perpl position stream."))
            .foregroundStyle(DeskColor.nightText.color)
    }
}

enum PositionTab: String, CaseIterable, Identifiable {
    case positions, orders, history
    var id: String { rawValue }
}

/// One closed position. The realised figure is the venue's own `dpnl`, never recomputed:
/// once closed there is no mark to derive it from.
private struct ClosedPositionRow: View {
    let position: PerplPosition
    let symbol: String
    let priceDecimals: UInt8?

    private var realised: Money? { position.realisedPnLRaw.flatMap { Money(raw: $0) } }

    private func price(_ raw: Int64?) -> String {
        guard let raw, let priceDecimals,
              let value = Price(raw: raw, decimals: priceDecimals) else { return Unavailable.text }
        return value.display(fractionDigits: priceDecimals)
    }

    var body: some View {
        HStack(spacing: 11) {
            MarketTokenLogo(symbol: symbol, size: 30)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("\(position.side == .long ? "Long" : "Short") \(symbol)")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                    Text("\(position.leverageHundredths / 100)×")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.1), in: Capsule())
                }
                Text(price(position.entryRaw) + " → " + price(position.exitRaw))
                    .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(realised.map { ($0.isNegative ? "" : "+") + $0.display() + " AUSD" }
                     ?? Unavailable.text)
                    .font(.system(size: 14, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle((realised.map { $0.isNegative ? DeskColor.fall : DeskColor.rise }
                                      ?? DeskColor.nightMuted).color)
                Text("realised")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
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
