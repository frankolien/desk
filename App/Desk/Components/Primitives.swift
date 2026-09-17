import DeskUI
import SwiftUI

/// The approved Desk identity from the app asset catalog.
///
/// Keeping the crop, corner treatment and shadow here means launch, onboarding and any
/// later branded surface cannot slowly turn into slightly different versions of the mark.
struct DeskBrandMark: View {
    let size: CGFloat

    init(size: CGFloat = 64) {
        self.size = size
    }

    var body: some View {
        Image("DeskLogo")
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .shadow(color: DeskColor.action.color.opacity(0.28), radius: size * 0.16, y: size * 0.06)
            .accessibilityHidden(true)
    }
}

/// The one filled action on a screen. Pine, because green is reserved for actions and
/// positive state, never decoration.
struct PrimaryButton: View {
    let title: String
    var tint: DeskRGB = DeskColor.action
    var isEnabled = true
    var action: () -> Void

    /// Dark text on every light fill, light text on the one dark fill. Chosen by the
    /// contrast the palette actually has rather than by which button it is.
    static func label(on tint: DeskRGB) -> DeskRGB {
        tint.contrastRatio(against: DeskColor.onFall) >= tint.contrastRatio(against: DeskColor.nightText)
            ? DeskColor.onFall : DeskColor.nightText
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(Self.label(on: tint).color)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 66)
                .background(tint.color.opacity(isEnabled ? 1 : 0.35))
                .clipShape(Capsule())
        }
        .disabled(!isEnabled)
    }
}

/// A label and a value on one line. The value is monospaced-digit so a column of them
/// does not ripple as it updates.
struct ValueRow: View {
    let label: String
    let value: String
    var detail: String?
    var tint: DeskRGB = DeskColor.nightText
    var isDimmed = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(DeskType.body)
                .foregroundStyle(DeskColor.nightMuted.color)
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 2) {
                Text(value)
                    .font(DeskType.value)
                    .foregroundStyle(tint.color)
                if let detail {
                    Text(detail)
                        .font(DeskType.caption)
                        .foregroundStyle(DeskColor.nightMuted.color)
                }
            }
        }
        .opacity(isDimmed ? 0.55 : 1)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// The app's one raised surface. Liquid Glass where the system supplies it, and a
    /// material with a hairline where it does not.
    @ViewBuilder
    func deskGlass<S: Shape>(interactive: Bool = false, in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(interactive), in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 0.6))
        }
    }
}

extension View {
    /// The one filled action in a native sheet: Liquid Glass tinted where the system has
    /// it, the standard prominent button where it does not.
    @ViewBuilder
    func deskProminentButton(tint: Color = DeskColor.action.color) -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent).tint(tint)
        } else {
            buttonStyle(.borderedProminent).tint(tint)
        }
    }

    @ViewBuilder
    func deskSecondaryButton() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}

/// Only ever on something tappable. Dark means flat: a chip is a hint, not a card.
struct Chip<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .font(DeskType.caption)
            .foregroundStyle(DeskColor.nightText.color)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(DeskColor.nightChip.color)
            .clipShape(Capsule())
    }
}

/// The app's own keypad, on the ground. Never the system keyboard sliding over the
/// figure the user is deciding about.
struct AmountKeypad: View {
    @Binding var text: String

    private let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", ".", "0", "\u{232B}"]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(keys, id: \.self) { key in
                Button { press(key) } label: {
                    Text(key)
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(DeskColor.nightText.color)
                        .frame(maxWidth: .infinity, minHeight: 56)
                }
                .accessibilityLabel(key == "\u{232B}" ? "Delete" : key)
            }
        }
    }

    private func press(_ key: String) {
        switch key {
        case "\u{232B}":
            if !text.isEmpty { text.removeLast() }
        case ".":
            if !text.contains(".") { text += text.isEmpty ? "0." : "." }
        default:
            // No leading zeros, and no more than two decimal places for a dollar figure.
            if text == "0" { text = key } else if decimals < 2 { text += key }
        }
    }

    private var decimals: Int {
        guard let point = text.firstIndex(of: ".") else { return 0 }
        return text.distance(from: text.index(after: point), to: text.endIndex)
    }
}
