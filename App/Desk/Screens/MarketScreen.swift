import DeskPerpl
import DeskUI
import SwiftUI

/// Perpetuals opens as an overview, matching the product hierarchy in the reference:
/// collateral, positions, then supported markets. Desk currently supports one live market,
/// so the list stays truthful rather than filling the design with invented feeds.
struct MarketScreen: View {
    let model: AppModel
    let market: MarketModel

    @State private var query = ""
    @State private var showsBTC = false
    @State private var showsPosition = false

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
            .navigationDestination(isPresented: $showsBTC) {
                PerpDetailScreen(model: model, market: market)
                    .toolbar(.hidden, for: .tabBar)
            }
        }
    }

    private var header: some View {
        ZStack {
            Text("Perpetuals")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(DeskColor.nightText.color)

            HStack {
                Spacer()
                Button { } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(DeskColor.nightText.color)
                        .frame(width: 42, height: 42)
                }
                .buttonStyle(.plain)
                .perpGlass(interactive: true, in: Circle())
            }
        }
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
            Text("A")
                .font(.system(size: 24, weight: .heavy, design: .rounded))
                .foregroundStyle(DeskColor.nightText.color)
                .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text("Available")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
                Text("\(model.collateral.value?.display() ?? "—") AUSD")
                    .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(DeskColor.nightText.color)
            }

            Spacer()

            Button { } label: {
                Image(systemName: "minus")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .perpGlass(interactive: true, in: Circle())

            Button { model.advance(to: .needsDesk) } label: {
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

            if query.isEmpty || "btc bitcoin".contains(query.lowercased()) {
                Button { showsBTC = true } label: {
                    HStack(spacing: 12) {
                        AssetMark.bitcoin(size: 42)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(market.symbol)
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .foregroundStyle(DeskColor.nightText.color)
                            Text("MAX 15×")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(DeskColor.nightMuted.color)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .overlay(Capsule().stroke(Color.white.opacity(0.13), lineWidth: 0.7))
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(market.markText == "—" ? "—" : "$" + market.markText)
                                .font(.system(size: 18, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle(DeskColor.nightText.color)
                            Text(market.changePercentText ?? "—")
                                .font(.system(size: 14, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle(market.trend.color)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Text("No supported market found")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
        }
    }
}

private struct PerpDetailScreen: View {
    let model: AppModel
    let market: MarketModel

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
            TicketSheet(side: side, market: market.market, mark: market.mark.value) { ticket = nil }
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

            Button { } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
            .perpGlass(interactive: true, in: Circle())
        }
        .foregroundStyle(DeskColor.nightText.color)
    }

    private var priceBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            AssetMark.bitcoin(size: 42)
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
        let line = Sparkline(values: market.history, tint: market.trend)
        if line.hasEnoughPoints {
            line
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
            ForEach(["1m", "3m", "5m", "15m", "30m"], id: \.self) { range in
                Text(range).foregroundStyle(DeskColor.nightMuted.color).frame(maxWidth: .infinity)
            }
            Text("Live")
                .foregroundStyle(DeskColor.nightText.color)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .perpGlass(in: Capsule())
        }
        .font(.system(size: 13, weight: .bold, design: .rounded))
    }

    private var stats: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MARKET STATS")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(0.9)
                .foregroundStyle(DeskColor.nightMuted.color)
            ValueRow(label: "Market", value: "BTC-PERP")
            ValueRow(label: "Maximum leverage", value: "15×")
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

extension Direction: @retroactive Identifiable {
    public var id: String { rawValue }
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
