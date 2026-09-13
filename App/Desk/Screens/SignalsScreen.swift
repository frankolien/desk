import DeskMoney
import DeskPerpl
import DeskUI
import SwiftUI

/// What the market is doing, in sentences.
///
/// The first version of this screen was a feed of invented trades from invented wallets
/// with a Follow button that did nothing. The honest version of that feature — recent
/// trades from wallets you follow — cannot be built from Perpl: its public trade stream
/// carries a timestamp, a price, a size and a side, and no account identity at all.
/// Attributing fills to addresses means indexing Monad itself.
///
/// So this reads what the venue *does* publish. Every figure here comes off the same
/// context call the price does — mark against oracle, bid against ask, last against mid,
/// open interest — and each is a relationship rather than a number dressed up as an
/// insight. A raw tape would be the pro-trader version and the wrong one: Desk is for
/// someone who wants to trade without the ceremony, and a scrolling wall of anonymous
/// fills is the ceremony.
///
/// Nothing is invented to fill the space. A reading that cannot be computed says so.
struct SignalsScreen: View {
    let market: MarketModel

    private var signals: MarketSignals? {
        market.market.map {
            MarketSignals(
                state: $0.state,
                priceDecimals: $0.config.priceDecimals,
                sizeDecimals: $0.config.sizeDecimals)
        }
    }

