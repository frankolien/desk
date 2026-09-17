import DeskUI
import SwiftUI

extension AutoCopyGlance.Move {
    var headline: String {
        switch kind {
        case .opened: "\(sideWord) \(symbol)\(leverage.map { " \($0)×" } ?? "")"
        case .closed: "Closed \(symbol)"
        }
    }
}

struct PnLText: View {
    let value: Double

    var body: some View {
        Text(AutoCopyGlance.money(value))
            .foregroundStyle(value < 0 ? DeskColor.fall.color : (value > 0 ? DeskColor.rise.color : DeskColor.nightText.color))
            .monospacedDigit()
            .contentTransition(.numericText(value: value))
    }
}

struct DeskMark: View {
    var size: CGFloat = 20

    var body: some View {
        Image("DeskMark")
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }
}

/// The status sentence under the title, shared by every surface so they never disagree.
func autoCopyStatus(paused: Bool, traders: Int, openCopies: Int, shadow: Bool) -> String {
    if paused { return "Paused" }
    let who = traders == 1 ? "1 trader" : "\(traders) traders"
    return "\(shadow ? "Shadow · " : "")\(who) · \(openCopies) open"
}

/// "now", "12m", "3h", "2d": a widget row has no room for "2 min, 5 sec".
func shortAge(_ date: Date, now: Date = .now) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    switch seconds {
    case ..<60: return "now"
    case ..<3_600: return "\(Int(seconds / 60))m"
    case ..<86_400: return "\(Int(seconds / 3_600))h"
    default: return "\(Int(seconds / 86_400))d"
    }
}

struct MoveRow: View {
    let move: AutoCopyGlance.Move

    var body: some View {
        HStack(spacing: 8) {
            Capsule()
                .fill((move.isLong ? DeskColor.rise : DeskColor.fall).color)
                .frame(width: 3, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(move.headline)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
                Text(move.trader)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
            .lineLimit(1)
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                if let pnl = move.pnl {
                    PnLText(value: pnl).font(.system(size: 13, weight: .semibold, design: .rounded))
                }
                Text(shortAge(move.date))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .monospacedDigit()
            }
            .fixedSize(horizontal: true, vertical: false)
            .lineLimit(1)
        }
    }
}
