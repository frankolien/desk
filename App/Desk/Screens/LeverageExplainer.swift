import DeskMoney
import DeskUI
import SwiftUI

struct LeverageExplainer: View {
    let onAgree: () -> Void
    let onBack: () -> Void

    @State private var accepted: Set<Int> = []

    /// BTC's ceiling: initial margin fraction 1500, maintenance 2500.
    private var liquidationDistance: String {
        guard let micros = Margin.liquidationDistanceMicros(
            leverageHundredths: 1_500, maintenanceMarginFraction: 2_500)
        else { return "a small" }
        return String(format: "%.2f%%", Double(micros) / 10_000)
    }

    private var terms: [String] {
        [
            "Leverage amplifies risk. Bigger gains when I am right, faster losses when I am wrong. At 15× on BTC a \(liquidationDistance) move against me closes the position and takes the collateral behind it.",
            "A liquidation is not a warning. There is no margin call and nobody rings. The position closes.",
            "My passkey is the only way into this account. If I lose it and its iCloud backup, nobody — including Desk — can recover the funds.",
        ]
    }

    private var canContinue: Bool { accepted.count == terms.count }

    var body: some View {
        ZStack {
            DeskBackground()

            VStack(alignment: .leading, spacing: 0) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .frame(width: 36, height: 36)
                        .background(DeskColor.nightChip.color)
                        .clipShape(Circle())
                }
                .accessibilityLabel("Back")

                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(DeskColor.impactAmber.color)
                    .padding(.top, 28)

                Text("Before you use leverage")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(DeskColor.nightText.color)
                    .padding(.top, 16)

                Text("Three things, once. Tap each one.")
                    .font(DeskType.body)
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .padding(.top, 6)

                VStack(spacing: 10) {
                    ForEach(Array(terms.enumerated()), id: \.offset) { index, term in
                        TermCard(text: term, isAccepted: accepted.contains(index)) {
                            if accepted.contains(index) { accepted.remove(index) } else { accepted.insert(index) }
                        }
                    }
                }
                .padding(.top, 24)

                Spacer()

                // The button says what is missing rather than sitting there dead.
                PrimaryButton(
                    title: canContinue
                        ? "Got it"
                        : "\(terms.count - accepted.count) left to read",
                    isEnabled: canContinue,
                    action: onAgree)
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .animation(.snappy(duration: 0.18), value: accepted)
    }
}

private struct TermCard: View {
    let text: String
    let isAccepted: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle()
                        .stroke(isAccepted ? Color.clear : DeskColor.nightLine.color, lineWidth: 1.5)
                        .frame(width: 24, height: 24)
                    if isAccepted {
                        Circle().fill(DeskColor.action.color).frame(width: 24, height: 24)
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(DeskColor.night.color)
                    }
                }
                Text(text)
                    .font(DeskType.body)
                    .foregroundStyle(DeskColor.nightText.color)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(DeskColor.nightChip.color)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isAccepted ? DeskColor.action.color.opacity(0.45) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isAccepted ? [.isButton, .isSelected] : .isButton)
    }
}
