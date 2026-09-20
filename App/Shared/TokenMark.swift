import DeskUI
import SwiftUI
import UIKit

/// Bundled, never fetched — a widget cannot load an image over the network.
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
