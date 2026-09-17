import DeskFlow
import DeskMoney
import DeskPerpl
import DeskUI
import SwiftUI

/// The whole book's risk in one place: what it is exposed to, how much of that auto-copy
/// opened, and what a move against it would cost.
///
/// Positions come from the venue and the marks from the same poll the rest of the app
/// reads, so nothing here is a second opinion. The stress test moves every market by the
/// same amount, which is what a bad day actually looks like, and says so rather than
/// implying a model it does not have.
struct RiskScreen: View {
    let model: AppModel
    let market: MarketModel
    let copier: CopyTrader

    @State private var move: Double = -0.1

    private var book: RiskBook {
        let copies = copier.open.filter { !$0.shadowed }
        let positions = model.openPositions.compactMap { held -> RiskPosition? in
            guard let target = market.market(id: held.marketID),
                  let mark = market.price(for: target),
                  let figures = PositionFigures(position: held, market: target.config, mark: mark)
            else { return nil }
            let markValue = Self.value(mark)
            let side: Side = figures.side
            let copy = copies.first {
                $0.positionID == held.positionID
                    || ($0.marketID == held.marketID && $0.isLong == (side == .long))
            }
            return RiskPosition(
                id: "\(held.accountID):\(held.positionID)",
                symbol: target.symbol.uppercased(),
                side: side,
                notional: Self.size(figures.size) * markValue,
                margin: Double(figures.collateral.raw) / 1_000_000,
                mark: markValue,
                liquidation: figures.liquidationPrice.map(Self.value),
                unrealised: Double(figures.unrealisedPnL.raw) / 1_000_000,
                source: copy.map { .copy(trader: CopyTrader.name(for: $0.trader)) } ?? .yours)
        }
        return RiskBook(positions: positions, free: Double(model.collateral.value?.raw ?? 0) / 1_000_000)
    }

