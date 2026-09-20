import SwiftUI

public struct Sparkline: View {
    private let values: [Double]
    private let tint: DeskRGB

    public init(values: [Double], tint: DeskRGB = DeskColor.rise) {
        self.values = values
        self.tint = tint
    }

    public var hasEnoughPoints: Bool { values.count >= 2 }

    public var body: some View {
        GeometryReader { geometry in
            let points = positions(in: geometry.size)
            if points.count >= 2 {
                ZStack {
                    fill(points, in: geometry.size)
                        .fill(LinearGradient(
                            colors: [tint.color.opacity(0.22), .clear],
                            startPoint: .top, endPoint: .bottom))
                    line(points)
                        .stroke(tint.color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    if let last = points.last {
                        Circle()
                            .fill(tint.color)
                            .frame(width: 6, height: 6)
                            .shadow(color: tint.color.opacity(0.9), radius: 5)
                            .position(last)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func positions(in size: CGSize) -> [CGPoint] {
        guard values.count >= 2 else { return [] }
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        // A flat series would divide by zero and, drawn at the top of the box, would also
        // look like a rally. It sits on the midline instead.
        let span = high - low
        let step = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { index, value in
            let fraction = span == 0 ? 0.5 : (value - low) / span
            return CGPoint(x: CGFloat(index) * step, y: size.height * (1 - CGFloat(fraction)))
        }
    }

    private func line(_ points: [CGPoint]) -> Path {
        var path = Path()
        path.move(to: points[0])
        for point in points.dropFirst() { path.addLine(to: point) }
        return path
    }

    private func fill(_ points: [CGPoint], in size: CGSize) -> Path {
        var path = line(points)
        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: size.height))
        path.addLine(to: CGPoint(x: points[0].x, y: size.height))
        path.closeSubpath()
        return path
    }
}
