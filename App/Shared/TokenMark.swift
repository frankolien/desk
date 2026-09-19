import DeskUI
import SwiftUI
import UIKit

/// A market's logo from the bundle, or a monogram when the bundle has none.
///
/// Bundled rather than fetched: a widget cannot load an image over the network, and the
/// app drawing a logo from a CDN that the Home Screen then draws as a grey hexagon is
/// two versions of one instrument. Perpl lists eight markets; all eight are in both
/// asset catalogs. The monogram is for a ninth the venue lists after this ships.
struct TokenMark: View {
    let symbol: String
    var size: CGFloat = 28

    var body: some View {
        let name = symbol.uppercased()
        Group {
            if UIImage(named: name) != nil {
                Image(name)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                ZStack {
                    Circle().fill(DeskColor.nightChip.color)
                    Text(String(name.prefix(1)))
                        .font(.system(size: size * 0.42, weight: .heavy, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}
