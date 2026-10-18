import SwiftUI

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

public struct SkeletonRow: View {
    private let widthFraction: CGFloat

    public init(widthFraction: CGFloat = 1) {
        self.widthFraction = widthFraction
    }

    public var body: some View {
        GeometryReader { geometry in
            SkeletonBlock(width: geometry.size.width * widthFraction, height: 14, cornerRadius: 8)
        }
        .frame(height: 14)
    }
}

/// A placeholder the shape of a card, a chart or a figure that has not arrived yet.
public struct SkeletonBlock: View {
    private let width: CGFloat?
    private let height: CGFloat
    private let cornerRadius: CGFloat

    public init(width: CGFloat? = nil, height: CGFloat, cornerRadius: CGFloat = 12) {
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(skeletonBase)
            .frame(width: width, height: height)
            .modifier(SkeletonShimmer(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)))
            .accessibilityHidden(true)
    }
}

public struct SkeletonCircle: View {
    private let size: CGFloat

    public init(size: CGFloat = 38) {
        self.size = size
    }

    public var body: some View {
        Circle()
            .fill(skeletonBase)
            .frame(width: size, height: size)
            .modifier(SkeletonShimmer(shape: Circle()))
            .accessibilityHidden(true)
    }
}

/// N rows shaped like an avatar beside two lines of text, for a list that is still loading.
public struct SkeletonList: View {
    private let rows: Int
    private let avatarSize: CGFloat
    private let spacing: CGFloat

    public init(rows: Int = 4, avatarSize: CGFloat = 38, spacing: CGFloat = 18) {
        self.rows = rows
        self.avatarSize = avatarSize
        self.spacing = spacing
    }

    public var body: some View {
        VStack(spacing: spacing) {
            ForEach(0..<max(rows, 0), id: \.self) { index in
                HStack(spacing: 12) {
                    SkeletonCircle(size: avatarSize)
                    VStack(alignment: .leading, spacing: 8) {
                        SkeletonRow(widthFraction: [0.55, 0.7, 0.45, 0.62][index % 4])
                        SkeletonRow(widthFraction: [0.35, 0.28, 0.4, 0.3][index % 4])
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// A diagonal highlight sweeping across the placeholder; a slow pulse when motion is reduced.
private let skeletonBase = DeskColor.nightLine.color.opacity(0.55)

private struct SkeletonShimmer<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    func body(content: Content) -> some View {
        if reduceMotion {
            content
                .opacity(pulse ? 1 : 0.55)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
                }
        } else {
            content
                .overlay {
                    TimelineView(.animation) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                        let x = -0.7 + phase * 2.4
                        LinearGradient(
                            colors: [.clear, Color.white.opacity(0.11), .clear],
                            startPoint: UnitPoint(x: x, y: 0),
                            endPoint: UnitPoint(x: x + 0.7, y: 1))
                    }
                }
                .clipShape(shape)
        }
    }
}
