import SwiftUI

public struct AssetMark: View {
    private let glyph: String
    private let tint: Color
    private let size: CGFloat

    public init(glyph: String, tint: Color, size: CGFloat = 38) {
        self.glyph = glyph
        self.tint = tint
        self.size = size
    }

    /// Bitcoin's own orange, not the app's amber. The distinction is the point.
    public static func bitcoin(size: CGFloat = 38) -> AssetMark {
        AssetMark(glyph: "₿", tint: Color(red: 0.97, green: 0.58, blue: 0.10), size: size)
    }

    public var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [tint.opacity(0.95), tint, tint.opacity(0.72)],
                        center: UnitPoint(x: 0.32, y: 0.24),
                        startRadius: 0,
                        endRadius: size * 0.95))

            Text(glyph)
                .font(.system(size: size * 0.54, weight: .bold, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.78))

            // The same top-leading light as every other surface, so the disc reads as an
            // object in the room rather than a flat swatch.
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.5), .clear],
                        startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: max(0.5, size * 0.022))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