    var body: some View {
        ZStack {
            DeskBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Signals")
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                        .padding(.top, 10)

                    Text("\(market.symbol)-PERP, read live from Perpl")
                        .font(DeskType.caption)
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .padding(.top, 6)

                    if let signals, !signals.isEmpty {
                        premium(signals).padding(.top, 22)

                        VStack(spacing: 10) {
                            spread(signals)
                            flow(signals)
                            interest(signals)
                        }
                        .padding(.top, 12)
                    } else {
                        waiting.padding(.top, 30)
                    }

                    Text("These come from the venue's own figures — the mark against the "
                         + "index, the bid against the ask, the last trade against the "
                         + "middle. They describe the market, not what you should do.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 26)
                        .padding(.bottom, 130)
                }
                .padding(.horizontal, 20)
            }
        }
    }

    // MARK: - The headline

    /// Mark against index: the one reading that says what the crowd is doing.
    ///
    /// Drawn as two marks on a line rather than stated as a percentage, because "0.2%
    /// above" means nothing to someone who has not held a perpetual, while two dots that
    /// do not line up is immediately legible.
    private func premium(_ signals: MarketSignals) -> some View {
        let micros = signals.premiumMicros ?? 0
        let above = micros > 0
        let tint: DeskRGB = !signals.premiumIsNotable ? DeskColor.nightMuted
            : (above ? DeskColor.rise : DeskColor.fall)

        return VStack(alignment: .leading, spacing: 0) {
            Text(signals.premiumIsNotable
                 ? (above ? "Buyers are paying above spot" : "Sellers are pushing below spot")
                 : "The perp is tracking spot")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(DeskColor.nightText.color)
                .fixedSize(horizontal: false, vertical: true)

            Text(signals.premiumIsNotable
                 ? "Holding a long here costs funding. Shorts are being paid it."
                 : "Neither side is paying much to hold a position.")
                .font(DeskType.caption)
                .foregroundStyle(DeskColor.nightMuted.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            premiumBar(micros: micros, tint: tint)
                .padding(.top, 20)

            HStack {
                Text("Index")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
                Spacer()
                Text(Self.percent(micros))
                    .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(tint.color)
                    .contentTransition(.numericText())
            }
            .padding(.top, 10)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DeskColor.nightChip.color.opacity(0.6),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(DeskColor.nightLine.color, lineWidth: 0.5))
        .animation(.snappy(duration: 0.3), value: micros)
    }

    /// The index sits at the centre; the perp sits off it. Clamped at half a percent,
    /// which is already a large premium on a liquid market.
    private func premiumBar(micros: Int, tint: DeskRGB) -> some View {
        GeometryReader { proxy in
            let limit = 5_000.0
            let offset = max(-1, min(1, Double(micros) / limit))
            let centre = proxy.size.width / 2

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DeskColor.nightLine.color)
                    .frame(height: 3)
                    .frame(maxHeight: .infinity, alignment: .center)

                // The index, fixed.
                Circle()
                    .strokeBorder(DeskColor.nightMuted.color, lineWidth: 2)
                    .frame(width: 11, height: 11)
                    .position(x: centre, y: proxy.size.height / 2)

                // The perp, offset by the premium.
                Circle()
                    .fill(tint.color)
                    .frame(width: 13, height: 13)
                    .shadow(color: tint.color.opacity(0.8), radius: 6)
                    .position(x: centre + offset * (centre - 10), y: proxy.size.height / 2)
            }
        }
        .frame(height: 18)
        .accessibilityElement()
        .accessibilityLabel("Premium over index")
        .accessibilityValue(Self.percent(micros))
    }

    // MARK: - The rows

    private func spread(_ signals: MarketSignals) -> some View {
        row(symbol: "arrow.left.and.right",
            title: "Spread",
            detail: signals.spreadMicros.map {
                $0 < 500 ? "Tight — cheap to get in and out" : "Wide — getting out will cost you"
            } ?? "No book to read",
            value: signals.spreadMicros.map(Self.percentUnsigned) ?? Unavailable.text,
            tint: signals.spreadMicros.map { $0 < 500 ? DeskColor.rise : DeskColor.action }
                ?? DeskColor.nightMuted)
    }

    private func flow(_ signals: MarketSignals) -> some View {
        let (detail, value, tint): (String, String, DeskRGB) = switch signals.lean {
        case .buyers: ("The last trade lifted the ask", "Buying", DeskColor.rise)
        case .sellers: ("The last trade hit the bid", "Selling", DeskColor.fall)
        case .balanced: ("Nothing decisive either way", "Balanced", DeskColor.nightMuted)
        }
        return row(symbol: "arrow.up.arrow.down", title: "Last trade",
                   detail: detail, value: value, tint: tint)
    }

    private func interest(_ signals: MarketSignals) -> some View {
        row(symbol: "chart.bar.fill",
            title: "Open interest",
            detail: signals.openInterest.map {
                $0.display(fractionDigits: 2) + " \(market.symbol) held across all positions"
            } ?? "Nothing open in this market",
            value: signals.openInterestNotional.map { "$" + $0.display(fractionDigits: 0) }
                ?? Unavailable.text,
            tint: DeskColor.nightText)
    }

    private func row(
        symbol: String, title: String, detail: String, value: String, tint: DeskRGB
    ) -> some View {
        HStack(spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DeskColor.nightMuted.color)
                .frame(width: 34, height: 34)
                .background(Color.white.opacity(0.05), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
                Text(detail)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Text(value)
                .font(.system(size: 14, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(tint.color)
                .contentTransition(.numericText())
        }
        .padding(14)
        .background(DeskColor.nightChip.color.opacity(0.45),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(DeskColor.nightLine.color, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }

    /// Skeletons rather than a spinner: the rows that will be here are drawn empty, so the
    /// screen reads as filling rather than as broken.
    private var waiting: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(0..<4, id: \.self) { index in
                SkeletonRow(widthFraction: [0.9, 0.55, 0.75, 0.45][index])
            }
        }
        .padding(18)
        .background(DeskColor.nightChip.color.opacity(0.45),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    static func percent(_ micros: Int) -> String {
        let sign = micros < 0 ? Direction.minus : "+"
        return sign + percentUnsigned(abs(micros))
    }

    static func percentUnsigned(_ micros: Int) -> String {
        "\(abs(micros) / 10_000).\(String(format: "%02d", (abs(micros) % 10_000) / 100))%"
    }
}
