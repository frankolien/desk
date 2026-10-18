import DeskUI
import SwiftUI

/// One trader you copy: are we copying them right now, how it has gone, and a plain list of
/// what they did and what Desk did about it. The answer to "is Auto-Copy doing anything?"
struct CopyBoardScreen: View {
    let address: String
    let model: AppModel
    let copier: CopyTrader
    let directory: TraderDirectory

    @State private var editing = false
    @State private var spot = SpotCopier.shared

    /// One move of theirs and what came of it here.
    struct Move: Identifiable {
        enum Outcome { case copied, skipped, failed, protected }
        let id: String
        let date: Date
        let theirs: String
        let outcome: Outcome
        let yours: String
        let pnl: Double?
    }

    private var copied: CopiedTrader? { copier.traders.first { $0.address.lowercased() == address.lowercased() } }
    /// Copied for their token trades, by Desk's server (spot Auto-Copy).
    private var spotLeader: SpotCopier.Leader? { spot.leaders[address.lowercased()] }
    private var name: String { directory.name(for: address) }

    private var moves: [Move] {
        let key = address.lowercased()
        var out: [Move] = []
        for entry in copier.shownLog where entry.trader.lowercased() == key {
            let side = entry.isLong ? "long" : "short"
            let shadow = entry.shadowed ? " · practice" : ""
            switch entry.kind {
            case .opened:
                let size = [entry.margin.map { "$\(Self.money($0))" }, entry.leverage.map { "\($0)×" }].compactMap { $0 }.joined(separator: " at ")
                out.append(Move(id: entry.id.uuidString, date: entry.date, theirs: "Opened \(side) \(entry.symbol)", outcome: .copied,
                                yours: "You opened \(size.isEmpty ? "the same" : size)\(shadow)", pnl: nil))
            case .closed:
                out.append(Move(id: entry.id.uuidString, date: entry.date, theirs: "Closed \(side) \(entry.symbol)", outcome: .copied,
                                yours: "You closed too\(shadow)", pnl: entry.pnl))
            case .protected:
                out.append(Move(id: entry.id.uuidString, date: entry.date, theirs: "Still in \(entry.symbol)", outcome: .protected,
                                yours: entry.detail.isEmpty ? "Your stop loss closed it" : entry.detail, pnl: entry.pnl))
            case .skipped:
                out.append(Move(id: entry.id.uuidString, date: entry.date, theirs: "Opened \(side) \(entry.symbol)", outcome: .skipped,
                                yours: "Skipped · \(entry.detail)", pnl: nil))
            case .failed:
                out.append(Move(id: entry.id.uuidString, date: entry.date, theirs: "Traded \(entry.symbol)", outcome: .failed,
                                yours: "Didn't go through · \(entry.detail)", pnl: nil))
            default: continue
            }
        }
        for row in spot.log where row.leader?.lowercased() == key {
            guard let side = row.side, side == "buy" || side == "sell", let symbol = row.symbol else { continue }
            let outcome: Move.Outcome = row.status == "copied" ? .copied : row.status == "failed" ? .failed : .skipped
            let amount = String(format: "$%.2f", row.ausd ?? 0)
            let yours = row.status == "copied"
                ? (side == "buy" ? "You bought \(amount) of it" : "You sold yours for \(amount)")
                : "\(row.status == "failed" ? "Didn't go through" : "Skipped") · \(row.detail ?? "")"
            out.append(Move(id: "spot-\(row.id)", date: row.date, theirs: "\(side == "buy" ? "Bought" : "Sold") \(symbol)",
                            outcome: outcome, yours: yours, pnl: nil))
        }
        return out.sorted { $0.date > $1.date }
    }

