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
    @State private var dismissedWarning = false

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
        ZStack {
            DeskBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if book.isEmpty {
                        ContentUnavailableView(
                            "Nothing at Risk",
                            systemImage: "shield.lefthalf.filled",
                            description: Text("Open a position, or let auto-copy open one, and this reads what it would cost you."))
                            .padding(.top, 80)
                    } else {
                        let stress = book.stress(move: move)
                        headline
                        scenarios.padding(.top, 20)
                        tiles.padding(.top, 18)
                        if let warning, !dismissedWarning { banner(warning).padding(.top, 18) }
                        Text("Positions")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DeskColor.nightMuted.color)
                            .padding(.top, 26)
                        rows(stress).padding(.top, 8)
                        stressCard(stress).padding(.top, 22)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
        }
        .tint(DeskColor.rise.color)
        .navigationTitle("Risk")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Headline

    private var headline: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(DisplayCurrency.shared.format(book.equity))
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .foregroundStyle(DeskColor.nightText.color)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.55)
            HStack(spacing: 8) {
                Text(DisplayCurrency.shared.format(book.unrealised, signed: true))
                    .foregroundStyle(pnlTint(book.unrealised))
                    .monospacedDigit()
                if let share = openShare {
                    Text(String(format: "(%@%.2f%%)", share < 0 ? Direction.minus : "+", abs(share) * 100))
                        .foregroundStyle(pnlTint(book.unrealised))
                        .monospacedDigit()
                }
                Text("Open")
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
            .font(.system(size: 15, weight: .semibold))
        }
    }

    /// Open profit against equity, which is the denominator the account is measured in.
    private var openShare: Double? {
        let base = book.equity - book.unrealised
        return base > 0 ? book.unrealised / base : nil
    }

    // MARK: - Scenarios

    private var scenarios: some View {
        HStack(spacing: 10) {
            ForEach([-0.05, -0.1, -0.25], id: \.self) { scenario in
                Button {
                    withAnimation(.snappy(duration: 0.25)) { move = scenario }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.right")
                            .font(.system(size: 13, weight: .bold))
                        Text(String(format: "%@%.0f%%", Direction.minus, abs(scenario * 100)))
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(move == scenario ? DeskColor.onAction.color : DeskColor.nightText.color)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .background {
                    if move == scenario { Capsule().fill(DeskColor.action.color) }
                }
                .deskGlass(interactive: true, in: Capsule())
                .accessibilityLabel("Stress the book by \(Int(abs(scenario * 100))) percent")
            }
        }
    }

    // MARK: - Tiles

    private var tiles: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                tile("Exposure", DisplayCurrency.shared.format(book.grossNotional, compact: true),
                     tint: DeskColor.nightText.color)
                tile("Leverage", book.accountLeverage.map { String(format: "%.1f×", $0) } ?? "—", tint: leverageTint)
                tile("Liq. room", book.tightest?.roomToLiquidation.map { String(format: "%.1f%%", $0 * 100) } ?? "—",
                     tint: roomTint)
                if let share = book.copyShare, share > 0 {
                    tile("From copies", String(format: "%.0f%%", share * 100), tint: DeskColor.nightText.color)
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollClipDisabled()
        .padding(.horizontal, -20)
    }

    private func tile(_ label: String, _ value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DeskColor.nightMuted.color)
            Text(value)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minWidth: 118, alignment: .leading)
        .deskGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - Banner

    /// The one sentence worth interrupting for, or none.
    private var warning: String? {
        if let tightest = book.tightest, let room = tightest.roomToLiquidation, room < 0.05 {
            return "\(tightest.isLong ? "Long" : "Short") \(tightest.symbol) is \(String(format: "%.1f%%", room * 100)) from liquidation."
        }
        if let concentration = book.concentration, concentration > 0.7, let largest = book.exposures.first {
            return "\(largest.symbol) carries \(String(format: "%.0f%%", concentration * 100)) of your exposure."
        }
        if let leverage = book.accountLeverage, leverage > 5 {
            return String(format: "At %.1f× exposure, a 10%% move is most of the account.", leverage)
        }
        return nil
    }

    private func banner(_ sentence: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DeskColor.action.color)
                .frame(width: 38, height: 38)
                .background(DeskColor.action.color.opacity(0.14), in: Circle())
            Text(sentence)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DeskColor.nightText.color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button { withAnimation(.snappy) { dismissedWarning = true } } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .deskGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: - Positions

    private func rows(_ stress: StressResult) -> some View {
        VStack(spacing: 0) {
            ForEach(book.positions) { position in
                let liquidates = stress.liquidated.contains(position)
                HStack(spacing: 12) {
                    MarketTokenLogo(symbol: position.symbol, size: 42)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(position.symbol)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(DeskColor.nightText.color)
                            Text(position.isLong ? "LONG" : "SHORT")
                                .font(.system(size: 10, weight: .heavy))
                                .foregroundStyle((position.isLong ? DeskColor.rise : DeskColor.fall).color)
                        }
                        HStack(spacing: 6) {
                            if let room = position.roomToLiquidation {
                                Text(String(format: "%.1f%% to liq.", room * 100))
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(room < 0.05 ? DeskColor.fall.color : DeskColor.nightMuted.color)
                                    .padding(.horizontal, 7)
                                    .frame(height: 20)
                                    .background((room < 0.05 ? DeskColor.fall.color : Color.white).opacity(0.12), in: Capsule())
                            }
                            if let trader = position.source.trader {
                                Text("Copied \(trader)")
                                    .font(.system(size: 12))
                                    .foregroundStyle(DeskColor.nightMuted.color)
                                    .lineLimit(1)
                            }
                        }
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(DisplayCurrency.shared.format(position.notional, compact: true))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(DeskColor.nightText.color)
                            .monospacedDigit()
                        Text(liquidates
                             ? "liquidated"
                             : DisplayCurrency.shared.format(stressed(position), signed: true))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(liquidates ? DeskColor.fall.color : pnlTint(stressed(position)))
                            .monospacedDigit()
                    }
                }
                .padding(.vertical, 12)
            }
        }
    }

    /// What this one position does at the move on the slider, capped at its collateral.
    private func stressed(_ position: RiskPosition) -> Double {
        max(position.notional * move * (position.isLong ? 1 : -1), -position.margin)
    }

    // MARK: - Stress

    private func stressCard(_ stress: StressResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("If every market moves")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DeskColor.nightMuted.color)
                    Text(String(format: "%@%.0f%%", move < 0 ? Direction.minus : "+", abs(move * 100)))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: move))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(DisplayCurrency.shared.format(stress.pnl, signed: true))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(pnlTint(stress.pnl))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: stress.pnl))
                    Text("equity \(DisplayCurrency.shared.format(stress.equity))")
                        .font(.system(size: 12))
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .monospacedDigit()
                }
            }

            Slider(value: $move, in: -0.5...0.5, step: 0.01)
                .tint(stress.liquidates ? DeskColor.fall.color : DeskColor.rise.color)

            Text(stress.liquidates
                 ? liquidationSentence(stress)
                 : (book.survivableFall().map { String(format: "Nothing is liquidated until about %@%.0f%%. Every market is moved together, which is what a bad day looks like.", Direction.minus, $0 * 100) }
                    ?? "Every market is moved together, which is what a bad day looks like."))
                .font(.system(size: 12))
                .foregroundStyle(stress.liquidates ? DeskColor.fall.color : DeskColor.nightMuted.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .deskGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func liquidationSentence(_ stress: StressResult) -> String {
        let names = stress.liquidated.map { "\($0.isLong ? "Long" : "Short") \($0.symbol)" }
        let list = names.count > 2 ? "\(names.count) positions" : names.joined(separator: " and ")
        return "\(list) would be liquidated, losing the collateral behind \(names.count == 1 ? "it" : "them")."
    }

    private func pnlTint(_ value: Double) -> Color {
        value < 0 ? DeskColor.fall.color : (value > 0 ? DeskColor.rise.color : DeskColor.nightText.color)
    }

    private var leverageTint: Color {
        switch book.accountLeverage ?? 0 {
        case ..<2: DeskColor.rise.color
        case ..<5: DeskColor.action.color
        default: DeskColor.fall.color
        }
    }

    private var roomTint: Color {
        switch book.tightest?.roomToLiquidation ?? 1 {
        case ..<0.05: DeskColor.fall.color
        case ..<0.15: DeskColor.action.color
        default: DeskColor.rise.color
        }
    }

    // MARK: - Scaling

    private static func value(_ price: Price) -> Double {
        Double(price.raw) / pow(10, Double(price.decimals))
    }

    private static func size(_ size: Size) -> Double {
        Double(size.raw) / pow(10, Double(size.decimals))
    }
}
