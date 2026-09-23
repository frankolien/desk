import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// The wallet address as a code another wallet can scan, drawn once per address.
struct AddressQR: View {
    let address: String
    var size: CGFloat = 168

    private var image: UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(address.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = size * UIScreen.main.scale / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // White on black inverted to dark on light: scanners want a light quiet zone.
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: size, height: size)
                    .padding(10)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .accessibilityLabel("Wallet address code")
    }
}
