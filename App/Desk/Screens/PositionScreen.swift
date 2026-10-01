import DeskPerpl
import DeskMoney
import DeskUI
import PhotosUI
import SwiftUI
import UIKit

struct PositionScreen: View {
    let position: PerplPosition
    let market: MarketModel
    let session: TradingSession
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showsClose = false
    @State private var showsProtection = false
    @State private var protectionPreset = ("", "")
    @State private var showsShare = false
    @State private var showsStudio = false
    @State private var tab: PositionTab = .positions
    @State private var focusedID: Int64?
    @State private var focusedLong: Bool?

    private var activeID: Int64 { focusedID ?? position.positionID }

    private var active: PerplPosition {
        model.openPositions.first { $0.positionID == activeID } ?? position
    }

    private var isClosed: Bool {
        model.trading.positions.value != nil && !model.openPositions.contains { $0.positionID == activeID }
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
                if isClosed { closedView } else if let figures { content(figures) } else { unavailable }
            }
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: isClosed) { _, closed in
                guard closed else { return }
                showsClose = false
                showsProtection = false
            }
            .sheet(isPresented: $showsClose) {
                if let figures, let selected = market.market {
                    MarketCloseSheet(
                        position: active, figures: figures, market: selected, session: session,
                        book: market.book.isReady ? market.book : nil) { showsClose = false }
                }
            }
            .sheet(isPresented: $showsProtection) {
                if let figures, let selected = market.market {
                    PositionProtectionSheet(
                        position: active, figures: figures, market: selected,
                        session: session, presetTakeProfit: protectionPreset.0,
                        presetStopLoss: protectionPreset.1) { showsProtection = false }
                }
            }
            #if DEBUG
            .task {
                if ProcessInfo.processInfo.arguments.contains("-open-share") {
                    try? await Task.sleep(for: .seconds(2))
                    showsShare = true
                }
                if ProcessInfo.processInfo.arguments.contains("-open-close") {
                    try? await Task.sleep(for: .seconds(2))
                    showsClose = true
                }
            }
            #endif
            .sheet(isPresented: $showsShare) {
                if let figures {
                    TradeShareSheet(symbol: market.symbol, figures: figures)
                }
            }
            .fullScreenCover(isPresented: $showsStudio) {
                let scale = pow(10.0, Double(market.market?.config.priceDecimals ?? 0))
                ChartStudio(market: market, network: model.network.name,
                            guides: figures.map { guides($0, scale: scale) } ?? [],
                            heldSide: figures.map { $0.side == .long ? .up : .down },
                            onProtect: { takeProfit, stopLoss in
                                showsStudio = false
                                Task {
                                    try? await Task.sleep(for: .milliseconds(550))
                                    protectionPreset = (takeProfit ?? "", stopLoss ?? "")
                                    showsProtection = true
                                }
                            },
                            onClose: { showsStudio = false })
            }
        }
    }

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

            if tab == .positions { actionBar }
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 0) {
            ForEach(PositionTab.allCases.filter { Showcase.openOrders || $0 != .orders }) { item in
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
                        focusedLong = held.side == .long
                        market.select(itsMarket)
                        Task { await session.selectMarket(itsMarket) }
                    }
                }
            }
        }
    }

    /// Desk has no resting-order feed, so an empty table would claim the account has none,
    /// which Desk cannot know.
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

    private var history: some View {
        VStack(spacing: 0) {
            if model.closedTrades.isEmpty {
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
                ForEach(Array(model.closedTrades.enumerated()), id: \.element.positionID) { index, closed in
                    ClosedPositionRow(
                        position: closed,
                        symbol: market.market(id: closed.marketID)?.symbol ?? Unavailable.text,
                        priceDecimals: market.market(id: closed.marketID)?.config.priceDecimals)
                    if index < model.closedTrades.count - 1 {
                        Divider().overlay(Color.white.opacity(0.08)).padding(.horizontal, 16)
                    }
                }
            }
        }
        .deskGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            actionButton("Add TP/SL", tint: DeskColor.nightText) { protectionPreset = ("", ""); showsProtection = true }
            actionButton(session.isBusy ? "Closing…" : "Close", tint: DeskColor.fall) {
                showsClose = true
            }
        }
        .disabled(session.isBusy)
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
        .background {
            LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0.9), .black],
                startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
        }
    }

    private var heading: some View {
        HStack(spacing: 11) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 38, height: 38)
                    .contentShape(Circle())
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

    /// The same thresholds as the position rows, so a line and a row never disagree.
    private func liquidationTint(_ figures: PositionFigures) -> DeskRGB {
        guard let distance = figures.liquidationDistanceMicros else { return DeskColor.nightMuted }
        switch distance {
        case ..<20_000: return DeskColor.fall
        case ..<50_000: return DeskColor.action
        default: return DeskColor.nightMuted
        }
    }

    private func guides(_ figures: PositionFigures, scale: Double) -> [PriceGuide] {
        var guides = [PriceGuide(
            label: "Entry",
            value: Double(figures.entry.raw) / scale,
            text: figures.entry.display(fractionDigits: figures.entry.decimals),
            tint: DeskColor.nightText.color)]
        if let liquidation = figures.liquidationPrice {
            guides.append(PriceGuide(
                label: "\(figures.side == .long ? "Long" : "Short") Liq.",
                value: Double(liquidation.raw) / scale,
                text: liquidation.display(fractionDigits: figures.entry.decimals),
                tint: liquidationTint(figures).color))
        }
        return guides
    }

    @ViewBuilder
    private func chart(_ figures: PositionFigures) -> some View {
        if !market.candles.isEmpty, let config = market.market?.config {
            let scale = pow(10.0, Double(config.priceDecimals))
            CandlestickChart(
                candles: market.candles.map { $0.chartCandle(scale: scale) },
                guides: guides(figures, scale: scale))
                .frame(height: 250)
                .overlay(alignment: .bottom) { Divider().overlay(Color.white.opacity(0.12)) }
                .overlay(alignment: .topTrailing) { ChartExpandButton { showsStudio = true } }
        } else {
            VStack(spacing: 18) {
                SkeletonRow(widthFraction: 0.88)
                SkeletonRow(widthFraction: 0.64)
                SkeletonRow(widthFraction: 0.76)
            }
            .frame(height: 250)
        }
    }

    /// An estimate at the taker rate, not a quote: Perpl has charged closes since contract 1.7.5.
    private func exitFee(_ figures: PositionFigures) -> Money? {
        guard let taker = market.market?.config.takerFeeMicros, taker > 0,
              let notional = Money.notional(price: figures.mark, size: figures.size, rounding: .towardZero)
        else { return nil }
        return Money(raw: Int64((Int128(notional.raw) * Int128(taker) / 1_000_000)))
    }

    private func value(_ figures: PositionFigures) -> Money? {
        Money.notional(price: figures.mark, size: figures.size, rounding: .towardZero)
    }

    private func card(_ figures: PositionFigures) -> some View {
        PositionCard(
            symbol: market.symbol,
            sideText: "\(figures.leverageHundredths / 100)× \(figures.side == .long ? "Long" : "Short")",
            isLong: figures.side == .long,
            rows: [
                (PositionCardMetric(label: "Value", value: value(figures).map { DisplayCurrency.shared.format($0) } ?? Unavailable.text, isDimmed: stale),
                 PositionCardMetric(label: "PnL",
                                    value: (figures.unrealisedPnL.isNegative ? "" : "+") + figures.unrealisedPnL.display() + " AUSD",
                                    detail: HomeScreen.percent(figures.returnOnMarginMicros) + " on margin",
                                    tint: figures.isProfit ? DeskColor.rise : DeskColor.fall, isDimmed: stale)),
                (PositionCardMetric(label: "Entry / Mark",
                                    value: figures.entry.display(fractionDigits: figures.entry.decimals) + " / " + figures.mark.display(fractionDigits: figures.mark.decimals),
                                    isDimmed: stale),
                 PositionCardMetric(label: "Liq. Price",
                                    value: figures.liquidationPrice?.display(fractionDigits: figures.entry.decimals) ?? Unavailable.text,
                                    detail: figures.liquidationDistanceMicros.map { $0 == 0 ? "At liquidation" : HomeScreen.percent($0, signed: false) + " away" },
                                    tint: liquidationTint(figures), isDimmed: stale)),
                (PositionCardMetric(label: "Size", value: figures.size.display(fractionDigits: figures.size.decimals) + " " + market.symbol),
                 PositionCardMetric(label: "Collateral", value: figures.collateral.display() + " AUSD")),
                (PositionCardMetric(label: "Funding", value: figures.fundingSinceEntry.map { $0.display() + " AUSD" } ?? Unavailable.text, detail: "since you opened"),
                 PositionCardMetric(label: "Fees", value: Money(raw: active.feeRaw).map { $0.display() + " AUSD" } ?? Unavailable.text,
                                    detail: exitFee(figures).map { "on entry · exit ≈ \($0.display())" } ?? "on entry")),
            ]) {
            PositionCardShareButton { showsShare = true }
        }
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
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .deskGlass(interactive: true, in: Capsule())
    }

    private var closedView: some View {
        let trade = model.closedTrades.first { $0.positionID == activeID }
        let pnl = trade?.realisedPnLRaw.flatMap { Money(raw: $0) }
        return VStack(alignment: .leading, spacing: 0) {
            heading
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(DeskColor.rise.color)
                Text("Position closed")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("\((trade?.isLong ?? focusedLong ?? (position.side == .long)) ? "Long" : "Short") \(market.symbol)")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
                if let pnl {
                    Text((pnl.isNegative ? "" : "+") + pnl.display() + " AUSD")
                        .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle((pnl.isNegative ? DeskColor.fall : DeskColor.rise).color)
                        .padding(.top, 6)
                    Text("Realised PnL, as Perpl reports it")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                }
            }
            .padding(.top, 36)
            Spacer()
            Button { dismiss() } label: {
                Text("Done").font(DeskType.label).frame(maxWidth: .infinity).frame(height: 52)
            }
            .buttonStyle(.borderedProminent)
            .tint(DeskColor.nightChip.color)
        }
        .foregroundStyle(DeskColor.nightText.color)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
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

