import SwiftUI

/// A figure with its fraction de-emphasised.
///
/// `77,057` carries the meaning and `.6` carries the precision, so they are not given
/// the same weight. Lifted from the reference app, where the portfolio total renders as a
/// bold `$39,842` with a smaller grey `.28`. It reads as one number and scans as one
/// glance, and it stops a long decimal tail from competing with the figure itself.
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
                .font(.system(size: size, weight: .bold).monospacedDigit())
                .foregroundStyle(colour.color)
            if let fraction {
                Text(fraction)
                    .font(.system(size: size * 0.62, weight: .bold).monospacedDigit())
                    .foregroundStyle(colour.color.opacity(0.55))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(whole + (fraction ?? ""))
    }
}

/// What a value looks like when there is nothing to show.
///
/// Two dashes, never a zero and never a blank. The reference app renders `24H --`,
/// `MC --`, `LIQ --` on a token it has no data for, and its own documentation is blunt
/// about why: unavailable is displayed as unavailable rather than converted into a
/// fabricated result. A zero is a claim; `--` is the truth.
public enum Unavailable {
    public static let text = "--"
}
