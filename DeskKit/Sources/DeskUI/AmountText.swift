import SwiftUI

public struct AmountText: View {
    private let whole: String
    private let fraction: String?
    private let size: CGFloat
    private let colour: DeskRGB

    public init(_ text: String, size: CGFloat = 56, colour: DeskRGB = DeskColor.nightText) {
        if let point = text.firstIndex(of: ".") {
            whole = String(text[text.startIndex..<point])
            fraction = String(text[point...])
        } else {
            whole = text
            fraction = nil
        }
        self.size = size
        self.colour = colour
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(whole)
                .font(.system(size: size, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundStyle(colour.color)
            if let fraction {
                Text(fraction)
                    .font(.system(size: size * 0.62, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(colour.color.opacity(0.55))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(whole + (fraction ?? ""))
    }
}

/// Two dashes, never a zero: a zero is a claim, `--` is the truth.
public enum Unavailable {
    public static let text = "--"
}