/// The realised figure is the venue's own `dpnl`: once closed there is no mark to derive it from.
private struct ClosedPositionRow: View {
    let position: ClosedTrade
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
                    Text("\(position.isLong ? "Long" : "Short") \(symbol)")
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
    var book: OrderBook?
    let onDone: () -> Void
    @State private var percentage = 100

    private var closeSize: Size? {
        let raw = Int128(figures.size.raw) * Int128(percentage) / 100
        return Int64(exactly: raw).flatMap {
            Size(raw: max(1, $0), decimals: figures.size.decimals)
        }
    }

    /// What the book holds for this close within its slippage bound; nil when the book isn't live.
    private var bookFill: OrderBook.FillEstimate? {
        guard let closeSize, let book, book.isReady, (book.spreadRaw ?? 1) > 0 else { return nil }
        let mark = Double(figures.mark.raw)
        let selling = figures.side == .long
        let bound = mark * (1 + (selling ? -slippageBps : slippageBps) / 10_000)
        return book.estimateFill(buying: !selling, sizeRaw: closeSize.raw,
                                 limitRaw: Int64(bound.rounded(selling ? .up : .down)))
    }

    private var slippageBps: Double { Double(min(50, market.maxMarketSlippageBps)) }

    /// The part that fills: all of it at the mark when there's no live book, otherwise only
    /// what the book holds within the bound, since the rest is cancelled.
    private var fillingRaw: Int64? {
        guard let closeSize else { return nil }
        guard let bookFill else { return closeSize.raw }
        return bookFill.averagePriceRaw == nil ? closeSize.raw : bookFill.filledRaw
    }

