import SwiftUI

/// The lit band at the top of the first screen.
///
/// A glyph on a black ground reads as code. Half the screen given over to something that
/// moves reads as a product, and the sibling app proves the point: its welcome hands the
/// top half to a video clip and keeps it alive afterwards with a drawn field of motes,
/// precisely because *"a looped clip restarts on a fixed period and the eye finds it
/// within a couple of passes."*
///
/// There is no footage for this app, so the whole band is drawn. Two layers: a slow field
/// of embers, and a price line that is actually a price — the same walk, seeded, so it is
/// the same hero on every launch rather than a different one each time.
public struct DeskHero: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    private struct Ember {
        let x: Double, y: Double, radius: Double
        let drift: Double, twinkle: Double, phase: Double, warmth: Double
    }

    /// Frequencies that share no common divisor, so the field never lands back where it
    /// started and the loop cannot be seen.
    private static let embers: [Ember] = {
        var seed: UInt64 = 0x5EED_DE5C_0000_0001
        func next() -> Double {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return Double(seed % 100_000) / 100_000
        }
        return (0..<64).map { _ in
            Ember(
                x: next(), y: next(),
                radius: 0.6 + next() * 1.9,
                drift: 0.008 + next() * 0.034,
                twinkle: 0.31 + next() * 1.07,
                phase: next() * .pi * 2,
                warmth: next())
        }
    }()

    /// A seeded random walk. It is decoration, but it is decoration shaped like the thing
    /// the app is about, and it is the same shape every time.
    private static let walk: [Double] = {
        var seed: UInt64 = 0x0DE5_C0DE_1234_5678
        var value = 0.5
        return (0..<64).map { _ in
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            value += (Double(seed % 1_000) / 1_000 - 0.48) * 0.085
            value = min(0.92, max(0.08, value))
            return value
        }
    }()

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate

            ZStack {
                LinearGradient(
                    colors: [
                        DeskColor.action.color.opacity(0.34),
                        DeskColor.ledger.color.opacity(0.30),
                        DeskColor.night.color,
                    ],
                    startPoint: .topTrailing,
                    endPoint: .bottomLeading)

                Canvas { context, size in
                    drawWalk(in: &context, size: size, time: time)
                    drawEmbers(in: &context, size: size, time: time)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func drawWalk(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        // Drifts sideways rather than redrawing, so the band breathes without the eye
        // being asked to read a number that is not real.
        let offset = reduceMotion ? 0 : (time * 0.004).truncatingRemainder(dividingBy: 1)
        let step = size.width / CGFloat(Self.walk.count - 1)
        var path = Path()
        for (index, value) in Self.walk.enumerated() {
            let x = CGFloat(index) * step - CGFloat(offset) * step
            let y = size.height * (0.34 + CGFloat(1 - value) * 0.5)
            index == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
        }
        var under = path
        under.addLine(to: CGPoint(x: size.width, y: size.height))
        under.addLine(to: CGPoint(x: 0, y: size.height))
        under.closeSubpath()

        context.fill(under, with: .linearGradient(
            Gradient(colors: [DeskColor.rise.color.opacity(0.16), .clear]),
            startPoint: CGPoint(x: 0, y: size.height * 0.3),
            endPoint: CGPoint(x: 0, y: size.height)))
        context.stroke(path, with: .color(DeskColor.rise.color.opacity(0.5)), lineWidth: 1.2)
    }

    private func drawEmbers(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        for ember in Self.embers {
            var y = ember.y - time * ember.drift
            y -= floor(y)
            let alpha = (sin(time * ember.twinkle + ember.phase) * 0.5 + 0.5) * 0.55 + 0.08
            guard alpha > 0.02 else { continue }

            let centre = CGPoint(x: ember.x * size.width, y: y * size.height)
            let colour = ember.warmth > 0.45 ? DeskColor.action.color : DeskColor.rise.color
            let halo = CGRect(
                x: centre.x - ember.radius * 3, y: centre.y - ember.radius * 3,
                width: ember.radius * 6, height: ember.radius * 6)
            context.fill(Path(ellipseIn: halo), with: .color(colour.opacity(alpha * 0.16)))
            let core = CGRect(
                x: centre.x - ember.radius, y: centre.y - ember.radius,
                width: ember.radius * 2, height: ember.radius * 2)
            context.fill(Path(ellipseIn: core), with: .color(colour.opacity(alpha)))
        }
    }
}