    var body: some View {
        let moves = moves
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                header
                summary(moves)
                activity(moves)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 60)
        }
        .background(DeskBackground())
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Settings") { editing = true }
            }
        }
        .sheet(isPresented: $editing) {
            if copied == nil && spotLeader != nil {
                SpotCopySheet(model: model, leader: address, name: name)
            } else {
                AutoCopySheet(address: address, name: name, copier: copier)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 10) {
            TraderAvatar(address: address, size: 72)
            Text(name)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(DeskColor.nightText.color)
            HStack(spacing: 7) {
                Circle().fill(isLive ? DeskColor.rise.color : DeskColor.action.color).frame(width: 8, height: 8)
                Text(statusLine)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
            }
            if let rules = rulesLine {
                Text(rules)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }

    private var isLive: Bool {
        if copied == nil { return spotLeader != nil && spot.stage == "live" && !spot.isPaused }
        return !copier.isPaused
    }

    private var statusLine: String {
        if copied == nil {
            guard spotLeader != nil else { return "Not copying" }
            return spot.isPaused ? "Paused" : isLive ? "Copying" : "Turning on…"
        }
        return copier.isPaused ? "Paused" : "Copying"
    }

    private var rulesLine: String? {
        if let rules = copied?.rules {
            return "$\(rules.marginPerTrade) per trade · up to \(rules.maxLeverage)×\(rules.mode == .shadow ? " · practice mode" : "")"
        }
        if let rules = spotLeader?.rules {
            return rules.sizing == .fixed ? "$\(Int(rules.amount)) per buy" : "Their size, up to $\(Int(rules.maxPerBuy))"
        }
        return nil
    }

    // MARK: Summary

    private func summary(_ moves: [Move]) -> some View {
        let copiedCount = moves.filter { $0.outcome == .copied || $0.outcome == .protected }.count
        let pnl = moves.compactMap(\.pnl).reduce(0, +)
        return HStack(spacing: 12) {
            stat("\(copiedCount)", moves.isEmpty ? "trades copied" : "of \(moves.count) trades copied")
            stat(pnl == 0 ? "$0" : DisplayCurrency.shared.format(pnl, signed: true), "your profit",
                 tint: pnl > 0 ? DeskColor.rise : pnl < 0 ? DeskColor.fall : DeskColor.nightText)
        }
    }

    private func stat(_ value: String, _ label: String, tint: DeskRGB = DeskColor.nightText) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(tint.color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(DeskColor.nightMuted.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: Activity

    private func activity(_ moves: [Move]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Activity")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(DeskColor.nightText.color)
                .padding(.bottom, 6)
            if moves.isEmpty {
                Text(isLive ? "Nothing yet. When they trade, it shows up here." : "Nothing yet.")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 32)
            }
            ForEach(Array(moves.enumerated()), id: \.element.id) { index, move in
                if index == 0 || !Calendar.current.isDate(move.date, inSameDayAs: moves[index - 1].date) {
                    Text(dayLabel(move.date))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .padding(.top, index == 0 ? 6 : 16)
                        .padding(.bottom, 4)
                }
                MoveRow(move: move)
            }
        }
    }

    private func dayLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).day().month())
    }

    static func money(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.2f", value)
    }
}

/// What they did, what Desk did, when.
private struct MoveRow: View {
    let move: CopyBoardScreen.Move

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(tint.color)
                .frame(width: 30, height: 30)
                .background(tint.color.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(move.theirs)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
                    .lineLimit(1)
                Text(move.yours)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(move.outcome == .failed ? DeskColor.fall.color : DeskColor.nightMuted.color)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                if let pnl = move.pnl {
                    Text(DisplayCurrency.shared.format(pnl, signed: true))
                        .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(pnl >= 0 ? DeskColor.rise.color : DeskColor.fall.color)
                }
                Text(move.date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5) }
    }

    private var icon: String {
        switch move.outcome {
        case .copied: "checkmark"
        case .protected: "shield.fill"
        case .skipped: "minus"
        case .failed: "exclamationmark"
        }
    }

    private var tint: DeskRGB {
        switch move.outcome {
        case .copied: DeskColor.rise
        case .protected: DeskColor.action
        case .skipped: DeskColor.nightMuted
        case .failed: DeskColor.fall
        }
    }
}
