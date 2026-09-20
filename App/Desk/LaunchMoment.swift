import DeskUI
import SwiftUI


struct LaunchMoment: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var struck = false
    @State private var lightSweep = false

    var body: some View {
        ZStack {
            DeskColor.night.color

            RadialGradient(
                colors: [
                    DeskColor.action.color.opacity(struck ? 0.15 : 0),
                    .clear,
                ],
                center: .center,
                startRadius: 0,
                endRadius: 280)
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

            DeskBrandMark(size: 104)
                .scaleEffect(struck ? 1 : 0.62)
                .rotation3DEffect(.degrees(struck ? 0 : -42), axis: (x: 0, y: 1, z: 0))
                .blur(radius: struck ? 0 : 14)
                .opacity(struck ? 1 : 0)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            if reduceMotion {
                struck = true
            } else {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(280))
                    withAnimation(.easeOut(duration: 1.0)) { lightSweep = true }
                    try? await Task.sleep(for: .milliseconds(180))
                    withAnimation(.spring(response: 0.82, dampingFraction: 0.78)) {
                        struck = true
                    }
                }
            }
        }
    }
}