    private var exitRaw: Double? {
        guard closeSize != nil else { return nil }
        return bookFill?.averagePriceRaw ?? Double(figures.mark.raw)
    }

    private var thinBookLine: String? {
        guard let bookFill, let closeSize, !bookFill.isComplete else { return nil }
        let limit = String(format: "%.2f%%", slippageBps / 100)
        guard bookFill.averagePriceRaw != nil, let held = market.size(bookFill.filledRaw) else {
            return "Nothing on the book within \(limit). This close may not fill."
        }
        return "Only \(held.display(fractionDigits: held.decimals)) of \(closeSize.display(fractionDigits: closeSize.decimals)) \(market.symbol) would close within \(limit). The rest stays open."
    }

    private var estimate: (back: Money?, pnl: Money?, fee: Money?, exit: String)? {
        guard let closeSize, let exitRaw, let fillingRaw else { return nil }
        let priceScale = pow(10, Double(figures.mark.decimals))
        let size = Double(fillingRaw) / pow(10, Double(closeSize.decimals))
        let exit = exitRaw / priceScale
        let entry = Double(figures.entry.raw) / pow(10, Double(figures.entry.decimals))
        let pnl = (figures.side == .long ? exit - entry : entry - exit) * size
        let fee = exit * size * Double(market.config.takerFeeMicros) / 1_000_000
        let share = figures.size.raw > 0
            ? Double(figures.collateral.raw) / 1_000_000 * Double(fillingRaw) / Double(figures.size.raw) : 0
        func money(_ value: Double) -> Money? { Money(raw: Int64((value * 1_000_000).rounded())) }
        let exitText = Price(raw: Int64(exitRaw.rounded()), decimals: figures.mark.decimals)?
            .display(fractionDigits: figures.mark.decimals) ?? Unavailable.text
        return (money(share + pnl - fee), money(pnl), money(fee), exitText)
    }

