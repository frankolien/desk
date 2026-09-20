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

            Button(action: onEnable) {
                Text("Turn On Alerts")
                    .font(.headline)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .controlSize(.large)
            .deskProminentButton()
            Button("Not Now", action: onLater)
                .font(.headline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.top, 6)
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

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            GlassPage {
                GlassSection {
                    HStack(spacing: 14) {
                        TraderAvatar(address: alert.trader, size: 38)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(name)
                                .font(.headline)
                                .lineLimit(1)
                            Text("\(headline) · \(alert.observedAt.formatted(.relative(presentation: .named)))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                GlassSection("Perpl mainnet", footer: closedSince ? "They've closed this since the alert."
                             : (alert.canCopy ? "Copy opens your own ticket at the same market, side and leverage. You choose the amount." : nil)) {
                    GlassRow("\(alert.market)-PERP") {
                        Text("\(alert.isLong ? "Long" : "Short") \(TraderFormat.leverage(alert.leverage))")
                            .fontWeight(.semibold)
                            .foregroundStyle(sideTint.color)
                    }
                    GlassRow("Their entry", value: TraderFormat.price(alert.entry))
                    GlassRow("Mark now", value: livePosition.map { TraderFormat.price($0.mark) } ?? (loaded ? Unavailable.text : "…"))
                    GlassRow("Since entry") {
                        Text(move.map { String(format: "%@%.2f%%", $0 < 0 ? Direction.minus : "+", abs($0)) } ?? "…")
                            .foregroundStyle(move.map { ($0 < 0 ? DeskColor.fall : DeskColor.rise).color } ?? .secondary)
                            .monospacedDigit()
                    }
                    GlassRow("Their position", value: TraderFormat.dollars(livePosition?.value ?? alert.value, signed: false))
                    GlassRow("Their open PnL") {
                        Text(livePosition.map { TraderFormat.dollars($0.pnl) } ?? (loaded ? Unavailable.text : "…"))
                            .foregroundStyle(livePosition.map { ($0.isProfit ? DeskColor.rise : DeskColor.fall).color } ?? .secondary)
                            .monospacedDigit()
                    }
                }
            }
            .navigationTitle("Trade Alert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    if alert.canCopy {
                        Button { onCopy(alert) } label: {
                            Text("Copy \(alert.isLong ? "Long" : "Short") \(TraderFormat.leverage(alert.leverage))")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.black)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 2)
                        }
                        .controlSize(.large)
                        .deskProminentButton()
                        .disabled(closedSince)
                    }
                    Button { onViewTrader(alert.trader) } label: {
                        Text("View \(name)")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 2)
                    }
                    .controlSize(.large)
                    .deskSecondaryButton()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }
        }
        .task {
            live = await directory.trader(alert.trader)
            loaded = live != nil
        }
    }
}
