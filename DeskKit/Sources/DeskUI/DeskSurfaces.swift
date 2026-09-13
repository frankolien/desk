import SwiftUI

/// The ground every screen sits on.
///
/// Never flat black. A single off-centre light source at four percent white is the
/// cheapest device in the reference set and its absence is the most reliable tell of an
/// unfinished app — the same move as the reference app's diagonal sheen across pure
/// black, or the starfield its closest competitor uses. One light, always from the same
/// direction, so the app reads as one lit room rather than a stack of screens.
public struct DeskBackground: View {
    public init() {}

    public var body: some View {
        ZStack {
            DeskColor.night.color
            RadialGradient(
                colors: [DeskColor.action.color.opacity(0.07), .clear],
                center: UnitPoint(x: 0.86, y: 0.06),
                startRadius: 0,
                endRadius: 520)
            RadialGradient(
                colors: [Color.white.opacity(0.035), .clear],
                center: UnitPoint(x: 0.08, y: 0.82),
                startRadius: 0,
                endRadius: 460)
        }
        .ignoresSafeArea()
    }
}

/// A chip that reads as glass rather than as a filled badge.
///
/// Faint light border, material behind, and nothing else. Filled badges are the
/// prototype look; every app in the reference set that feels expensive uses this instead.
public struct GlassChip<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(DeskColor.nightText.color)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
    }
}

/// A row that is present but has nothing in it yet.
///
/// Emptiness should read as loading rather than as failure — the reference wallet renders
/// its welcome screen with skeleton token rows standing in for tokens the user does not
/// own, which is why a brand new account looks like it is filling rather than broken.
public struct SkeletonRow: View {
    private let widthFraction: CGFloat

    public init(widthFraction: CGFloat = 1) {
        self.widthFraction = widthFraction
    }

    @State private var shimmer = false

    public var body: some View {
        GeometryReader { geometry in
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(DeskColor.nightLine.color.opacity(shimmer ? 0.75 : 0.4))
                .frame(width: geometry.size.width * widthFraction)
        }
        .frame(height: 14)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                shimmer = true
            }
        }
        .accessibilityHidden(true)
    }
}
