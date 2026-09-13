import Foundation
import Testing

@testable import DeskUI

@Suite("The sparkline")
struct SparklineTests {
    @Test("One point is not a line")
    func needsTwoPoints() {
        // A line invented to fill a space is a claim about a market.
        #expect(Sparkline(values: []).hasEnoughPoints == false)
        #expect(Sparkline(values: [77_133]).hasEnoughPoints == false)
        #expect(Sparkline(values: [77_133, 77_140]).hasEnoughPoints)
    }
}
