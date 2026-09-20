import DeskUI
import SwiftUI

struct MarketCrowdFeed: View {
    let crowd: [MarketCrowd]
    let name: (String) -> String
    let onOpenTrader: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Every open position on Perpl, added up per market.")
                .font(DeskType.caption)
                .foregroundStyle(DeskColor.nightMuted.color)
                .padding(.top, 16)

            if crowd.isEmpty {
                waiting.padding(.top, 30)
            } else {
                VStack(spacing: 10) {
                    ForEach(crowd) { market in
                        MarketCrowdCard(crowd: market, name: name, onOpenTrader: onOpenTrader)
                    }
                }
                .padding(.top, 18)
            }

            Text("Positions are read from Perpl's exchange contract, every one that is "
                 + "open, not a sample of them. A crowded side is not a signal on its own "
                 + "— it is what your copy would be joining.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(DeskColor.nightMuted.color.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 26)
        }
    }

    private var waiting: some View {
        HStack(spacing: 10) {
            ProgressView().tint(DeskColor.nightMuted.color)
            Text("Reading the book")
                .font(DeskType.label)
                .foregroundStyle(DeskColor.nightMuted.color)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct MarketCrowdCard: View {
    let crowd: MarketCrowd
    let name: (String) -> String
    let onOpenTrader: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            bar
            sides
            if let biggest = crowd.biggest { biggestRow(biggest) }
            if !crowd.complete { floorNote }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DeskColor.nightChip.color.opacity(0.6),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(DeskColor.nightLine.color, lineWidth: 0.5))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(crowd.market)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(DeskColor.nightText.color)
            Text(crowd.traders == 1 ? "1 trader" : "\(crowd.traders) traders")
                .font(DeskType.caption)
                .foregroundStyle(DeskColor.nightMuted.color)
            Spacer()
            Text(TraderFormat.compact(crowd.total))
                .font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(DeskColor.nightText.color)
        }
    }

    /// One bar, split where the money is. Long owns green and short owns red, the same
    /// way every other direction in the app does, so the bar needs no key.
    private var bar: some View {
        GeometryReader { proxy in
            let share = crowd.longShare ?? 0
            let width = max(0, proxy.size.width - 3)
            HStack(spacing: 3) {
                Capsule()
                    .fill(DeskColor.rise.color)
                    .frame(width: width * share)
                Capsule()
                    .fill(DeskColor.fall.color)
            }
        }
        .frame(height: 9)
        .animation(.snappy(duration: 0.35), value: crowd.longShareBps)
        .accessibilityElement()
        .accessibilityLabel("\(crowd.market) positioning")
        .accessibilityValue(shareText(crowd.longShare) + " long")
    }

    private var sides: some View {
        HStack(alignment: .top) {
            side(label: "long", share: crowd.longShare, traders: crowd.longTraders,
                 value: crowd.longValue, tint: DeskColor.rise, alignment: .leading)
            Spacer(minLength: 12)
            side(label: "short", share: crowd.longShare.map { 1 - $0 }, traders: crowd.shortTraders,
                 value: crowd.shortValue, tint: DeskColor.fall, alignment: .trailing)
        }
    }

    private func side(label: String, share: Double?, traders: Int, value: String,
                      tint: DeskRGB, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text("\(shareText(share)) \(label)")
                .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(tint.color)
            Text("\(traders) · \(TraderFormat.compact(Double(value)))")
                .font(DeskType.caption)
                .foregroundStyle(DeskColor.nightMuted.color)
        }
    }

    private func biggestRow(_ biggest: MarketCrowd.Biggest) -> some View {
        Button {
            if let address = biggest.address { onOpenTrader(address) }
        } label: {
            HStack(spacing: 8) {
                Text("Biggest")
                    .font(DeskType.caption)
                    .foregroundStyle(DeskColor.nightMuted.color)
                Text(biggest.address.map(name) ?? "Unknown")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(TraderFormat.compact(Double(biggest.value)))
                    .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle((biggest.isLong ? DeskColor.rise : DeskColor.fall).color)
                if let leverage = biggest.leverage {
                    Text(TraderFormat.leverage(leverage))
                        .font(DeskType.caption)
                        .foregroundStyle(DeskColor.nightMuted.color)
                }
                if biggest.address != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(DeskColor.nightMuted.color)
                }
            }
            .padding(.top, 2)
        }
        .buttonStyle(.plain)
        .disabled(biggest.address == nil)
    }

    /// The one place this screen can be wrong is by being short, so it says when it is.
    private var floorNote: some View {
        Text("More open than Desk could read in one pass — these are floors.")
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(DeskColor.action.color.opacity(0.9))
    }

    private func shareText(_ share: Double?) -> String {
        guard let share else { return Unavailable.text }
        return "\(Int((share * 100).rounded()))%"
    }
}