    private var closingHere: Bool { session.orderOrigin == .close(market: position.marketID) }

    var body: some View {
        VStack(spacing: 20) {
            Capsule().fill(DeskColor.nightMuted.color.opacity(0.5)).frame(width: 44, height: 5)
            Text("Close \(figures.side == .long ? "Long" : "Short") \(market.symbol)").font(DeskType.title)
            VStack(spacing: 8) {
                Text("You get back").font(DeskType.caption).foregroundStyle(DeskColor.nightMuted.color)
                Text(estimate?.back.map { "≈ " + $0.display() + " AUSD" } ?? Unavailable.text)
                    .font(.system(size: 38, weight: .bold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("\(percentage)% of the position")
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
                ValueRow(label: "Closing", value: (closeSize?.display(fractionDigits: figures.size.decimals) ?? Unavailable.text) + " " + market.symbol)
                ValueRow(label: "Est. exit", value: estimate?.exit ?? Unavailable.text,
                         detail: bookFill?.averagePriceRaw == nil ? "at mark" : "from the live book")
                ValueRow(label: "PnL on this part",
                         value: estimate?.pnl.map { ($0.isNegative ? "" : "+") + $0.display() + " AUSD" } ?? Unavailable.text,
                         tint: estimate?.pnl?.isNegative == true ? DeskColor.fall : DeskColor.rise)
                ValueRow(label: "Fee", value: estimate?.fee.map { $0.display() + " AUSD" } ?? Unavailable.text)
            }
            .padding(16).background(DeskColor.nightChip.color, in: RoundedRectangle(cornerRadius: 18))
            Spacer()
            if let thinBookLine {
                Text(thinBookLine)
                    .font(DeskType.caption)
                    .foregroundStyle(DeskColor.action.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if session.hasFailed, closingHere, let reason = session.statusText {
                Text(reason)
                    .font(DeskType.caption)
                    .foregroundStyle(DeskColor.fall.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HoldToConfirm(
                title: session.isBusy && closingHere ? "Closing…" : "Hold to close \(percentage)%",
                tint: DeskColor.fall,
                isEnabled: closeSize != nil && !session.isBusy
            ) {
                guard let closeSize else { return }
                Task {
                    await session.closePosition(
                        position, size: closeSize,
                        slippageBps: min(50, market.maxMarketSlippageBps), in: market)
                    if !session.hasFailed { onDone() }
                }
            }
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
    var presetTakeProfit = ""
    var presetStopLoss = ""
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
            if let problem = session.protectionProblem {
                Text(problem)
                    .font(DeskType.caption)
                    .foregroundStyle(DeskColor.fall.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                Task {
                    let saved = await session.protectPosition(
                        position, stopLoss: sl, takeProfit: tp,
                        slippageBps: min(50, market.maxMarketSlippageBps), in: market)
                    if saved { onDone() }
                }
            } label: {
                Text("Save protection").font(DeskType.label).frame(maxWidth: .infinity).frame(height: 52)
            }
            .buttonStyle(.borderedProminent).tint(DeskColor.rise.color).disabled(!valid)
        }
        .onAppear { session.clearProtectionProblem() }
        .padding(20).foregroundStyle(DeskColor.nightText.color).background(DeskColor.night.color)
        .presentationDetents([.large]).presentationDragIndicator(.hidden)
        .onAppear {
            if takeProfit.isEmpty { takeProfit = presetTakeProfit }
            if stopLoss.isEmpty { stopLoss = presetStopLoss }
        }
        .onAppear {
            if takeProfit.isEmpty { takeProfit = presetTakeProfit }
            if stopLoss.isEmpty { stopLoss = presetStopLoss }
        }
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

extension PerplPosition: @retroactive Identifiable {
    public var id: Int64 { positionID }
}

private struct TradeShareSheet: View {
    let symbol: String
    let figures: PositionFigures

    @Environment(\.dismiss) private var dismiss
    @State private var photoItem: PhotosPickerItem?
    @State private var photo: UIImage?
    @State private var rendered: UIImage?
    @State private var presentsActivity = false
    @State private var saveNotice: String?
    @State private var saver = PhotoSaver()

    var body: some View {
        NavigationStack {
            ZStack {
                DeskColor.night.color.ignoresSafeArea()
                GeometryReader { proxy in
                    let usableWidth = proxy.size.width - 28
                    let controlsHeight: CGFloat = 174
                    let cardHeight = min(usableWidth * 1.25, proxy.size.height - controlsHeight)
                    let cardWidth = cardHeight * 0.8

                    VStack(spacing: 10) {
                        ShareCardPreview(
                            symbol: symbol, figures: figures, photo: photo,
                            width: cardWidth, height: cardHeight)
                            .frame(maxWidth: .infinity)

                        backgroundPicker

                        HStack(spacing: 10) {
                            Button(action: save) {
                                Label("Save", systemImage: "square.and.arrow.down")
                                    .font(.system(size: 16, weight: .bold, design: .rounded))
                                    .frame(maxWidth: .infinity).frame(height: 48)
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(DeskColor.nightText.color)
                            .background(DeskColor.nightChip.color, in: Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(0.12)))

                            Button {
                                rendered = render()
                                presentsActivity = rendered != nil
                            } label: {
                                Label("Share", systemImage: "square.and.arrow.up")
                                    .font(.system(size: 16, weight: .bold, design: .rounded))
                                    .frame(maxWidth: .infinity).frame(height: 48)
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(DeskColor.night.color)
                            .background(DeskColor.action.color, in: Capsule())
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle("Share position")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(DeskColor.action.color)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let selected = UIImage(data: data) else { return }
                photo = selected
            }
        }
        #if DEBUG
        .task {
            if ProcessInfo.processInfo.arguments.contains("-share-photo") {
                photo = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 700)).image { context in
                    UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 300, height: 700))
                    UIColor.systemOrange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 300, height: 120))
                }
            }
        }
        #endif
        .sheet(isPresented: $presentsActivity) {
            if let rendered { ActivitySheet(items: [rendered]) }
        }
        .overlay(alignment: .top) {
            if let saveNotice {
                Label(saveNotice, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private func save() {
        guard let image = render() else { return }
        saver.save(image) { saved in
            withAnimation(.snappy) {
                saveNotice = saved ? "Saved to Photos" : "Allow Photos access in Settings to save"
            }
            Task {
                try? await Task.sleep(for: .seconds(2))
                withAnimation(.snappy) { saveNotice = nil }
            }
        }
    }

    private var backgroundPicker: some View {
        let hasPhoto = photo != nil
        return VStack(alignment: .leading, spacing: 10) {
            Text("BACKGROUND")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(1.1)
                .foregroundStyle(DeskColor.nightMuted.color)
            HStack(spacing: 12) {
                Button { photo = nil; photoItem = nil } label: {
                    backgroundTile(image: Image("TradeShareCardBackground"), selected: photo == nil)
                }
                .buttonStyle(.plain)

                PhotosPicker(selection: $photoItem, matching: .images) {
                    SharePhotoTile(selected: hasPhoto)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func backgroundTile(image: Image, selected: Bool) -> some View {
        image.resizable().scaledToFill()
            .frame(width: 106, height: 68).clipped()
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16)
                .stroke(selected ? DeskColor.action.color : Color.white.opacity(0.1), lineWidth: 2))
    }

    @MainActor private func render() -> UIImage? {
        let card = TradeShareCard(symbol: symbol, figures: figures, photo: photo)
            .frame(width: 900, height: 1125)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 1
        renderer.isOpaque = true
        return renderer.uiImage
    }
}

private struct ShareCardPreview: View {
    let symbol: String
    let figures: PositionFigures
    let photo: UIImage?
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        TradeShareCard(symbol: symbol, figures: figures, photo: photo)
            .frame(width: 900, height: 1125)
            .scaleEffect(width / 900, anchor: .topLeading)
            .frame(width: width, height: height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(0.1)))
    }
}

private struct SharePhotoTile: View {
    let selected: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 16)
                .fill(DeskColor.nightChip.color)
                .overlay {
                    VStack(spacing: 7) {
                        Image(systemName: selected ? "photo.fill" : "photo.on.rectangle.angled")
                        Text(selected ? "Photo selected" : "Your photo")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(selected ? DeskColor.nightText.color : DeskColor.nightMuted.color)
                }
                .overlay(RoundedRectangle(cornerRadius: 16)
                    .stroke(selected ? DeskColor.action.color : Color.white.opacity(0.1), lineWidth: 2))
            Image(systemName: "pencil")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 28, height: 28)
                .foregroundStyle(DeskColor.night.color)
                .background(DeskColor.action.color, in: Circle())
                .padding(7)
        }
        .frame(width: 106, height: 68)
    }
}

private struct TradeShareCard: View {
    let symbol: String
    let figures: PositionFigures
    let photo: UIImage?

    private var tint: Color { figures.isProfit ? DeskColor.rise.color : DeskColor.fall.color }
    private var pnl: String {
        (figures.unrealisedPnL.isNegative ? "" : "+") + figures.unrealisedPnL.display() + " AUSD"
    }
    private var notional: String {
        Money.notional(price: figures.mark, size: figures.size, rounding: .towardZero)
            .map { $0.display() + " AUSD" } ?? Unavailable.text
    }

    static let size = CGSize(width: 900, height: 1125)

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 18) {
                    DeskBrandMark(size: 68)
                    Text("DESK")
                        .font(.system(size: 34, weight: .black, design: .rounded))
                        .tracking(7)
                    Spacer()
                    Text(Date.now.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.58))
                }

                Spacer().frame(height: 92)

                HStack(spacing: 14) {
                    MarketTokenLogo(symbol: symbol, size: 54)
                    Text(symbol).font(.system(size: 36, weight: .black, design: .rounded))
                    Text(figures.side == .long ? "LONG" : "SHORT")
                        .font(.system(size: 18, weight: .black, design: .rounded))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(tint.opacity(0.16), in: Capsule())
                    Text("\(figures.leverageHundredths / 100)×")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.72))
                    Spacer()
                }

                Spacer().frame(height: 60)

                Text(pnl)
                    .font(.system(size: 74, weight: .black, design: .rounded).monospacedDigit())
                    .foregroundStyle(tint).minimumScaleFactor(0.55).lineLimit(1)
                Text(HomeScreen.percent(figures.returnOnMarginMicros) + " on margin")
                    .font(.system(size: 32, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(tint.opacity(0.92))
                    .padding(.top, 8)

                Spacer()

                HStack(spacing: 50) {
                    shareFact("MARK PRICE", "$" + figures.mark.display(fractionDigits: figures.mark.decimals))
                    shareFact("LEVERAGED SIZE", notional)
                }

                Rectangle().fill(DeskColor.action.color.opacity(0.6)).frame(height: 1)
                    .padding(.top, 40)

                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Trade from your desk.")
                            .font(.system(size: 25, weight: .bold, design: .rounded))
                        Text("Perpetuals secured by Face ID")
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.56))
                    }
                    Spacer()
                    AddressQR(address: "https://trydesk.trade/app/trade/\(symbol)", size: 80, label: "Code to open \(symbol) on Desk")
                }
                .padding(.top, 34)
            }
            .padding(58)
            .foregroundStyle(.white)
        }
        // The card's size is fixed and the background fills it from behind; as a ZStack sibling
        // a photo shaped unlike the card would set the stack's size and move every figure.
        .frame(width: Self.size.width, height: Self.size.height)
        .background {
            if let photo {
                Image(uiImage: photo).resizable().scaledToFill()
                    .frame(width: Self.size.width, height: Self.size.height)
                    .clipped()
                    .overlay { Color.black.opacity(0.58) }
                    .overlay {
                        LinearGradient(colors: [.black.opacity(0.08), .black.opacity(0.84)],
                                       startPoint: .top, endPoint: .bottom)
                    }
            } else {
                Image("TradeShareCardBackground").resizable().scaledToFill()
                    .frame(width: Self.size.width, height: Self.size.height)
                    .clipped()
            }
        }
        .clipped()
    }

    private func shareFact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 16, weight: .bold, design: .rounded))
                .tracking(1).foregroundStyle(Color.white.opacity(0.5))
            Text(value).font(.system(size: 27, weight: .bold, design: .rounded).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.7)
        }
    }
}

@MainActor
private final class PhotoSaver: NSObject {
    private var completion: ((Bool) -> Void)?

    func save(_ image: UIImage, completion: @escaping (Bool) -> Void) {
        self.completion = completion
        UIImageWriteToSavedPhotosAlbum(image, self, #selector(finished(_:didFinishSavingWithError:contextInfo:)), nil)
    }

    @objc nonisolated private func finished(
        _ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeRawPointer
    ) {
        let saved = error == nil
        Task { @MainActor in self.completion?(saved) }
    }
}

private struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
