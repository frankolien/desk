import DeskUI
import SwiftUI

struct LaunchMoment: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        ZStack {
            DeskColor.night.color

            Image("DeskGlyph")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 96, height: 96)
                .scaleEffect(shown ? 1 : 0.86)
                .opacity(shown ? 1 : 0)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            if reduceMotion {
                shown = true
            } else {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.85).delay(0.15)) { shown = true }
            }
        }
    }
}
