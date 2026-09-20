import SwiftUI

public struct AddressAvatar: View {
    private let address: String
    private let size: CGFloat

    public init(address: String, size: CGFloat = 26) {
        self.address = address
        self.size = size
    }

    /// Two hues and a tilt, derived from the address.
    ///
    /// Separated from the view so it can be tested: the same address must always produce
    /// the same mark, and two addresses that differ anywhere must not collapse onto one.
    /// FNV-1a rather than `hashValue`, because Swift's hashing is seeded per process and
    /// would give the same account a different face on every launch.
    public static func seed(for address: String) -> (primary: Double, secondary: Double, tilt: Double) {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in address.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        let primary = Double(hash % 360)
        let secondary = (primary + 40 + Double((hash >> 16) % 120)).truncatingRemainder(dividingBy: 360)
        let tilt = Double((hash >> 32) % 360)
        return (primary, secondary, tilt)
    }

    public var body: some View {
        let seed = Self.seed(for: address)
        Circle()
            .fill(
                AngularGradient(
                    colors: [
                        Color(hue: seed.primary / 360, saturation: 0.62, brightness: 0.92),
                        Color(hue: seed.secondary / 360, saturation: 0.70, brightness: 0.78),
                        Color(hue: seed.primary / 360, saturation: 0.62, brightness: 0.92),
                    ],
                    center: .center,
                    angle: .degrees(seed.tilt)))
            .overlay(
                // One highlight, lit from the same top-leading direction as every other
                // surface in the app, so the mark sits in the room rather than on it.
                Ellipse()
                    .fill(Color.white.opacity(0.34))
                    .frame(width: size * 0.52, height: size * 0.3)
                    .offset(x: -size * 0.12, y: -size * 0.24)
                    .blur(radius: size * 0.1)
                    .blendMode(.plusLighter))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
