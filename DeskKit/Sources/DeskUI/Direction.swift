import SwiftUI

/// Long or short, up or down — encoded so it survives a grayscale filter.
///
/// The screen designs set an encoding ladder, strongest first, and this carries all of
/// it: an explicit sign using U+2212 MINUS rather than a hyphen, an SF Symbol that scales
/// with Dynamic Type, the word itself, and only then a colour. Colour is the last rung,
/// never the only one.
public enum Direction: String, Sendable, Hashable, CaseIterable {
    case up
    case down

    public init(signOf value: Int64) { self = value < 0 ? .down : .up }

    /// U+2212, not a hyphen-minus. A hyphen is narrower than a digit and makes a column
    /// of figures ripple; the true minus is digit-width in the system font.
    public static let minus = "\u{2212}"

    public var symbolName: String { self == .up ? "arrow.up" : "arrow.down" }

    public var color: DeskRGB { self == .up ? DeskColor.rise : DeskColor.fall }

    public func word(long: String = "Long", short: String = "Short") -> String {
        self == .up ? long : short
    }

    /// Renders a value with a real minus sign and no hyphen anywhere.
    public static func signed(_ text: String) -> String {
        text.hasPrefix("-") ? minus + text.dropFirst() : text
    }
}
