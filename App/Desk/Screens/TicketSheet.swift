import DeskFlow
import DeskMoney
import DeskPerpl
import DeskUI
import SwiftUI

/// The order ticket. Its order is fixed: the amount, then what the amount costs, then
/// the keypad, then the action.
///
/// Nothing consequential is behind a disclosure. Margin, liquidation, fee and total stay
/// on screen at all times; only stop loss and take profit fold away, because they are
/// optional and empty unless asked for — and leaving them open pushed the keypad and the
/// confirm control off the bottom of the sheet.
struct TicketSheet: View {
    let side: Direction
    let market: Market?
    let mark: Price?
    /// Injected rather than built here: the ticket does not own a socket and must not
    /// decide whether an order can be sent. It asks, and is answered in a sentence.
    let session: TradingSession
    /// Where the leverage rail starts, for a ticket opened from someone else's position.
    var initialLeverage = 1
    let onDismiss: () -> Void

    @State private var amount = ""
    @State private var leverage = 1
    @State private var stopLoss = ""
    @State private var takeProfit = ""
    @State private var handledFill = false
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
        let sl = stopLoss.isEmpty ? nil : Price(selling: stopLoss, decimals: decimals)
        let tp = takeProfit.isEmpty ? nil : Price(buying: takeProfit, decimals: decimals)
        guard sl != nil || tp != nil else { return nil }
        if let sl, side == .up ? sl >= mark : sl <= mark { return nil }
        if let tp, side == .up ? tp <= mark : tp >= mark { return nil }
        return .init(stopLoss: sl, takeProfit: tp)
    }

    private var hasInvalidProtection: Bool {
        (!stopLoss.isEmpty || !takeProfit.isEmpty) && protection == nil
    }

    private func sizeFor(_ notional: Money, mark: Price, market: Market) -> Size? {
        // size = notional / price, at the market's own size scale.
        let scale = Int128(pow10(Int(market.config.sizeDecimals) + Int(market.config.priceDecimals)))
        let raw = Int128(notional.raw) * scale / (Int128(mark.raw) * 1_000_000)
        return Int64(exactly: raw).flatMap { market.size($0) }
    }

    private func pow10(_ exponent: Int) -> Double { pow(10, Double(exponent)) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        HStack(spacing: 9) {
                            // The market's own mark. This drew Bitcoin for every market,
                            // so shorting PUMP showed a Bitcoin coin on the ticket.
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

                    Text("Leveraged size  \(quote?.notional.display() ?? Unavailable.text) AUSD")
                        .font(DeskType.caption)
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .padding(.top, 4)

                    // What it costs, immediately under what was typed. Paired rather than
                    // stacked: five full-width rows for four figures did not leave the
                    // keypad and the confirm control room on the sheet.
                    VStack(spacing: 12) {
                        HStack(alignment: .top, spacing: 12) {
                            figure("Your margin", quote?.margin.display() ?? Unavailable.text)
                            if leverage == 1 {
                                // A default of 1× is invisible unless it is said out loud.
                                figure("Liquidation", "None",
                                       detail: "No leverage", tint: DeskColor.rise,
                                       alignment: .trailing)
                            } else {
                                figure("Liquidation",
                                       quote.map { liquidationText($0) } ?? Unavailable.text,
                                       // An estimate, and said to be one: the real figure
                                       // depends on the fill.
                                       detail: quote.map { "est · \(percent($0.liquidationDistanceMicros)) away" },
                                       tint: DeskColor.fall, alignment: .trailing)
                            }
                        }
                        HStack(alignment: .top, spacing: 12) {
                            figure("Fee", quote?.fee.display(fractionDigits: 4) ?? Unavailable.text)
                            figure("Total", quote?.total.display() ?? Unavailable.text,
                                   alignment: .trailing)
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

                    AmountKeypad(text: $amount)
                        .padding(.top, 8)

                    if session.hasFailed, let reason = session.statusText {
                        // Above the control rather than in an alert: an alert is dismissed and
                        // forgotten, and the reason is the thing the user has to act on.
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
                isEnabled: quote != nil && !hasInvalidProtection && !session.isBusy
            ) {
                Task { await submit() }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)

            // The one place the venue's own vocabulary is worth showing, because
            // "forwarded" is a real state a user can be stuck in and a spinner is not an
            // explanation.
            if session.isBusy, let status = session.statusText {
                Text(status)
                    .font(DeskType.caption)
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)
                    .transition(.opacity)
            }
        }
        .padding(.bottom, 8)
        .background(DeskColor.night.color)
        .onChange(of: session.order.outcome) { _, outcome in
            guard outcome == .settled, !handledFill else { return }
            handledFill = true
            Task { @MainActor in
                // Leave the venue's confirmation visible for a beat before returning to
                // the portfolio. Forwarded is deliberately not enough: only a real fill
                // earns automatic dismissal.
                try? await Task.sleep(for: .milliseconds(650))
                guard !Task.isCancelled else { return }
                onDismiss()
            }
        }
    }

    /// Builds the draft and hands it to the session.
    ///
    /// There is no branch here for "not enrolled". Whether an order can be signed is the
    /// session's answer, arrived at through the same call the real path takes, so the day
    /// a key exists nothing in this file changes.
    private func submit() async {
        guard let market, let quote else { return }
        let draft = OrderDesk.Draft(
            side: side == .up ? .long : .short,
            size: quote.size,
            leverageHundredths: leverage * 100,
            // The venue's own cap, not a number chosen here. A market order is a
            // marketable limit bounded by slippage, so this is the only thing standing
            // between a thin book and a fill at any price.
            slippageBps: min(50, market.maxMarketSlippageBps),
            protection: protection)

        await session.place(draft)
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
