import DeskUI
import SwiftUI

/// The question the rest of the app assumes you can already answer.
///
/// Offered from the welcome screen and never forced. That distinction is the whole design:
/// the research is blunt that a pre-roll tutorial makes tasks feel *harder* rather than
/// easier, so this is a link a curious person can pull rather than a wall everybody has to
/// climb. Someone who knows what a perpetual is never sees it.
///
/// Deliberately not the risk disclosure. `LeverageExplainer` is the one blocking sheet in
/// the app and it appears later, at the moment leverage is actually reached, with terms
/// that have to be ticked. This one explains and then gets out of the way — mixing the two
/// would turn an answer into a consent form.
struct PerpetualExplainer: View {
    let onClose: () -> Void

    private struct Point: Identifiable {
        let id = UUID()
        let symbol: String
        let title: String
        let body: String
    }

    private let points: [Point] = [
        Point(
            symbol: "infinity",
            title: "It never expires",
            body: "A normal futures contract has a settlement date. A perpetual does not — "
                + "you hold it until you close it, or until it closes you."),
        Point(
            symbol: "arrow.up.arrow.down",
            title: "You can bet either way",
            body: "Long profits when the price rises. Short profits when it falls. "
                + "You are not buying Bitcoin; you are taking a position on its price."),
        Point(
            symbol: "dial.medium",
            title: "Leverage multiplies both directions",
            body: "$100 at 10× moves like $1,000 — up and down. It is the reason perpetuals "
                + "are interesting and the reason they are dangerous."),
        Point(
            symbol: "exclamationmark.triangle.fill",
            title: "Liquidation ends it for you",
            body: "If the price moves far enough against you, the position is closed "
                + "automatically and the collateral behind it is gone. No warning, no call."),
        Point(
            symbol: "clock.arrow.2.circlepath",
            title: "Funding is the rent",
            body: "Every 43 minutes, one side pays the other a small fee to keep the "
                + "perpetual's price near the real one. Holding a position is not free."),
    ]

    var body: some View {
        ZStack {
            DeskBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("What is a\nperpetual?")
                        .font(.system(size: 38, weight: .heavy, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                        .padding(.top, 12)

                    Text("A way to bet on a price going up or down, with no expiry date.")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 14)

                    VStack(spacing: 12) {
                        ForEach(points) { point in
                            row(point)
                        }
                    }
                    .padding(.top, 28)

                    // The honest footer. Someone reading an explainer because they did not
                    // know the word is exactly the person who should be told this plainly,
                    // and burying it would be the trick this app is supposed to not play.
                    Text("Most people who trade perpetuals with leverage lose money. "
                         + "Desk runs on testnet, so nothing here is real — but the "
                         + "arithmetic is the same one that applies to real funds.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 26)

                    PrimaryButton(title: "Got it", tint: DeskColor.identity) { onClose() }
                        .padding(.top, 26)
                        .padding(.bottom, 32)
                }
                .padding(.horizontal, 24)
            }
        }
    }

    private func row(_ point: Point) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: point.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(DeskColor.action.color)
                .frame(width: 34, height: 34)
                .background(DeskColor.action.color.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 5) {
                Text(point.title)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
                Text(point.body)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(15)
        .background(DeskColor.nightChip.color.opacity(0.55),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(DeskColor.nightLine.color, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}
