import DeskFlow
import DeskMoney
import DeskPerpl
import DeskUI
import SwiftUI

/// The order ticket. Its order is fixed: the amount, then what the amount costs, then
/// the keypad, then the action. Nothing consequential is behind a disclosure.
struct TicketSheet: View {
    let side: Direction
    let market: Market?
    let mark: Price?
    /// Injected rather than built here: the ticket does not own a socket and must not
    /// decide whether an order can be sent. It asks, and is answered in a sentence.
    let session: TradingSession
    let onDismiss: () -> Void

    @State private var amount = ""
    @State private var leverage = 1
    @State private var stopLoss = ""
    @State private var takeProfit = ""
    @State private var handledFill = false

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
                            AssetMark.bitcoin(size: 30)
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

                    // What it costs, immediately under what was typed. Principle three, as a
                    // layout rather than as a promise.
                    VStack(spacing: 10) {
                        ValueRow(label: "Leveraged size", value: quote?.notional.display() ?? Unavailable.text)
                        ValueRow(label: "Your margin", value: quote?.margin.display() ?? Unavailable.text)
                        if leverage == 1 {
                            // The honesty case. A default of 1× is invisible unless it is said
                            // out loud, and saying it is the cheapest credibility in the app.
                            ValueRow(
                                label: "Liquidation",
                                value: "None",
                                detail: "Trading without leverage",
                                tint: DeskColor.rise)
                        } else {
                            ValueRow(
                                label: "Liquidation",
                                value: quote.map { liquidationText($0) } ?? Unavailable.text,
                                // An estimate, and said to be one: the real figure depends on the
                                // fill, and every venue that is honest about this labels it.
                                detail: quote.map { "est · \(percent($0.liquidationDistanceMicros)) away" },
                                tint: DeskColor.fall)
                        }
                        ValueRow(label: "Fee", value: quote?.fee.display(fractionDigits: 4) ?? Unavailable.text)
                        ValueRow(label: "Total", value: quote?.total.display() ?? Unavailable.text)
                    }
                    .padding(16)
                    .background(DeskColor.nightChip.color)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.top, 20)

                    LeverageRail(
                        leverage: $leverage,
                        maximum: max(1, market?.config.maxLeverage ?? 1)
                    )
                    .padding(.top, 16)

                    VStack(spacing: 10) {
                        HStack {
                            Text("Stop loss / Take profit")
                                .font(DeskType.label)
                            Spacer()
                            Text("Mark price")
                                .font(DeskType.caption)
                                .foregroundStyle(DeskColor.nightMuted.color)
                        }
                        HStack(spacing: 10) {
                            protectionField("SL price", text: $stopLoss)
                            protectionField("TP price", text: $takeProfit)
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

    var body: some View {
        VStack(spacing: 7) {
            HStack {
                Text("Leverage")
                    .font(DeskType.caption)
                    .foregroundStyle(DeskColor.nightMuted.color)
                Spacer()
                Text("\(leverage)×")
                    .font(.system(size: 17, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(DeskColor.nightText.color)
            }
            GeometryReader { proxy in
                HStack(alignment: .center, spacing: 0) {
                    ForEach(1...maximum, id: \.self) { tick in
                        Capsule()
                            .fill(
                                tick <= leverage
                                    ? DeskColor.action.color
                                    : DeskColor.nightMuted.color.opacity(0.38)
                            )
                            .frame(
                                width: tick == 1 || tick == maximum || tick % 5 == 0 ? 3 : 2,
                                height: tick == 1 || tick == maximum || tick % 5 == 0 ? 24 : 13)
                        if tick < maximum { Spacer(minLength: 1) }
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            let fraction = min(max(drag.location.x / proxy.size.width, 0), 1)
                            let next = 1 + Int((fraction * Double(maximum - 1)).rounded())
                            guard next != leverage else { return }
                            leverage = next
                            Haptics.selection()
                        })
            }
            .frame(height: 32)
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
            HStack {
                Text("1×")
                Spacer()
                Text("MAX \(maximum)×")
            }
            .font(DeskType.caption)
            .foregroundStyle(DeskColor.nightMuted.color)
        }
        .padding(14)
        .background(DeskColor.nightChip.color)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onChange(of: maximum) { _, limit in leverage = min(leverage, limit) }
    }
}
