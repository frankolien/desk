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
    let onDismiss: () -> Void

    @State private var amount = ""
    @State private var leverage = 1
    @State private var submission = Submission.idle

    /// What the ticket knows about the order it sent.
    ///
    /// `forwarded` is its own state and not a spinner labelled "done", because `mt: 3`
    /// with `code: 0` means the gateway accepted the order for forwarding — not that it
    /// reached the book and not that it filled. Only `mt: 24` settles anything. Collapsing
    /// the two would tell someone they hold a position they may not.
    enum Submission: Equatable {
        case idle
        case sending
        case forwarded
        case filled
        case failed(String)

        var isBusy: Bool { self == .sending || self == .forwarded }
    }

    private var quote: OrderQuote? {
        guard let market, let mark, let money = Money(text: amount.isEmpty ? "0" : amount),
              money.raw > 0,
              let size = sizeFor(money, mark: mark, market: market)
        else { return nil }
        return try? OrderQuote.forMarket(
            market, side: side == .up ? .long : .short, size: size, price: mark,
            leverageHundredths: leverage * 100)
    }

    private func sizeFor(_ notional: Money, mark: Price, market: Market) -> Size? {
        // size = notional / price, at the market's own size scale.
        let scale = Int128(pow10(Int(market.config.sizeDecimals) + Int(market.config.priceDecimals)))
        let raw = Int128(notional.raw) * scale / (Int128(mark.raw) * 1_000_000)
        return Int64(exactly: raw).flatMap { market.size($0) }
    }

    private func pow10(_ exponent: Int) -> Double { pow(10, Double(exponent)) }

    var body: some View {
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
                Text("AUSD")
                    .font(DeskType.label)
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
            .padding(.top, 12)

            // What it costs, immediately under what was typed. Principle three, as a
            // layout rather than as a promise.
            VStack(spacing: 10) {
                ValueRow(label: "Order value", value: quote?.notional.display() ?? Unavailable.text)
                ValueRow(label: "Margin", value: quote?.margin.display() ?? Unavailable.text)
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

            HStack(spacing: 8) {
                ForEach([1, 2, 5, 10, 15], id: \.self) { option in
                    Button { leverage = option } label: {
                        Text("\(option)×")
                            .font(DeskType.caption)
                            .foregroundStyle(leverage == option ? DeskColor.onLedger.color : DeskColor.nightMuted.color)
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(leverage == option ? DeskColor.ledger.color : DeskColor.nightChip.color)
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(.top, 16)

            AmountKeypad(text: $amount)
                .padding(.top, 8)

            Spacer(minLength: 8)

            if case .failed(let reason) = submission {
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

            HoldToConfirm(
                title: quote == nil
                    ? "Enter order size"
                    : "Hold to \(side.word().lowercased()) \(amount) AUSD · \(leverage)×",
                tint: side == .up ? DeskColor.rise : DeskColor.fall,
                isEnabled: quote != nil && !submission.isBusy
            ) {
                Task { await submit() }
            }

            // The one place the venue's own vocabulary is worth showing, because
            // "forwarded" is a real state a user can be stuck in and a spinner is not an
            // explanation.
            if submission.isBusy {
                Text(submission == .sending ? "Sending to Perpl…" : "Forwarded — waiting for the book")
                    .font(DeskType.caption)
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)
                    .transition(.opacity)
            }
        }
        .padding(24)
        .background(DeskColor.night.color)
    }

    /// Sends the order, or explains precisely why it cannot be sent.
    ///
    /// Every failure here is a sentence naming what the user can do about it. There is no
    /// enrolled key until the desk has been opened, and "not enrolled" is a state of the
    /// account rather than a fault — so it reads as an instruction, not an error.
    private func submit() async {
        guard let quote else { return }
        withAnimation(.snappy) { submission = .sending }
        do {
            try await send(quote)
        } catch {
            Haptics.failure()
            withAnimation(.snappy) { submission = .failed(Self.sentence(for: error)) }
        }
    }

    private func send(_ quote: OrderQuote) async throws {
        // The authenticated socket needs an enrolled API key, which needs a desk opened
        // on a funded address. Until that exists this is the honest answer rather than a
        // fake confirmation — the one thing a trading app must never do is tell someone
        // an order went through when nothing left the phone.
        throw OrderDesk.Failure.notEnrolled
    }

    static func sentence(for error: any Error) -> String {
        switch error {
        case OrderDesk.Failure.notEnrolled:
            return "Your desk is not enrolled with Perpl yet, so no order can be signed. "
                + "Finish opening your desk first."
        case OrderDesk.Failure.forwardingNotAllowed:
            return "Perpl will not accept orders on this account until order forwarding "
                + "is switched on, which is the last step of opening your desk."
        case OrderDesk.Failure.notConnected:
            return "Not connected to Perpl. Nothing was sent."
        default:
            return "The order could not be sent. Nothing left your phone."
        }
    }

    private func liquidationText(_ quote: OrderQuote) -> String {
        quote.liquidationPrice.display(fractionDigits: market?.config.priceDecimals ?? 1)
    }

    private func percent(_ micros: Int) -> String {
        String(format: "%.2f%%", Double(micros) / 10_000)
    }
}
