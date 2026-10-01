import SwiftUI

public struct AddressAvatar: View {
    private let address: String
    private let size: CGFloat

    public init(address: String, size: CGFloat = 26) {
        self.address = address
        self.size = size
    }

    /// FNV-1a rather than `hashValue`: Swift's hashing is seeded per process, so a face would change every launch.
    public static func seed(for address: String) -> (primary: Double, secondary: Double, tilt: Double) {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let canonical = address.hasPrefix("0x") ? address.lowercased() : address
        for byte in canonical.utf8 {
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