    var body: some View {
        GlassPage {
            if book.isEmpty {
                ContentUnavailableView(
                    "Nothing at Risk",
                    systemImage: "shield.lefthalf.filled",
                    description: Text("Open a position or let auto-copy open one, and this reads what it would cost you."))
                    .padding(.top, 60)
            } else {
                let stress = book.stress(move: move)
                health
                exposure
                sources
                stressTest(stress)
            }
        }
        .tint(DeskColor.rise.color)
        .navigationTitle("Risk")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Health

    private var health: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(DisplayCurrency.shared.format(book.equity))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text("Account equity")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(book.accountLeverage.map { String(format: "%.1f×", $0) } ?? "—")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(leverageTint)
                    Text("Exposure")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let leverage = book.accountLeverage {
                Gauge(value: min(leverage, 10), in: 0...10) { EmptyView() }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .tint(leverageTint)
                    .frame(height: 8)
            }

            Text(headline)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .deskGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var headline: String {
        let gross = DisplayCurrency.shared.format(book.grossNotional, compact: true)
        guard let leverage = book.accountLeverage else { return "\(gross) of positions." }
        return String(format: "%@ of positions against %@ of equity, so a 1%% move is %.1f%% of the account.",
                      gross, DisplayCurrency.shared.format(book.equity, compact: true), leverage)
    }

    private var leverageTint: Color {
        switch book.accountLeverage ?? 0 {
        case ..<2: DeskColor.rise.color
        case ..<5: DeskColor.action.color
        default: DeskColor.fall.color
        }
    }

    // MARK: - Exposure

    private var exposure: some View {
        GlassSection("Exposure", footer: book.exposures.contains(where: \.isHedged)
                     ? "A market held on both sides shows its gross; the two sides offset each other."
                     : nil) {
            ForEach(book.exposures) { held in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(held.symbol).fontWeight(.medium)
                        if held.isHedged {
                            Text("BOTH SIDES")
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(DisplayCurrency.shared.format(abs(held.net), compact: true))
                            .monospacedDigit()
                            .foregroundStyle((held.isNetLong ? DeskColor.rise : DeskColor.fall).color)
                        Text(held.isNetLong ? "long" : "short")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    shareBar(held.gross / max(book.grossNotional, 0.01), isLong: held.isNetLong)
                }
            }
            GlassRow("Net exposure") {
                Text(DisplayCurrency.shared.format(abs(book.netNotional), compact: true)
                     + (book.netNotional >= 0 ? " long" : " short"))
                    .foregroundStyle((book.netNotional >= 0 ? DeskColor.rise : DeskColor.fall).color)
                    .monospacedDigit()
            }
        }
    }

    private func shareBar(_ share: Double, isLong: Bool) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill((isLong ? DeskColor.rise : DeskColor.fall).color.opacity(0.85))
                    .frame(width: max(4, proxy.size.width * share))
            }
        }
        .frame(height: 5)
    }

    // MARK: - Where the risk comes from

    private var sources: some View {
        GlassSection("Where It Comes From") {
            if let concentration = book.concentration, let largest = book.exposures.first {
                GlassRow("Largest market",
                         subtitle: concentration > 0.6 ? "Most of the account rides on one market" : nil) {
                    Text(String(format: "%@ · %.0f%%", largest.symbol, concentration * 100))
                        .foregroundStyle(concentration > 0.6 ? DeskColor.action.color : .secondary)
                        .monospacedDigit()
                }
            }
            if let share = book.copyShare, share > 0 {
                GlassRow("Opened by auto-copy") {
                    Text(String(format: "%.0f%%", share * 100))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if let heaviest = book.heaviestTrader {
                GlassRow("Most from") {
                    Text("\(heaviest.trader) · \(DisplayCurrency.shared.format(heaviest.notional, compact: true))")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if let tightest = book.tightest, let room = tightest.roomToLiquidation {
                GlassRow("Closest to liquidation", subtitle: "\(tightest.isLong ? "Long" : "Short") \(tightest.symbol)") {
                    Text(String(format: "%.1f%% away", room * 100))
                        .foregroundStyle(room < 0.05 ? DeskColor.fall.color : (room < 0.15 ? DeskColor.action.color : .secondary))
                        .monospacedDigit()
                }
            }
        }
    }

    // MARK: - Stress test

    private func stressTest(_ stress: StressResult) -> some View {
        GlassSection("If The Market Moves",
                     footer: "Every market is moved by the same amount, which is what a bad day looks like. A position can only lose the collateral behind it, because the venue closes it first.") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(format: "%@%.0f%%", move < 0 ? Direction.minus : "+", abs(move * 100)))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: move))
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(DisplayCurrency.shared.format(stress.pnl, signed: true))
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(stress.pnl < 0 ? DeskColor.fall.color : DeskColor.rise.color)
                            .contentTransition(.numericText(value: stress.pnl))
                        Text("equity \(DisplayCurrency.shared.format(stress.equity))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Slider(value: $move, in: -0.5...0.5, step: 0.01) {
                    Text("Market move")
                } minimumValueLabel: {
                    Text("−50%").font(.caption2).foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text("+50%").font(.caption2).foregroundStyle(.secondary)
                }
                .tint(stress.liquidates ? DeskColor.fall.color : DeskColor.rise.color)
            }

            if stress.liquidates {
                Label(liquidationSentence(stress), systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(DeskColor.fall.color)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let survivable = book.survivableFall() {
                Label(String(format: "Nothing is liquidated until about −%.0f%%.", survivable * 100),
                      systemImage: "shield.lefthalf.filled")
                    .font(.footnote)
                    .foregroundStyle(DeskColor.rise.color)
            }
        }
    }

    private func liquidationSentence(_ stress: StressResult) -> String {
        let names = stress.liquidated.map { "\($0.isLong ? "Long" : "Short") \($0.symbol)" }
        let list = names.count > 2 ? "\(names.count) positions" : names.joined(separator: " and ")
        let behind = names.count == 1 ? "it" : "them"
        return "\(list) would be liquidated, losing the collateral behind \(behind)."
    }

    // MARK: - Scaling

    private static func value(_ price: Price) -> Double {
        Double(price.raw) / pow(10, Double(price.decimals))
    }

    private static func size(_ size: Size) -> Double {
        Double(size.raw) / pow(10, Double(size.decimals))
    }
}
