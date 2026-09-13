import SwiftUI

/// The app's mark, drawn rather than borrowed from SF Symbols.
///
/// A system glyph is the clearest tell that a screen is a prototype: it is the same shape
/// every other app on the phone is using. This is a struck coin — a warm disc, a raised
/// rim, a price line cut into the face, and one specular highlight off the top left so it
/// reads as an object with a light on it rather than a flat circle.
public struct DeskMark: View {
    private let size: CGFloat

    public init(size: CGFloat = 64) {
        self.size = size
    }

    public var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(
                    colors: [
                        Color(red: 0.99, green: 0.83, blue: 0.42),
                        DeskColor.action.color,
                        Color(red: 0.72, green: 0.48, blue: 0.08),
                    ],
                    center: UnitPoint(x: 0.32, y: 0.24),
                    startRadius: 0,
                    endRadius: size * 0.82))

            // The rim, lit from the same direction as the face.
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.55), .clear, Color.black.opacity(0.28)],
                        startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: size * 0.045)

            Circle()
                .strokeBorder(Color.black.opacity(0.14), lineWidth: size * 0.03)
                .padding(size * 0.13)

            // The face: the same walk the hero draws, cut small.
            Path { path in
                let inset = size * 0.28
                let width = size - inset * 2
                let points: [CGFloat] = [0.62, 0.44, 0.70, 0.34, 0.52, 0.24]
                for (index, value) in points.enumerated() {
                    let x = inset + width * CGFloat(index) / CGFloat(points.count - 1)
                    let y = inset + width * value
                    index == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            .stroke(Color(red: 0.34, green: 0.21, blue: 0.02).opacity(0.85),
                    style: StrokeStyle(lineWidth: size * 0.075, lineCap: .round, lineJoin: .round))

            // One specular, off the top left, clipped to the disc.
            Ellipse()
                .fill(LinearGradient(
                    colors: [.white.opacity(0.42), .clear],
                    startPoint: .top, endPoint: .bottom))
                .frame(width: size * 0.66, height: size * 0.34)
                .offset(x: -size * 0.08, y: -size * 0.26)
                .blendMode(.plusLighter)
                .clipShape(Circle())
        }
        .frame(width: size, height: size)
        .shadow(color: DeskColor.action.color.opacity(0.45), radius: size * 0.22, y: size * 0.08)
        .accessibilityHidden(true)
    }
}

/// The feature ticker: a stack of phrases with one lit and the rest nearly gone.
///
/// Ported from the sibling app, where the same control sits commented out with the note
/// *"the ticker through Hold, Send, Request, Earn is switched off for now."* Its timings
/// are kept — 1.45 seconds a step, 0.55 to cross — because they are already tuned: fast
/// enough to read as alive, slow enough to actually read.
public struct FeatureTicker: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var active = 0

    private let items: [(symbol: String, title: String)]

    public init(items: [(symbol: String, title: String)]) {
        self.items = items
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                row(item, isActive: index == active)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            guard !reduceMotion, items.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.45))
                withAnimation(.smooth(duration: 0.55)) {
                    active = (active + 1) % items.count
                }
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func row(_ item: (symbol: String, title: String), isActive: Bool) -> some View {
        HStack(spacing: 12) {
            if isActive {
                Image(systemName: item.symbol)
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
                    .transition(.move(edge: .leading).combined(with: .opacity).combined(with: .scale))
            }
            Text(item.title)
                .font(.system(size: isActive ? 28 : 22, weight: .bold, design: .rounded))
                .foregroundStyle(isActive ? DeskColor.nightText.color : DeskColor.nightText.color.opacity(0.13))
        }
        .padding(.horizontal, isActive ? 22 : 0)
        .frame(height: isActive ? 56 : 28)
        .background {
            if isActive {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 0.5))
            }
        }
        .animation(.smooth(duration: 0.55), value: isActive)
    }
}
