import Foundation
import Testing

@testable import DeskUI

@Suite("The palette")
struct PaletteTests {
    private let ground = DeskColor.night

    @Test("Body text clears AAA on the ground and muted text clears AA")
    func textContrast() {
        #expect(DeskColor.nightText.contrastRatio(against: ground) >= 7.0)
        #expect(DeskColor.nightMuted.contrastRatio(against: ground) >= 4.5)
    }

    @Test("Every figure colour clears 4.5 on the ground")
    func figureContrast() {
        for colour in [DeskColor.rise, DeskColor.fall, DeskColor.impactAmber, DeskColor.impactOrange] {
            #expect(colour.contrastRatio(against: ground) >= 4.5)
        }
        #expect(DeskColor.ledger.contrastRatio(against: ground) < 3.0)
    }

    @Test("Identity blue is legible and is nobody else's colour")
    func identityIsItsOwnColour() {
        let ground = DeskColor.night
        let label = PaletteTests.betterLabel(on: DeskColor.identity)
        #expect(label.contrastRatio(against: DeskColor.identity) >= 4.5)
        #expect(DeskColor.identity != DeskColor.action)
        #expect(DeskColor.identity != DeskColor.rise)
        #expect(DeskColor.identity != DeskColor.fall)
        #expect(DeskColor.identity.contrastRatio(against: ground) >= 3.0)
    }

    /// Mirrors `PrimaryButton.label(on:)`, which lives in the app target and cannot be
    /// imported here. If the two ever disagree, this test is the one that is wrong.
    static func betterLabel(on tint: DeskRGB) -> DeskRGB {
        tint.contrastRatio(against: DeskColor.onFall) >= tint.contrastRatio(against: DeskColor.nightText)
            ? DeskColor.onFall : DeskColor.nightText
    }

    @Test("A label on a filled button clears AA against its fill")
    func buttonContrast() {
        #expect(DeskColor.onAction.contrastRatio(against: DeskColor.action) >= 4.5)
        #expect(DeskColor.onLedger.contrastRatio(against: DeskColor.ledger) >= 4.5)
        #expect(DeskColor.onFall.contrastRatio(against: DeskColor.fall) >= 4.5)
    }

    @Test("Action is not a direction, and direction is not an action")
    func actionIsItsOwnColour() {
        #expect(DeskColor.action != DeskColor.rise)
        #expect(DeskColor.action != DeskColor.fall)
        #expect(DeskColor.action.contrastRatio(against: ground) >= 4.5)
    }

    @Test("Up and down are separated by luminance, not only hue")
    func grayscaleSeparation() {
        let separation = DeskColor.rise.contrastRatio(against: DeskColor.fall)
        #expect(separation >= 1.5)
        #expect(DeskColor.rise.relativeLuminance > DeskColor.fall.relativeLuminance)
    }

    @Test("Chips sit above the ground without becoming containers")
    func chipIsSubtle() {
        let lift = DeskColor.nightChip.contrastRatio(against: ground)
        #expect(lift > 1.0)
        #expect(lift < 1.5)
    }

    @Test("The impact ladder follows Uniswap's thresholds")
    func impactLadder() {
        #expect(DeskColor.impact(basisPoints: 0) == DeskColor.impactNeutral)
        #expect(DeskColor.impact(basisPoints: 99) == DeskColor.impactNeutral)
        #expect(DeskColor.impact(basisPoints: 100) == DeskColor.impactAmber)
        #expect(DeskColor.impact(basisPoints: 299) == DeskColor.impactAmber)
        #expect(DeskColor.impact(basisPoints: 300) == DeskColor.impactOrange)
        #expect(DeskColor.impact(basisPoints: 499) == DeskColor.impactOrange)
        #expect(DeskColor.impact(basisPoints: 500) == DeskColor.impactRed)
        // Perpl's own testnet BTC cap, which should read as the warning it is.
        #expect(DeskColor.impact(basisPoints: 1_000) == DeskColor.impactRed)
    }

    @Test("Hex parsing is the components it claims")
    func hexParsing() {
        let white = DeskRGB(hex: 0xFFFFFF)
        #expect(white.red == 1 && white.green == 1 && white.blue == 1)
        #expect(DeskRGB(hex: 0x000000).relativeLuminance == 0)
        #expect(abs(white.relativeLuminance - 1) < 0.0001)
        #expect(white.contrastRatio(against: DeskRGB(hex: 0x000000)) == 21)
    }
}

@Suite("Direction without colour")
struct DirectionTests {
    @Test("The sign is a real minus, not a hyphen")
    func trueMinus() {
        #expect(Direction.minus == "\u{2212}")
        #expect(Direction.signed("-12.50") == "\u{2212}12.50")
        #expect(Direction.signed("12.50") == "12.50")
        #expect(!Direction.signed("-1").contains("-"))
    }

    @Test("Direction carries a shape and a word before it carries a colour")
    func encodingLadder() {
        #expect(Direction.up.symbolName == "arrow.up")
        #expect(Direction.down.symbolName == "arrow.down")
        #expect(Direction.up.word() == "Long")
        #expect(Direction.down.word() == "Short")
        #expect(Direction.up.word(long: "Profit", short: "Loss") == "Profit")
    }

    @Test("A sign maps to a direction, with zero reading as up")
    func fromSign() {
        #expect(Direction(signOf: 1) == .up)
        #expect(Direction(signOf: 0) == .up)
        #expect(Direction(signOf: -1) == .down)
    }
}
