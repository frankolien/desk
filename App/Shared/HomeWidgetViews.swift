import DeskUI
import SwiftUI
import WidgetKit

/// The account on the Home Screen: collateral, then the open positions under it.
///
/// Shared with the app rather than kept in the extension so the app can draw the same
/// view in a debug gallery — a widget cannot be launched from the command line, and a
/// layout nobody has seen rendered is a layout with a wrapped label in it somewhere.
struct PortfolioWidgetView: View {
    let glance: PortfolioGlance?
    let family: WidgetFamily

    var body: some View {
        if let glance {
            switch family {
            case .systemSmall: small(glance)
            default: list(glance, limit: family == .systemLarge ? 6 : 2)
            }
        } else {
            WidgetNote(
                title: "Sign in to Desk",
                detail: "Your collateral and open positions show up here.")
        }
    }

    private func small(_ glance: PortfolioGlance) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(glance.network)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DeskColor.nightMuted.color)
            Spacer(minLength: 4)
            Text(glance.collateralText)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(DeskColor.nightText.color)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .privacySensitive()
            Text("Collateral")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DeskColor.nightMuted.color)
            Spacer(minLength: 4)
            Text(positionsLine(glance))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DeskColor.nightMuted.color)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func list(_ glance: PortfolioGlance, limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(glance)
            Rectangle()
                .fill(DeskColor.nightLine.color)
                .frame(height: 1)
                .padding(.vertical, 10)
            if glance.positions.isEmpty {
                Spacer(minLength: 0)
                Text("No open positions")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            } else {
                VStack(spacing: 10) {
                    ForEach(glance.positions.prefix(limit)) { PositionRow(position: $0) }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func header(_ glance: PortfolioGlance) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(glance.addressShort)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(DeskColor.nightText.color)
                    .privacySensitive()
                Text(glance.network)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(glance.collateralText)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(DeskColor.nightText.color)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .privacySensitive()
                Text("COLLATERAL")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
        }
    }

    private func positionsLine(_ glance: PortfolioGlance) -> String {
        switch glance.positions.count {
        case 0: "No open positions"
        case 1: "1 open position"
        default: "\(glance.positions.count) open positions"
        }
    }
}

private struct PositionRow: View {
    let position: PortfolioGlance.Position

    var body: some View {
        HStack(spacing: 10) {
            TokenMark(symbol: position.symbol, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(position.symbol)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
                HStack(spacing: 6) {
                    Text("\(position.isLong ? "Long" : "Short") \(position.leverage)×")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DeskColor.nightMuted.color)
                    ChangeChip(text: Percent.micros(position.returnOnMarginMicros),
                               isUp: position.returnOnMarginMicros >= 0)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 3) {
                Text(position.pnlText)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle((position.pnl < 0 ? DeskColor.fall : DeskColor.rise).color)
                    .privacySensitive()
                Text("unrealised")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
        }
        .lineLimit(1)
    }
}

/// The saved markets with their last marks, in the order the Watchlist tab lists them.
struct WatchlistWidgetView: View {
    let glance: WatchlistGlance?
    let family: WidgetFamily

    var body: some View {
        if let glance, !glance.rows.isEmpty {
            let limit = family == .systemLarge ? 7 : 3
            VStack(spacing: 0) {
                ForEach(Array(glance.rows.prefix(limit).enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        Rectangle().fill(DeskColor.nightLine.color).frame(height: 1)
                    }
                    WatchRow(row: row)
                        .frame(maxHeight: .infinity)
                }
            }
        } else {
            WidgetNote(
                title: "Nothing saved yet",
                detail: "Save a market on Watchlist and it shows up here.")
        }
    }
}

private struct WatchRow: View {
    let row: WatchlistGlance.Row

    var body: some View {
        HStack(spacing: 10) {
            TokenMark(symbol: row.symbol, size: 28)
            Text(row.symbol)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(DeskColor.nightText.color)
            Spacer(minLength: 6)
            Text(row.priceText)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(DeskColor.nightText.color)
                .minimumScaleFactor(0.75)
            if let change = row.changePercent {
                ChangeChip(text: Percent.change(change), isUp: change >= 0)
                    .frame(width: 66, alignment: .trailing)
            }
        }
        .lineLimit(1)
    }
}

/// A percentage in a tinted capsule. Green and red on a dark ground at full strength
/// shout; at eighteen percent behind a coloured label they read.
struct ChangeChip: View {
    let text: String
    let isUp: Bool

    var body: some View {
        let tint = (isUp ? DeskColor.rise : DeskColor.fall).color
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.18), in: Capsule())
    }
}

struct WidgetNote: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Spacer(minLength: 0)
            Text(title)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(DeskColor.nightText.color)
            Text(detail)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DeskColor.nightMuted.color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
