import DeskUI
import SwiftUI

/// Progress deliberately resets between attempts: a bar that resumes where it stopped
/// rewards repeated jabbing, which is the input this exists to refuse.
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
            // VoiceOver cannot hold a button down, so there the system's double-tap plus a
            // label naming the consequence is the confirmation.
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
