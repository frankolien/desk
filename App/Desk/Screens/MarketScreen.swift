import DeskPerpl
import DeskUI
import SwiftUI

/// Perpetuals opens as an overview, matching the product hierarchy in the reference:
/// collateral, positions, then supported markets. Desk currently supports one live market,
/// so the list stays truthful rather than filling the design with invented feeds.
struct MarketScreen: View {
    let model: AppModel
    let market: MarketModel
    let session: TradingSession

    @State private var query = ""
    @State private var showsMarket = false
    @State private var showsPosition = false
    @State private var showsWithdraw = false
    @State private var showsFunding = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        searchField.padding(.top, 16)
                        collateralCard.padding(.top, 24)
                        Divider().overlay(Color.white.opacity(0.10)).padding(.top, 30)
                        positions.padding(.top, 16)
                        Divider().overlay(Color.white.opacity(0.10)).padding(.top, 26)
                        markets.padding(.top, 18)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 116)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showsMarket) {
                PerpDetailScreen(model: model, market: market, session: session)
                    .toolbar(.hidden, for: .tabBar)
            }
            .sheet(isPresented: $showsWithdraw) {
                WithdrawSheet(model: model) { showsWithdraw = false }
                    .presentationDetents([.large])
            }
            .sheet(isPresented: $showsPosition) {
                PositionScreen(model: model, isStale: market.freshness.freezesDigits)
            }
            .sheet(isPresented: $showsFunding) { AddFundsSheet(model: model) }
        }
    }

    /// A title and nothing else.
    ///
    /// There was a search button here, directly above the search field. A second entry
    /// point to a control already on screen is furniture — it costs a tap target, it
    /// implies a second behaviour that does not exist, and its absence is not missed.
    private var header: some View {
        Text("Perpetuals")
            .font(.system(size: 17, weight: .bold, design: .rounded))
            .foregroundStyle(DeskColor.nightText.color)
            .frame(height: 42)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(DeskColor.nightMuted.color)
            TextField("Search", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(DeskColor.nightText.color)
        }
        .font(.system(size: 15, weight: .medium, design: .rounded))
        .padding(.horizontal, 15)
        .frame(height: 44)
        .perpGlass(interactive: true, in: Capsule())
    }

    private var collateralCard: some View {
        HStack(spacing: 14) {
            TokenLogo(asset: .ausd, size: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text("Available")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
                Text("\(model.collateral.value?.display() ?? "—") AUSD")
                    .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(DeskColor.nightText.color)
            }

            Spacer()

            Button { showsWithdraw = true } label: {
                Image(systemName: "minus")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .perpGlass(interactive: true, in: Circle())

            Button { showsFunding = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .perpGlass(interactive: true, in: Circle())
        }
        .foregroundStyle(DeskColor.nightText.color)
        .padding(.horizontal, 16)
        .frame(height: 70)
        .perpGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    /// Derived at the point of display so that the header total, the PnL and the
    /// liquidation distance all descend from the one mark current when the screen drew.
    private var position: PositionFigures? {
        guard let held = model.openPosition,
              let mark = market.mark.value,
              let config = market.market?.config
        else { return nil }
        return PositionFigures(position: held, market: config, mark: mark)
    }

    private var positions: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Open Positions")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(DeskColor.nightMuted.color)

            // The header total is unrealised PnL, not notional. Notional is the number
            // that looks impressive and answers nothing; this is the one a person came
            // to see.
            Text(position.map { figures in
                (figures.unrealisedPnL.isNegative ? "" : "+") + "$" + figures.unrealisedPnL.display()
            } ?? "$0.00")
                .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle((position.map { $0.isProfit ? DeskColor.rise : DeskColor.fall }
                                  ?? DeskColor.nightText).color)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.25), value: position?.unrealisedPnL.raw)
                .padding(.top, 3)

            if let position {
                OpenPositionCard(
                    figures: position,
                    symbol: market.symbol,
                    isStale: market.freshness.freezesDigits) { showsPosition = true }
                    .padding(.top, 16)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "infinity")
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundStyle(DeskColor.nightMuted.color)
                    Text("No Open Positions")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                    Text("Choose a market below to open one")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 190)
            }
        }
    }

    private var markets: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MARKETS")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(0.9)
                .foregroundStyle(DeskColor.nightMuted.color)

            let visible = market.allMarkets.filter { item in
                query.isEmpty || item.symbol.localizedCaseInsensitiveContains(query)
            }
            if !visible.isEmpty {
                ForEach(visible, id: \.id) { item in
                Button {
                    market.select(item)
                    Task { await session.selectMarket(item) }
                    showsMarket = true
                } label: {
                    HStack(spacing: 12) {
                        MarketTokenLogo(symbol: item.symbol, size: 42)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.symbol)
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .foregroundStyle(DeskColor.nightText.color)
                            Text("MAX \(item.config.maxLeverage)×")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(DeskColor.nightMuted.color)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .overlay(Capsule().stroke(Color.white.opacity(0.13), lineWidth: 0.7))
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            let price = market.markText(for: item)
                            Text(price == "—" ? "—" : "$" + price)
                                .font(.system(size: 18, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle(DeskColor.nightText.color)
                            let change = market.changePercent(for: item)
                            Text(change.map { String(format: "%+.2f%%", $0) } ?? "—")
                                .font(.system(size: 14, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle((change ?? 0) >= 0 ? DeskColor.rise.color : DeskColor.fall.color)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
                }
            } else {
                Text("No supported market found")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
        }
    }
}

struct PerpDetailScreen: View {
    let model: AppModel
    let market: MarketModel
    /// Handed down rather than rebuilt: an order outlives the sheet that sent it, and a
    /// session created per presentation would lose the answer.
    let session: TradingSession

    @Environment(\.dismiss) private var dismiss
    @State private var ticket: Direction?
    @State private var pendingSide: Direction?

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    detailHeader
                    priceBlock.padding(.top, 42)
                    chart.padding(.top, 28)
                    ranges.padding(.top, 22)
                    stats.padding(.top, 34)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 110)
            }

            HStack(spacing: 10) {
                tradeButton(.up, title: "Long")
                tradeButton(.down, title: "Short")
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 12)
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $ticket) { side in
            TicketSheet(
                side: side, market: market.market, mark: market.mark.value, session: session
            ) {
                session.clear()
                ticket = nil
            }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $pendingSide) { side in
            LeverageExplainer(
                onAgree: {
                    model.hasSeenLeverageExplainer = true
                    pendingSide = nil
                    ticket = side
                },
                onBack: { pendingSide = nil })
        }
    }

    private var detailHeader: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
            .perpGlass(interactive: true, in: Circle())

            Spacer()


        }
        .foregroundStyle(DeskColor.nightText.color)
    }

    private var priceBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            MarketTokenLogo(symbol: market.symbol, size: 42)
            Text(market.symbol)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(DeskColor.nightMuted.color)
                .padding(.top, 8)
            AmountText(market.markText == "—" ? "—" : "$" + market.markText, size: 42)
                .contentTransition(.numericText())
            HStack(spacing: 8) {
                Text(market.changePercentText ?? "—")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(market.trend.color)
                Text("LIVE")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.16)))
            }
        }
    }

    @ViewBuilder private var chart: some View {
        if !market.candles.isEmpty, let config = market.market?.config {
            CandlestickChart(candles: market.candles, priceDecimals: Int(config.priceDecimals))
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

    private var ranges: some View {
        HStack {
            ForEach([(60, "1m"), (180, "3m"), (300, "5m"),
                     (900, "15m"), (1_800, "30m"), (3_600, "1H")], id: \.0) { seconds, label in
                Button { market.selectCandleInterval(seconds) } label: {
                    Text(label)
                        .foregroundStyle(market.candleIntervalSeconds == seconds
                                         ? DeskColor.nightText.color : DeskColor.nightMuted.color)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .modifier(RangeSelectionGlass(selected: market.candleIntervalSeconds == seconds))
            }
        }
        .font(.system(size: 13, weight: .bold, design: .rounded))
    }

    private var stats: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MARKET STATS")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(0.9)
                .foregroundStyle(DeskColor.nightMuted.color)
            ValueRow(label: "Market", value: "\(market.symbol)-PERP")
            ValueRow(label: "Maximum leverage", value: "\(market.market?.config.maxLeverage ?? 0)×")
            ValueRow(label: "Data", value: market.freshness == .live ? "Live" : "Last known")
        }
        .padding(16)
        .perpGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func tradeButton(_ side: Direction, title: String) -> some View {
        Button {
            if model.hasSeenLeverageExplainer { ticket = side } else { pendingSide = side }
        } label: {
            Text(title)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(side.color.color)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
        }
        .buttonStyle(.plain)
        .perpGlass(interactive: true, in: Capsule())
    }
}

private struct RangeSelectionGlass: ViewModifier {
    let selected: Bool
    func body(content: Content) -> some View {
        if selected { content.perpGlass(in: Capsule()) } else { content }
    }
}

extension Direction: @retroactive Identifiable {
    public var id: String { rawValue }
}

/// OHLC candles built only from marks this device actually observed. Until a historical
/// candle endpoint is available, no invented highs or lows are shown.
private struct CandlestickChart: View {
    let candles: [MarketModel.Candle]
    let priceDecimals: Int

    var body: some View {
        Canvas { context, size in
            let samples = Array(candles.suffix(25))
            guard samples.count > 1,
                  let lowRaw = samples.map(\.l).min(),
                  let highRaw = samples.map(\.h).max() else { return }
            let scale = pow(10.0, Double(priceDecimals))
            let low = Double(lowRaw) / scale, high = Double(highRaw) / scale
            let spread = max(high - low, high * 0.0001)
            let plotWidth = size.width - 62
            let priceHeight = size.height * 0.76
            let volumeTop = size.height * 0.80
            let xStep = plotWidth / CGFloat(samples.count)
            func y(_ raw: UInt64) -> CGFloat {
                let value = Double(raw) / scale
                return priceHeight * CGFloat(1 - (value - low) / spread) * 0.90 + 7
            }
            for row in 0...3 {
                let y = priceHeight * CGFloat(row) / 3
                var grid = Path(); grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: plotWidth, y: y))
                context.stroke(grid, with: .color(.white.opacity(0.07)), style: StrokeStyle(lineWidth: 0.6, dash: [3, 5]))
                let price = high - spread * Double(row) / 3
                context.draw(Text(Self.axis(price)).font(.system(size: 10, weight: .semibold)).foregroundStyle(.gray),
                             at: CGPoint(x: plotWidth + 31, y: y + 6))
            }
            let maxVolume = samples.compactMap { Double($0.v) }.max() ?? 1
            for (index, candle) in samples.enumerated() {
                let rising = candle.c >= candle.o
                let color = rising ? Color.green : Color.red
                let x = (CGFloat(index) + 0.5) * xStep
                let top = min(y(candle.o), y(candle.c)), bottom = max(y(candle.o), y(candle.c))
                var wick = Path(); wick.move(to: CGPoint(x: x, y: y(candle.h))); wick.addLine(to: CGPoint(x: x, y: y(candle.l)))
                context.stroke(wick, with: .color(color), lineWidth: 1)
                let body = CGRect(x: x - max(2, xStep * 0.28), y: top,
                                  width: max(4, xStep * 0.56), height: max(2, bottom - top))
                context.fill(Path(roundedRect: body, cornerRadius: 2), with: .color(color))
                let volume = (Double(candle.v) ?? 0) / maxVolume
                let volumeRect = CGRect(x: x - xStep * 0.30,
                                        y: size.height - 2 - CGFloat(volume) * (size.height - volumeTop),
                                        width: xStep * 0.60,
                                        height: CGFloat(volume) * (size.height - volumeTop))
                context.fill(Path(roundedRect: volumeRect, cornerRadius: 2),
                             with: .color(.white.opacity(0.15)))
            }
            if let last = samples.last {
                let currentY = y(last.c)
                var line = Path(); line.move(to: CGPoint(x: 0, y: currentY)); line.addLine(to: CGPoint(x: plotWidth, y: currentY))
                context.stroke(line, with: .color((last.c >= last.o ? Color.green : .red).opacity(0.55)), lineWidth: 0.8)
            }
        }
    }

    private static func axis(_ value: Double) -> String {
        value >= 1_000 ? String(format: "%.2fK", value / 1_000) : String(format: "%.2f", value)
    }
}

private extension View {
    @ViewBuilder
    func perpGlass<S: Shape>(interactive: Bool = false, in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(interactive), in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }
}
