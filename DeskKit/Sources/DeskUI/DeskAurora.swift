import SwiftUI

/// The wash behind the balance.
///
/// Amber alone is a flat yellow, and a flat yellow behind a figure reads as a filter
/// rather than as light. So the ground under the balance is a mesh: amber at its core,
/// warmed to orange and bronze down the left, and cooled into Monad's violet on the
/// right, with the brand's near-black in the outer corners. The violet is not decoration
/// — it is the chain the app trades on, and the one other colour Desk has a reason to
/// wear. Two hues that far apart also stop the field reading as a single tint: the eye
/// sees a light crossing the screen rather than a yellow filter laid over it.
///
/// A mesh rather than stacked radial gradients because a mesh interpolates in one pass:
/// the seams between hues are real blends rather than two translucent circles
/// overlapping, which is the look the grant review called generated. The points drift
/// slowly and the field is masked to the top third, so the colour stays a light in one
/// corner of the room and everything from the rows down is the same near-black as the
/// rest of the app.
public struct DeskAurora: View {
    private let height: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    public init(height: CGFloat = 430) {
        self.height = height
    }

    public var body: some View {
        MeshGradient(
            width: 3,
            height: 3,
            points: points,
            colors: colours,
            smoothsColors: true)
            .frame(height: height)
            // Softens the mesh's own vertices, which are otherwise just visible as
            // faint corners in a field this large.
            .blur(radius: 42)
            // The colour is a light, not a layer: it fades out entirely before the
            // rows begin, so nothing below the actions sits on a tinted ground.
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .white, location: 0),
                        .init(color: .white.opacity(0.9), location: 0.45),
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

    /// The middle row and the centre point drift; the corners are pinned, so the mesh
    /// stays a rectangle and only the light inside it moves.
    private var points: [SIMD2<Float>] {
        let drift = Float(phase)
        return [
            SIMD2(0, 0), SIMD2(0.5 + drift * 0.08, 0), SIMD2(1, 0),
            SIMD2(0, 0.5 - drift * 0.06), SIMD2(0.42 + drift * 0.14, 0.46 + drift * 0.08), SIMD2(1, 0.5 + drift * 0.06),
            SIMD2(0, 1), SIMD2(0.5 - drift * 0.1, 1), SIMD2(1, 1),
        ]
    }

    private var colours: [Color] {
        let night = DeskColor.night.color
        return [
            night, Self.amber.opacity(0.85), Self.violet.opacity(0.7),
            Self.orange.opacity(0.8), Self.amber, Self.violet.opacity(0.55),
            night, Self.bronze.opacity(0.6), night,
        ]
    }

    // Amber is the brand; orange and bronze are the same hue family either side of it,
    // so the warm half reads as one light rather than as three colours. The violet is
    // Monad's own.
    private static let amber = DeskColor.action.color
    private static let orange = DeskColor.impactOrange.color
    private static let bronze = Color(red: 0.54, green: 0.31, blue: 0.05)
    private static let violet = Color(red: 0.51, green: 0.43, blue: 0.98)
}
