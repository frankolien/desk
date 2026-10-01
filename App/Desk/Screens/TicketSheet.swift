import DeskFlow
import DeskMoney
import DeskPerpl
import DeskUI
import SwiftUI

struct TicketPreset: Hashable {
    var takeProfit: String?
    var stopLoss: String?
}

struct TicketSheet: View {
    let side: Direction
    let market: Market?
    let mark: Price?
    let session: TradingSession
    var isPriceFresh = true
    var initialLeverage = 1
    var preset: TicketPreset?
    var book: OrderBook? = nil
    let onDismiss: () -> Void

    @State private var amount = ""
    @State private var leverage = 1
    @State private var stopLoss = ""
    @State private var takeProfit = ""
    @State private var handledFill = false
    @State private var submitted = false
    @State private var watchingEarlier = false
    private var mine: Bool { submitted || watchingEarlier }

    private func origin(for market: Market) -> TradingSession.OrderOrigin {
        .ticket(market: market.id, side: side == .up ? .long : .short)
    }
    @State private var showsProtection = false

    private var quote: OrderQuote? {
        guard let market, let mark, let margin = Money(text: amount.isEmpty ? "0" : amount),
            margin.raw > 0,
            let notionalRaw = Int64(exactly: Int128(margin.raw) * Int128(leverage)),
            let notional = Money(raw: notionalRaw),
            let size = sizeFor(notional, mark: mark, market: market)
        else { return nil }
        return try? OrderQuote.forMarket(
            market, side: side == .up ? .long : .short, size: size, price: mark,
            leverageHundredths: leverage * 100)
    }

    private var protection: OrderDesk.Draft.Protection? {
        guard let market, let mark else { return nil }
        let decimals = market.config.priceDecimals
        // Rounded towards the mark by side, so a typed trigger is never moved further away
        // than asked: a long's stop rounds up, a short's rounds down, take profits mirror it.
        let sl = stopLoss.isEmpty ? nil : (side == .up
            ? Price(selling: stopLoss, decimals: decimals)
            : Price(buying: stopLoss, decimals: decimals))
        let tp = takeProfit.isEmpty ? nil : (side == .up
            ? Price(buying: takeProfit, decimals: decimals)
            : Price(selling: takeProfit, decimals: decimals))
        guard sl != nil || tp != nil else { return nil }
        if let sl, side == .up ? sl >= mark : sl <= mark { return nil }
        if let tp, side == .up ? tp <= mark : tp >= mark { return nil }
        // A stop beyond the liquidation price can never fire: the venue closes the position first.
        if let sl, let quote, side == .up ? sl <= quote.liquidationPrice : sl >= quote.liquidationPrice {
            return nil
        }
        return .init(stopLoss: sl, takeProfit: tp)
    }

    private var hasInvalidProtection: Bool {
        (!stopLoss.isEmpty || !takeProfit.isEmpty) && protection == nil
    }

    /// What the order costs against what the account holds — margin *and* fee, which is what
    /// leaves the balance. Nil while the account is unknown, which is not a refusal.
    private var shortfall: Money? {
        guard let quote, let free = session.account.value?.free, !quote.isAffordable(freeCollateral: free)
        else { return nil }
        return Money(raw: quote.total.raw - free.raw)
    }

    private var smallestMargin: String? {
        guard quote == nil, let market, let mark, mark.raw > 0,
              let margin = Money(text: amount.isEmpty ? "0" : amount), margin.raw > 0 else { return nil }
        let exponent = Int(market.config.sizeDecimals) + Int(market.config.priceDecimals)
        let unitNotional = Double(mark.raw) * 1_000_000 / pow(10, Double(exponent))
        let smallest = (unitNotional / Double(leverage) / 1_000_000 * 100).rounded(.up) / 100
        return String(format: "%.2f", max(smallest, 0.01))
    }

    @AppStorage("desk.leverageExplainerSeen") private var leverageUnderstood = false
    private var firstLeverageLine: String? {
        guard leverage > 1, !leverageUnderstood, let quote else { return nil }
        return "At \(leverage)×, a \(percent(quote.liquidationDistanceMicros)) move against you closes it. No margin call."
    }

    private var blockingReason: String? {
        if !isPriceFresh {
            return "Waiting for a live price."
        }
        if hasInvalidProtection {
            return side == .up
                ? "For a long, the stop must sit below the mark and above the liquidation price, and the take profit above the mark."
                : "For a short, the stop must sit above the mark and below the liquidation price, and the take profit below the mark."
        }
        if let smallest = smallestMargin { return "Too small for one \(market?.symbol ?? "") unit. Enter at least \(smallest) AUSD." }
        guard let shortfall, let quote else { return nil }
        return "This order costs \(quote.total.display()) AUSD with its fee, \(shortfall.display()) AUSD more than you have free."
    }

