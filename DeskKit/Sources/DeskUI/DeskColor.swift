import SwiftUI

/// Amber is the only colour that means "you can act here"; green and red belong to direction.
/// Pine survives from Recourse for quiet surfaces only — on this ground it reads at 2.75:1.
public enum DeskColor {
    // MARK: Ground

    /// Near-black with a green cast, never neutral black.
    public static let night = DeskRGB(hex: 0x070907)
    /// One step up, and only ever on something tappable.
    public static let nightChip = DeskRGB(hex: 0x141A16)
    public static let nightLine = DeskRGB(hex: 0x212B23)
    public static let nightText = DeskRGB(hex: 0xEDF2ED)
    public static let nightMuted = DeskRGB(hex: 0x8C998F)

    // MARK: Action

    /// The brand, and the only colour that means "you can do something here".
    ///
    /// Amber rather than green for a reason the reference app makes plain: green already
    /// means profit. A green Confirm button and a green PnL figure read as the same
    /// statement, and on a trading screen that is a real ambiguity. So direction owns
    /// green and red, action owns amber. Amber appears on nothing but a trading action —
    /// identity has its own blue, so signing in and placing an order never wear one colour.
    public static let action = DeskRGB(hex: 0xE8B339)
    public static let onAction = DeskRGB(hex: 0x0B0D0B)

    /// Identity, and only identity. The Face ID button wears it; nothing else does.
    ///
    /// Apple's own system blue, because a biometric prompt is the platform's affordance
    /// rather than the app's, and borrowing the colour the OS uses for it is the shortest
    /// way to say "this is your phone asking, not us". It also keeps amber honest: amber
    /// means a trading action, and signing in is not one.
    ///
    /// White on this fails AA at 3.22:1, so `PrimaryButton` picks the near-black label —
    /// the same bright-fill, dark-label rule every other filled button in the app follows.
    public static let identity = DeskRGB(hex: 0x0A84FF)

    /// The deep pine carried over from Recourse. Kept for quiet brand surfaces only —
    /// never a label, never a figure, never a call to action.
    public static let ledger = DeskRGB(hex: 0x05634A)
    public static let onLedger = DeskRGB(hex: 0xEDF2ED)

    // MARK: Direction

    /// Long, and profit.
    public static let rise = DeskRGB(hex: 0x4CC38A)
    /// Short, and loss. Separated from `rise` by luminance and not only by hue, so the
    /// two stay distinguishable under a grayscale filter.
    public static let fall = DeskRGB(hex: 0xE5484D)
    public static let onFall = DeskRGB(hex: 0x0B0D0B)

    // MARK: Price impact

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
