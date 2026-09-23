import DeskUI
import SwiftUI

struct PositionCardMetric {
    let label: String
    let value: String
    var detail: String? = nil
    var tint: DeskRGB = DeskColor.nightText
    var isDimmed = false
}

/// The card every position is read on, whoever holds it: the market and the side above,
/// then figures in pairs, left and right.
struct PositionCard<Accessory: View>: View {
    let symbol: String
    let sideText: String
    let isLong: Bool
    let rows: [(PositionCardMetric, PositionCardMetric)]
    @ViewBuilder let accessory: () -> Accessory

    private var sideTint: Color { (isLong ? DeskColor.rise : DeskColor.fall).color }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                MarketTokenLogo(symbol: symbol, size: 30)
                Text(symbol)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
                Text(sideText)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(sideTint)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(sideTint.opacity(0.14), in: Capsule())
                Spacer(minLength: 8)
                accessory()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 14)

            VStack(spacing: 16) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, pair in
                    HStack(alignment: .top, spacing: 12) {
                        metric(pair.0, alignment: .leading)
                        metric(pair.1, alignment: .trailing)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .deskGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func metric(_ item: PositionCardMetric, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(item.label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(DeskColor.nightMuted.color)
            Text(item.value)
                .font(.system(size: 14, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(item.tint.color)
                .contentTransition(.numericText())
            if let detail = item.detail {
                Text(detail)
                    .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
        .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
        .opacity(item.isDimmed ? 0.55 : 1)
        .accessibilityElement(children: .combine)
    }
}

/// The round-button accessory the card carries when there is something to share.
struct PositionCardShareButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(DeskColor.nightText.color)
                .frame(width: 30, height: 30)
                .background(Color.white.opacity(0.08), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Share position")
    }
}