    private func sizeFor(_ notional: Money, mark: Price, market: Market) -> Size? {
        // Scale built by integer multiplication: `pow(10:)` is a Double, inexact past 10^23,
        // and converting a non-representable Double to Int128 traps.
        let exponent = Int(market.config.sizeDecimals) + Int(market.config.priceDecimals)
        guard exponent >= 0, exponent <= 38 else { return nil }
        var scale = Int128(1)
        for _ in 0..<exponent { scale *= 10 }
        let raw = Int128(notional.raw) * scale / (Int128(mark.raw) * 1_000_000)
        return Int64(exactly: raw).flatMap { market.size($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        HStack(spacing: 9) {
                            MarketTokenLogo(symbol: market?.symbol ?? "", size: 30)
                            Text(side.word())
                                .font(DeskType.title)
                                .foregroundStyle(side.color.color)
                        }
                        Spacer()
                        Text(market?.symbol ?? "—")
                            .font(DeskType.label)
                            .foregroundStyle(DeskColor.nightMuted.color)
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(amount.isEmpty ? "0" : amount)
                            .font(DeskType.display)
                            .foregroundStyle(DeskColor.nightText.color)
                            .lineLimit(1)
                            .minimumScaleFactor(0.55)
                        Text("AUSD")
                            .font(DeskType.label)
                            .foregroundStyle(DeskColor.nightMuted.color)
                    }
                    .padding(.top, 12)

                    HStack {
                        Text("Leveraged size  \(quote?.notional.display() ?? Unavailable.text) AUSD")
                        Spacer(minLength: 8)
                        if let free = session.account.value?.free {
                            Text("Free  \(free.display()) AUSD")
                        }
                    }
                    .font(DeskType.caption)
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.top, 4)

                    VStack(spacing: 12) {
                        HStack(alignment: .top, spacing: 12) {
                            figure("Your margin", quote?.margin.display() ?? Unavailable.text)
                            figure("Liquidation",
                                   quote.map { liquidationText($0) } ?? Unavailable.text,
                                   detail: quote.map { "est · \(percent($0.liquidationDistanceMicros)) away" },
                                   tint: DeskColor.fall, alignment: .trailing)
                        }
                        HStack(alignment: .top, spacing: 12) {
                            figure("Fee", quote?.fee.display(fractionDigits: 4) ?? Unavailable.text)
                            figure("Total", quote?.total.display() ?? Unavailable.text,
                                   alignment: .trailing)
                        }
                        if book != nil {
                            HStack(spacing: 6) {
                                Text("Est. fill")
                                    .foregroundStyle(DeskColor.nightMuted.color)
                                Text(bookEstimate?.price ?? Unavailable.text)
                                    .foregroundStyle(DeskColor.nightText.color)
                                Spacer(minLength: 8)
                                Text(bookEstimate?.versusMark ?? "")
                                    .foregroundStyle(DeskColor.nightMuted.color)
                            }
                            .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                            .lineLimit(1)
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(14)
                    .background(DeskColor.nightChip.color)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.top, 14)

                    LeverageRail(
                        leverage: $leverage,
                        maximum: max(1, market?.config.maxLeverage ?? 1)
                    )
                    .onAppear {
                        leverage = min(max(1, initialLeverage), max(1, market?.config.maxLeverage ?? 1))
                        if let preset {
                            takeProfit = preset.takeProfit ?? ""
                            stopLoss = preset.stopLoss ?? ""
                            showsProtection = true
                        }
                        #if DEBUG
                        if ProcessInfo.processInfo.arguments.contains("-ticket-demo") {
                            amount = "120"
                            leverage = min(15, max(1, market?.config.maxLeverage ?? 1))
                        }
                        #endif
                    }
                    .padding(.top, 16)

                    VStack(spacing: 10) {
                        Button {
                            withAnimation(.snappy(duration: 0.22)) { showsProtection.toggle() }
                        } label: {
                            HStack {
                                Text("Stop loss / Take profit")
                                    .font(DeskType.label)
                                    .foregroundStyle(DeskColor.nightText.color)
                                if protection != nil {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(DeskColor.rise.color)
                                }
                                Spacer()
                                Image(systemName: showsProtection ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(DeskColor.nightMuted.color)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if showsProtection {
                            HStack {
                                Spacer()
                                Text("Mark price")
                                    .font(DeskType.caption)
                                    .foregroundStyle(DeskColor.nightMuted.color)
                            }
                            HStack(spacing: 10) {
                                protectionField("SL price", text: $stopLoss)
                                protectionField("TP price", text: $takeProfit)
                            }
                        }
                        if let loss = projectedPnL(stopLoss, isProfit: false) {
                            ValueRow(
                                label: "Potential loss", value: "−\(loss.display()) AUSD", tint: DeskColor.fall)
                        }
                        if let profit = projectedPnL(takeProfit, isProfit: true) {
                            ValueRow(
                                label: "Potential profit", value: "+\(profit.display()) AUSD", tint: DeskColor.rise)
                        }
                        if hasInvalidProtection {
                            Text(
                                side == .up
                                    ? "For a long, SL must be below mark and TP above it."
                                    : "For a short, SL must be above mark and TP below it."
                            )
                            .font(DeskType.caption)
                            .foregroundStyle(DeskColor.fall.color)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else if protection != nil {
                            Text("Held by Perpl even when Desk is closed")
                                .font(DeskType.caption)
                                .foregroundStyle(DeskColor.rise.color)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.top, 14)

                    AmountKeypad(text: $amount, keyHeight: 46, spacing: 4)
                        .padding(.top, 2)

                    if let blockingReason, !(mine && session.hasFailed) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(DeskColor.action.color)
                            Text(blockingReason)
                                .font(DeskType.caption)
                                .foregroundStyle(DeskColor.nightText.color.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.bottom, 12)
                        .transition(.opacity)
                    }

                    if mine, session.hasFailed, let reason = session.statusText {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(DeskColor.action.color)
                            Text(reason)
                                .font(DeskType.caption)
                                .foregroundStyle(DeskColor.nightText.color.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.bottom, 12)
                        .transition(.opacity)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }

            HoldToConfirm(
                title: quote == nil
                    ? "Enter order size"
                    : "Hold to \(side.word().lowercased()) \(amount) AUSD · \(leverage)×",
                tint: side == .up ? DeskColor.rise : DeskColor.fall,
                isEnabled: quote != nil && !hasInvalidProtection && shortfall == nil && !session.isBusy && isPriceFresh
                    && !handledFill
            ) {
                Task { await submit() }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)

            if quote != nil, !session.isBusy {
                if let warning = bookEstimate?.short ?? firstLeverageLine {
                    Text(warning)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(DeskColor.action.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                } else {
                    Text("Estimated. Fills, fees and liquidation can differ from this preview.")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color.opacity(0.7))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                }
            }

            if let status = mine
                ? (session.isBusy || session.order.outcome == .settled ? session.statusText : nil)
                : (session.isBusy ? "Another order is still in flight." : nil) {
                Text(status)
                    .font(DeskType.caption)
                    .foregroundStyle(session.order.outcome == .settled ? DeskColor.rise.color : DeskColor.nightMuted.color)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)
                    .transition(.opacity)
            }
        }
        .padding(.bottom, 8)
        .background(DeskColor.night.color)
        .interactiveDismissDisabled(mine && session.isBusy)
        .onAppear {
            if session.isBusy {
                watchingEarlier = market.map { session.orderOrigin == origin(for: $0) } ?? false
            } else {
                session.clear()
            }
        }
        .onChange(of: session.order.outcome) { _, outcome in
            guard outcome == .settled, submitted || watchingEarlier, !handledFill else { return }
            handledFill = true
            Task { @MainActor in
                // Forwarded is deliberately not enough: only a real fill earns automatic dismissal.
                try? await Task.sleep(for: .milliseconds(session.order.fill?.isPartial == true ? 2_600 : 650))
                guard !Task.isCancelled, session.order.outcome == .settled else { return }
                onDismiss()
            }
        }
    }

    private var bookEstimate: (price: String, versusMark: String, short: String?)? {
        guard let book, book.isReady, (book.spreadRaw ?? 1) > 0,
              let quote, let market, let mark, mark.raw > 0 else { return nil }
        let bps = min(50, market.maxMarketSlippageBps)
        let buying = side == .up
        let bound = Double(mark.raw) * (1 + (buying ? 1 : -1) * Double(bps) / 10_000)
        let estimate = book.estimateFill(
            buying: buying, sizeRaw: quote.size.raw,
            limitRaw: Int64(bound.rounded(buying ? .down : .up)))
        let limitText = String(format: "%.2f%%", Double(bps) / 100)
        guard let average = estimate.averagePriceRaw else {
            return ("—", "", "Nothing on the book within \(limitText). This would not fill.")
        }
        let decimals = market.config.priceDecimals
        let price = Price(raw: Int64(average.rounded()), decimals: decimals)?.display(fractionDigits: decimals) ?? "—"
        let gap = (average - Double(mark.raw)) / Double(mark.raw) * 100
        let versusMark = String(format: "%.3f%%", abs(gap)) == "0.000%"
            ? "at mark"
            : String(format: "%.3f%% ", abs(gap)) + (gap > 0 ? "above mark" : "below mark")
        var short: String?
        if !estimate.isComplete, let held = market.size(estimate.filledRaw) {
            short = "Only \(held.display(fractionDigits: held.decimals)) of \(quote.size.display(fractionDigits: quote.size.decimals)) \(market.symbol) would fill within \(limitText)."
        }
        return (price, versusMark, short)
    }

    private func submit() async {
        submitted = true
        if leverage > 1 { leverageUnderstood = true }
        guard let market, let quote else { return }
        let draft = OrderDesk.Draft(
            side: side == .up ? .long : .short,
            size: quote.size,
            leverageHundredths: leverage * 100,
            // The venue's own cap. A market order is a limit bounded by slippage, so this is
            // all that stands between a thin book and a fill at any price.
            slippageBps: min(50, market.maxMarketSlippageBps),
            protection: protection)

        await session.place(draft, in: market, origin: origin(for: market))
    }

    private func figure(
        _ label: String,
        _ value: String,
        detail: String? = nil,
        tint: DeskRGB = DeskColor.nightText,
        alignment: HorizontalAlignment = .leading
    ) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(label)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(DeskColor.nightMuted.color)
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(tint.color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let detail {
                Text(detail)
                    .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
        .accessibilityElement(children: .combine)
    }

    private func protectionField(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .keyboardType(.decimalPad)
            .font(DeskType.label)
            .foregroundStyle(DeskColor.nightText.color)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(DeskColor.nightChip.color)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func projectedPnL(_ text: String, isProfit: Bool) -> Money? {
        guard !text.isEmpty, let market, let mark, let size = quote?.size else { return nil }
        let entered =
            isProfit
            ? Price(buying: text, decimals: market.config.priceDecimals)
            : Price(selling: text, decimals: market.config.priceDecimals)
        guard let entered else { return nil }
        let difference = entered.raw >= mark.raw ? entered - mark : mark - entered
        return Money.notional(price: difference, size: size, rounding: .towardZero)
    }

    private func liquidationText(_ quote: OrderQuote) -> String {
        quote.liquidationPrice.display(fractionDigits: market?.config.priceDecimals ?? 1)
    }

    private func percent(_ micros: Int) -> String {
        String(format: "%.2f%%", Double(micros) / 10_000)
    }
}

private struct LeverageRail: View {
    @Binding var leverage: Int
    let maximum: Int

    private var scale: LeverageScale { LeverageScale(maximum: maximum) }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Leverage")
                    .font(DeskType.caption)
                    .foregroundStyle(DeskColor.nightMuted.color)
                Spacer()
                Text("\(leverage)×")
                    .font(.system(size: 17, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(DeskColor.nightText.color)
                    .contentTransition(.numericText())
            }
            GeometryReader { proxy in
                HStack(alignment: .center, spacing: 0) {
                    ForEach(0..<scale.tickCount, id: \.self) { index in
                        let major = scale.isMajor(tick: index)
                        Capsule()
                            .fill(
                                scale.isFilled(tick: index, at: leverage)
                                    ? DeskColor.action.color
                                    : DeskColor.nightMuted.color.opacity(0.32))
                            .frame(width: major ? 2.5 : 1.5, height: major ? 26 : 14)
                        if index < scale.tickCount - 1 { Spacer(minLength: 0) }
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            let next = scale.value(
                                atFraction: drag.location.x / proxy.size.width)
                            guard next != leverage else { return }
                            leverage = next
                            Haptics.selection()
                        })
            }
            .frame(height: 30)
            .accessibilityElement()
            .accessibilityLabel("Leverage")
            .accessibilityValue("\(leverage) times")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: leverage = min(maximum, leverage + 1)
                case .decrement: leverage = max(1, leverage - 1)
                @unknown default: break
                }
            }
            HStack(spacing: 0) {
                ForEach(Array(scale.labelledValues.enumerated()), id: \.offset) { index, value in
                    Text(value == maximum ? "MAX \(value)×" : "\(value)×")
                        .frame(maxWidth: .infinity,
                               alignment: index == 0 ? .leading
                                   : (index == scale.labelledValues.count - 1 ? .trailing : .center))
                }
            }
            .font(DeskType.caption)
            .foregroundStyle(DeskColor.nightMuted.color)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(DeskColor.nightChip.color)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onChange(of: maximum) { _, limit in leverage = min(leverage, limit) }
    }
}
