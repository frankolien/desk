import DeskUI
import SwiftUI

/// Confirmation by holding, not by tapping.
///
/// A tap is the wrong gesture for an irreversible, leveraged order. It is the same gesture
/// as scrolling past, it is what a mis-aimed thumb produces, and it is what the rest of
/// the screen has been teaching for the previous minute. A hold cannot happen by accident:
/// it takes a decision to start and a second decision not to let go.
///
/// Every exchange app that ships leverage on a phone has converged on this or on a swipe,
/// and a hold is the better of the two — a swipe has a direction, and on a screen where
/// direction already means long or short, a second directional gesture is one meaning too
/// many.
///
/// Releasing early cancels and says so. The progress does not persist between attempts,
/// because a bar that resumes where it stopped rewards repeated jabbing, which is the
/// input this exists to refuse.
struct HoldToConfirm: View {
    let title: String
    let tint: DeskRGB
    var duration: Duration = .milliseconds(900)
    var isEnabled = true
    let action: () -> Void

    @State private var progress: Double = 0
    @State private var isHolding = false
    @State private var ticker: Task<Void, Never>?

    private var label: DeskRGB { PrimaryButton.label(on: tint) }

    var body: some View {
        ZStack {
            Capsule().fill(tint.color.opacity(isEnabled ? 0.24 : 0.1))

            // The fill is the gesture made visible. It is the whole control; the text on
            // top only names what is about to happen.
            GeometryReader { proxy in
                Capsule()
                    .fill(tint.color)
                    .frame(width: proxy.size.width * progress)
            }
            .clipShape(Capsule())

            HStack(spacing: 8) {
                Image(systemName: isHolding ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: 14, weight: .bold))
                Text(isHolding ? "Keep holding…" : title)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            // Once the fill is past the text the label has to survive on top of the tint,
            // so it switches to the colour computed for that fill rather than staying
            // white and disappearing into it.
            .foregroundStyle(progress > 0.55 ? label.color : DeskColor.nightText.color)
            .animation(.easeInOut(duration: 0.15), value: progress > 0.55)
            .padding(.horizontal, 22)
        }
        .frame(height: 62)
        .opacity(isEnabled ? 1 : 0.45)
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if isEnabled, !isHolding { begin() } }
                .onEnded { _ in cancel() })
        .accessibilityRepresentation {
            // VoiceOver cannot hold a button down, and a control nobody using VoiceOver
            // can operate is not a safety feature. The confirmation there is the system's
            // own double-tap plus the label naming the consequence.
            Button(title, action: action).disabled(!isEnabled)
        }
        .onDisappear { ticker?.cancel() }
    }

    private func begin() {
        isHolding = true
        Haptics.selection()
        let steps = 60
        let step = duration / steps
        ticker?.cancel()
        ticker = Task { @MainActor in
            for index in 1...steps {
                try? await Task.sleep(for: step)
                guard !Task.isCancelled, isHolding else { return }
                withAnimation(.linear(duration: 0.016)) { progress = Double(index) / Double(steps) }
            }
            guard isHolding else { return }
            isHolding = false
            Haptics.success()
            action()
            // Reset after the action, so the control does not sit full behind whatever
            // the action presented.
            withAnimation(.easeOut(duration: 0.25)) { progress = 0 }
        }
    }

    private func cancel() {
        guard isHolding else { return }
        ticker?.cancel()
        isHolding = false
        withAnimation(.easeOut(duration: 0.2)) { progress = 0 }
    }
}

/// The three moments in this app worth a physical response.
///
/// Deliberately few. Haptics used as decoration stop meaning anything, and on a trading
/// screen the one that matters is the fill — the confirmation that something irreversible
/// happened while the user was looking at their thumb rather than at the screen.
enum Haptics {
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func failure() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
