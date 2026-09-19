import SwiftUI

/// The wash behind the balance.
///
/// Amber alone is a flat yellow, and a flat yellow behind a figure reads as a filter
/// rather than as light. So the ground under the balance is a mixture of two colours the
/// app already owns: its own amber, and Monad's violet — the chain it trades on, and the
/// one other hue Desk has a reason to wear.
///
/// The mixing happens before the mesh, not inside it. An earlier version put amber on the
/// left of the grid and violet on the right, and that is exactly what it looked like: a
/// yellow half and a blue half meeting in the middle. Here every vertex is already both
/// colours in a different ratio, and no vertex is either colour on its own, so the field
/// reads as one indeterminate mixture rather than as two named colours sharing a screen.
/// Each stop is then mixed down into the near-black ground, which is what keeps it dim —
/// a wash this large goes garish long before it goes bright.
///
/// A mesh rather than stacked radial gradients because a mesh interpolates in one pass:
/// the seams are real blends rather than two translucent circles overlapping, which is
/// the look the grant review called generated. A four by four grid rather than three by
/// three because the extra ring of vertices lets the ratios shift several times across
/// the screen — the marbling is those crossings, blurred.
public struct DeskAurora: View {
    private let height: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    public init(height: CGFloat = 430) {
        self.height = height
    }

    public var body: some View {
        MeshGradient(
            width: 4,
            height: 4,
            points: points,
            colors: colours,
            smoothsColors: true)
            .frame(height: height)
            // Heavy enough to melt the grid's own vertices into each other. Without it
            // the crossings read as sixteen soft squares rather than as one field.
            .blur(radius: 58)
            // The colour is a light, not a layer: it fades out entirely before the
            // rows begin, so nothing below the actions sits on a tinted ground.
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .white, location: 0),
                        .init(color: .white.opacity(0.88), location: 0.45),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                guard !reduceMotion else { return }
                // Eighteen seconds a cycle. Slow enough that nobody watching the screen
                // sees it move, fast enough that the screen is never twice the same.
                withAnimation(.easeInOut(duration: 18).repeatForever(autoreverses: true)) {
                    phase = 1
                }
            }
    }

    /// Edge vertices stay on their edge, so the field remains a rectangle; the four
    /// interior ones drift, which is what moves the mixture around.
    private var points: [SIMD2<Float>] {
        let drift = Float(phase)
        return [
            SIMD2(0, 0),
            SIMD2(0.34 + drift * 0.05, 0),
            SIMD2(0.68 - drift * 0.04, 0),
            SIMD2(1, 0),

            SIMD2(0, 0.33 - drift * 0.04),
            SIMD2(0.29 + drift * 0.11, 0.37 + drift * 0.06),
            SIMD2(0.71 - drift * 0.09, 0.30 + drift * 0.08),
            SIMD2(1, 0.34 + drift * 0.05),

            SIMD2(0, 0.68 + drift * 0.03),
            SIMD2(0.36 - drift * 0.09, 0.69 - drift * 0.05),
            SIMD2(0.65 + drift * 0.08, 0.71 + drift * 0.04),
            SIMD2(1, 0.67 - drift * 0.04),

            SIMD2(0, 1),
            SIMD2(0.33 - drift * 0.05, 1),
            SIMD2(0.67 + drift * 0.04, 1),
            SIMD2(1, 1),
        ]
    }

    /// Ratios rather than colours. Reading across, the amber-to-violet balance tips back
    /// and forth instead of crossing once, so there is no line where one colour ends.
    private var colours: [Color] {
        [
            Self.deep, Self.leaning, Self.crossed, Self.deep,
            Self.tipped, Self.warm, Self.cool, Self.crossed,
            Self.crossed, Self.leaning, Self.tipped, Self.deep,
            Self.deep, Self.crossed, Self.deep, Self.deep,
        ]
    }

    private static let amber = DeskColor.action.color
    private static let violet = Color(red: 0.51, green: 0.43, blue: 0.98)
    private static let night = DeskColor.night.color

    /// Six ratios of the same two colours, each then taken most of the way down to the
    /// ground. Mixed perceptually, so amber into violet passes through a dulled bronze
    /// rather than through the grey that a straight RGB average would give.
    private static let warm = blend(0.24, ground: 0.42)
    private static let leaning = blend(0.38, ground: 0.50)
    private static let crossed = blend(0.52, ground: 0.56)
    private static let tipped = blend(0.64, ground: 0.52)
    private static let cool = blend(0.76, ground: 0.46)
    private static let deep = blend(0.50, ground: 0.84)

    private static func blend(_ towardsViolet: Double, ground: Double) -> Color {
        amber
            .mix(with: violet, by: towardsViolet, in: .perceptual)
            .mix(with: night, by: ground, in: .perceptual)
    }
}
