import SwiftUI

public enum DeskType {
    public static let display = Font.system(size: 56, weight: .heavy, design: .rounded).monospacedDigit()
    public static let figure = Font.system(size: 28, weight: .bold, design: .rounded).monospacedDigit()
    public static let value = Font.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit()

    public static let title = Font.system(size: 22, weight: .bold, design: .rounded)
    public static let body = Font.system(size: 17, weight: .regular, design: .rounded)
    public static let label = Font.system(size: 15, weight: .semibold, design: .rounded)
    public static let caption = Font.system(size: 13, weight: .medium, design: .rounded)
}
