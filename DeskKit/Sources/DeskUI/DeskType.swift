import SwiftUI

public enum DeskType {
    /// The billboard figure: the amount being entered, the mark price.
    public static let display = Font.system(size: 56, weight: .heavy, design: .rounded).monospacedDigit()
    /// A secondary figure, still a value that can change.
    public static let figure = Font.system(size: 28, weight: .bold, design: .rounded).monospacedDigit()
    /// Rows of consequence inside a sheet.
    public static let value = Font.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit()

    public static let title = Font.system(size: 22, weight: .bold, design: .rounded)
    public static let body = Font.system(size: 17, weight: .regular, design: .rounded)
    public static let label = Font.system(size: 15, weight: .semibold, design: .rounded)
    /// Micro-labels, which stay muted and never take the accent.
    public static let caption = Font.system(size: 13, weight: .medium, design: .rounded)
}
