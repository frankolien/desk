import DeskUI
import SwiftUI

/// One quick brand beat between iOS's static launch frame and the restored app state.
/// It never waits for networking and disappears in under a second.
struct LaunchMoment: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var struck = false
    @State private var wordmark = false
    @State private var message = false
    @State private var lightSweep = false

    var body: some View {
        ZStack {
            DeskColor.night.color

            RadialGradient(
                colors: [
                    DeskColor.action.color.opacity(struck ? 0.13 : 0),
                    .clear,
                ],
                center: .center,
                startRadius: 0,
                endRadius: 260)
                .scaleEffect(struck ? 1.08 : 0.5)

            LinearGradient(
                colors: [.clear, DeskColor.action.color.opacity(0.34), .white.opacity(0.22), .clear],
                startPoint: .leading,
                endPoint: .trailing)
                .frame(width: 180, height: 2)
                .blur(radius: 10)
                .scaleEffect(y: 18)
                .offset(x: lightSweep ? 310 : -310)
                .opacity(lightSweep ? 0 : 1)

            VStack(spacing: 0) {
                DeskMark(size: 76)
                    .scaleEffect(struck ? 1 : 0.62)
                    .rotation3DEffect(.degrees(struck ? 0 : -42), axis: (x: 0, y: 1, z: 0))
                    .blur(radius: struck ? 0 : 14)
                    .opacity(struck ? 1 : 0)

                Capsule()
                    .fill(DeskColor.action.color.opacity(0.7))
                    .frame(width: wordmark ? 38 : 0, height: 1.5)
                    .padding(.top, 16)

                Text("Desk")
                    .font(.system(size: 44, weight: .heavy, design: .rounded))
                    .tracking(wordmark ? -1.2 : 8)
                    .foregroundStyle(.white)
                    .padding(.top, 7)
                    .blur(radius: wordmark ? 0 : 12)
                    .scaleEffect(wordmark ? 1 : 1.08)
                    .opacity(wordmark ? 1 : 0)

                Text("PERPETUALS, WITHOUT THE FRICTION")
                    .font(.caption2.weight(.semibold))
                    .tracking(1.8)
                    .foregroundStyle(.white.opacity(0.52))
                    .padding(.top, 6)
                    .offset(y: message ? 0 : 6)
                    .blur(radius: message ? 0 : 5)
                    .opacity(message ? 1 : 0)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            if reduceMotion {
                struck = true
                wordmark = true
                message = true
            } else {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(280))
                    withAnimation(.easeOut(duration: 1.0)) { lightSweep = true }
                    try? await Task.sleep(for: .milliseconds(180))
                    withAnimation(.spring(response: 0.82, dampingFraction: 0.78)) {
                        struck = true
                    }
                    try? await Task.sleep(for: .milliseconds(430))
                    withAnimation(.easeOut(duration: 0.72)) { wordmark = true }
                    try? await Task.sleep(for: .milliseconds(520))
                    withAnimation(.easeOut(duration: 0.55)) { message = true }
                }
            }
        }
    }
}
