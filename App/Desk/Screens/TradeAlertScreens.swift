import DeskUI
import SwiftUI

/// Shown before iOS asks for notification permission, so the system prompt arrives with a
/// reason attached. The preview is drawn from the trader's real book when they have one.
struct AlertsPrimerSheet: View {
    let trader: TraderSnapshot
    let name: String
    let onEnable: () -> Void
    let onLater: () -> Void

    @State private var appeared = false

    private var sample: (title: String, body: String) {
        guard let position = trader.positions.max(by: { (Double($0.value) ?? 0) < (Double($1.value) ?? 0) }) else {
            return ("\(name) opened a position", "Tap to copy it on your own account.")
        }
        return ("\(name) opened a \(position.side)",
                "\(position.market) \(TraderFormat.leverage(position.leverage)) at $\(TraderFormat.price(position.entry)), "
                + "\(TraderFormat.compact(Double(position.value))) position. Tap to copy.")
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                banner(title: sample.title, body: sample.body, time: "now")
                    .redacted(reason: .placeholder)
                    .scaleEffect(0.92)
                    .offset(y: appeared ? 14 : 0)
                    .opacity(appeared ? 0.45 : 0)
                banner(title: sample.title, body: sample.body, time: "now")
                    .offset(y: appeared ? 0 : -16)
                    .opacity(appeared ? 1 : 0)
            }
            .padding(.top, 34)
            .padding(.bottom, 14)
            .accessibilityHidden(true)

            Text("Know the moment they trade")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.top, 26)

            Text("Desk watches \(name) on Perpl and tells you when they open, add to or close a position. Tap the alert to copy it with your own key.")
                .font(.system(size: 15, weight: .regular, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
                .padding(.horizontal, 8)

            Spacer(minLength: 24)

            PrimaryButton(title: "Turn on alerts", action: onEnable)
            Button("Not now", action: onLater)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.65))
                .frame(maxWidth: .infinity, minHeight: 48)
                .padding(.top, 4)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
        .background(Color(red: 0.07, green: 0.07, blue: 0.08).ignoresSafeArea())
        .onAppear { withAnimation(.spring(duration: 0.55, bounce: 0.25).delay(0.15)) { appeared = true } }
    }

    private func banner(title: String, body: String, time: String) -> some View {
        HStack(alignment: .center, spacing: 11) {
            Image("DeskLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(time)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.5))
                }
                Text(body)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(red: 0.16, green: 0.16, blue: 0.17), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
    }
}

/// What a tapped alert opens: the move, where the market is now against their entry, and
/// the copy. Their book is read again first, so a trade closed since the alert says so
/// rather than inviting a copy of something they have left.
struct TradeAlertSheet: View {
    let alert: TradeAlert
    let directory: TraderDirectory
    let onCopy: (TradeAlert) -> Void
    let onViewTrader: (String) -> Void

    @State private var live: TraderSnapshot?
    @State private var loaded = false

    private var name: String { directory.name(for: alert.trader) }
    private var livePosition: TraderPosition? {
        live?.positions.first { $0.market.caseInsensitiveCompare(alert.market) == .orderedSame }
    }
    private var closedSince: Bool { loaded && alert.canCopy && livePosition?.side != alert.side }
    private var sideTint: DeskRGB { alert.isLong ? DeskColor.rise : DeskColor.fall }

    private var headline: String {
        switch alert.event {
        case .opened: "Opened a \(alert.side)"
        case .flipped: "Flipped to \(alert.side)"
        case .added: "Added to their \(alert.side)"
        case .closed: "Closed their \(alert.side)"
        }
    }

    /// The market's move since their entry, signed for their side: positive is working.
    private var move: Double? {
        guard let entry = Double(alert.entry), entry > 0,
              let mark = livePosition.flatMap({ Double($0.mark) }) else { return nil }
        let change = (mark - entry) / entry * 100
        return alert.isLong ? change : -change
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                TraderAvatar(address: alert.trader, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("\(headline) · \(alert.observedAt.formatted(.relative(presentation: .named)))")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 28)

            card.padding(.top, 20)

            if closedSince {
                Label("They've closed this since the alert.", systemImage: "info.circle")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .padding(.top, 12)
            }

            Spacer(minLength: 20)

            if alert.canCopy {
                PrimaryButton(
                    title: "Copy \(alert.side) \(TraderFormat.leverage(alert.leverage))",
                    isEnabled: !closedSince
                ) { onCopy(alert) }
                Text("Opens your own ticket at the same market, side and leverage. You choose the amount.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)
            }
            Button { onViewTrader(alert.trader) } label: {
                Text("View \(name)")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(alert.canCopy ? 0.7 : 1))
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(alert.canCopy ? Color.clear : Color.white.opacity(0.1), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .background(Color(red: 0.07, green: 0.07, blue: 0.08).ignoresSafeArea())
        .task {
            live = await directory.trader(alert.trader)
            loaded = live != nil
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                MarketTokenLogo(symbol: alert.market, size: 30)
                Text("\(alert.market)-PERP")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("\(alert.isLong ? "Long" : "Short") \(TraderFormat.leverage(alert.leverage))")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(sideTint.color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(sideTint.color.opacity(0.14), in: Capsule())
                Spacer(minLength: 0)
            }

            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    figure("Their entry", TraderFormat.price(alert.entry))
                    figure("Mark now", livePosition.map { TraderFormat.price($0.mark) } ?? (loaded ? Unavailable.text : "…"))
                    figure("Since entry", move.map { String(format: "%@%.2f%%", $0 < 0 ? Direction.minus : "+", abs($0)) } ?? "…",
                           tint: move.map { ($0 < 0 ? DeskColor.fall : DeskColor.rise).color } ?? .white)
                }
                GridRow {
                    figure("Their position", TraderFormat.dollars(livePosition?.value ?? alert.value, signed: false))
                    figure("Open PnL", livePosition.map { TraderFormat.dollars($0.pnl) } ?? (loaded ? Unavailable.text : "…"),
                           tint: livePosition.map { ($0.isProfit ? DeskColor.rise : DeskColor.fall).color } ?? .white)
                    figure("Network", "Perpl mainnet")
                }
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
    }

    private func figure(_ title: String, _ value: String, tint: Color = .white) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.45))
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
