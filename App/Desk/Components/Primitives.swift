import DeskUI
import SwiftUI
import UIKit

@MainActor
enum Haptics {
    static func touch() {
        let generator = UIImpactFeedbackGenerator(style: .soft)
        generator.prepare()
        generator.impactOccurred(intensity: 0.72)
    }

    static func selection() {
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }

    static func commit() {
        let generator = UIImpactFeedbackGenerator(style: .rigid)
        generator.prepare()
        generator.impactOccurred(intensity: 0.9)
    }

    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    static func failure() { error() }
}

struct DeskPressStyle: ButtonStyle {
    var haptic = true
    var scale: CGFloat = 0.975

    func makeBody(configuration: Configuration) -> some View {
        Pressed(configuration: configuration, haptic: haptic, scale: scale)
    }

    private struct Pressed: View {
        let configuration: Configuration
        let haptic: Bool
        let scale: CGFloat
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
                .opacity(configuration.isPressed ? 0.82 : 1)
                .animation(.snappy(duration: 0.14), value: configuration.isPressed)
                .onChange(of: configuration.isPressed) { _, pressed in
                    if pressed, haptic { Haptics.touch() }
                }
        }
    }
}

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
        .buttonStyle(DeskPressStyle(scale: 0.985))
        .disabled(!isEnabled)
    }
}

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

struct AmountKeypad: View {
    @Binding var text: String
    var keyHeight: CGFloat = 56
    var spacing: CGFloat = 8

    private let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", ".", "0", "\u{232B}"]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: spacing) {
            ForEach(keys, id: \.self) { key in
                Button { press(key) } label: {
                    Text(key)
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(DeskColor.nightText.color)
                        .frame(maxWidth: .infinity, minHeight: keyHeight)
                }
                .accessibilityLabel(key == "\u{232B}" ? "Delete" : key)
                .buttonStyle(DeskPressStyle(scale: 0.92))
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
            if text == "0" { text = key } else if decimals < 2 { text += key }
        }
    }

    private var decimals: Int {
        guard let point = text.firstIndex(of: ".") else { return 0 }
        return text.distance(from: text.index(after: point), to: text.endIndex)
    }
}

/// A sheet the height of its content, measured at its ideal height: a fixed detent is right only
/// on the phone it was tuned on.
struct FittedSheet: ViewModifier {
    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .frame(maxHeight: .infinity, alignment: .top)
            .presentationDetents([.height(max(height, 1))])
    }
}

extension View {
    func fittedSheet() -> some View { modifier(FittedSheet()) }
}
