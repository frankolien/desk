import SwiftUI

/// Amber is the only colour that means "you can act here"; green and red belong to direction.
/// Pine survives from Recourse for quiet surfaces only — on this ground it reads at 2.75:1.
public enum DeskColor {

    public static let night = DeskRGB(hex: 0x070907)
    public static let nightChip = DeskRGB(hex: 0x141A16)
    public static let nightLine = DeskRGB(hex: 0x212B23)
    public static let nightText = DeskRGB(hex: 0xEDF2ED)
    public static let nightMuted = DeskRGB(hex: 0x8C998F)

    public static let action = DeskRGB(hex: 0xE8B339)
    public static let onAction = DeskRGB(hex: 0x0B0D0B)

    /// Identity only: the Face ID button. White on it fails AA at 3.22:1, so `PrimaryButton`
    /// uses the near-black label.
    public static let identity = DeskRGB(hex: 0x0A84FF)

    public static let ledger = DeskRGB(hex: 0x05634A)
    public static let onLedger = DeskRGB(hex: 0xEDF2ED)

    public static let rise = DeskRGB(hex: 0x4CC38A)
    public static let fall = DeskRGB(hex: 0xE5484D)
    public static let onFall = DeskRGB(hex: 0x0B0D0B)

    /// Uniswap's published thresholds, so the boundaries have a reason behind them
    /// rather than a taste: neutral to 1%, amber 1 to 3%, orange 3 to 5%, red above.
    public static let impactNeutral = nightMuted
    public static let impactAmber = action
    public static let impactOrange = DeskRGB(hex: 0xF08C3C)
    public static let impactRed = fall

    public static func impact(basisPoints: Int) -> DeskRGB {
        switch basisPoints {
        case ..<100: impactNeutral
        case ..<300: impactAmber
        case ..<500: impactOrange
        default: impactRed
        }
    }
}
