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

            PrimaryButton(
                title: quote == nil ? "Enter order size" : "\(side.word()) \(amount) AUSD · \(leverage)×",
                tint: side == .up ? DeskColor.ledger : DeskColor.fall,
                isEnabled: quote != nil
            ) {
                onDismiss()
            }
        }
        .padding(24)
        .background(DeskColor.night.color)
    }

    private func liquidationText(_ quote: OrderQuote) -> String {
        quote.liquidationPrice.display(fractionDigits: market?.config.priceDecimals ?? 1)
    }

    private func percent(_ micros: Int) -> String {
        String(format: "%.2f%%", Double(micros) / 10_000)
    }
}
