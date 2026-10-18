import Charts
import DeskUI
import SwiftUI

/// One trader you copy, laid out the way exchanges lay out a copy: your profit from them and
/// its line over time, the copies open right now, the history of every move, and Adjust /
/// Stop at the bottom.
struct CopyBoardScreen: View {
    let address: String
    let model: AppModel
    let copier: CopyTrader
    let directory: TraderDirectory

    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var confirmsStop = false
    @State private var range: Range = .week
    @State private var tab: Tab = .positions
    @State private var selected: PortfolioChartPoint?
    @State private var spot = SpotCopier.shared

    enum Range: String, CaseIterable { case week = "7D", month = "30D", all = "All" }
    enum Tab: String, CaseIterable { case positions = "Positions", history = "History" }

    /// One move of theirs and what came of it here.
    struct Move: Identifiable {
        enum Outcome { case copied, skipped, failed, protected }
        let id: String
        let date: Date
        let symbol: String
        let title: String
        let detail: String
        let outcome: Outcome
        let pnl: Double?
    }

    private var copied: CopiedTrader? { copier.traders.first { $0.address.lowercased() == address.lowercased() } }
    /// Copied for their token trades, by Desk's server (spot Auto-Copy).
    private var spotLeader: SpotCopier.Leader? { spot.leaders[address.lowercased()] }
    private var isSpot: Bool { copied == nil && spotLeader != nil }
    private var name: String { directory.name(for: address) }
    private var since: Date? { copied?.since ?? spotLeader?.since.map { Date(timeIntervalSince1970: $0 / 1000) } }

    private var isLive: Bool {
        if isSpot { return spot.stage == "live" && !spot.isPaused }
        return copied != nil && !copier.isPaused
    }

    private var open: [OpenCopy] { copier.shownOpen.filter { $0.trader.lowercased() == address.lowercased() } }

    private var moves: [Move] {
        let key = address.lowercased()
        var out: [Move] = []
        for entry in copier.shownLog where entry.trader.lowercased() == key {
            let side = entry.isLong ? "long" : "short"
            let practice = entry.shadowed ? " · practice" : ""
            switch entry.kind {
            case .opened:
                let size = [entry.margin.map { "$\(Self.money($0))" }, entry.leverage.map { "\($0)×" }].compactMap { $0 }.joined(separator: " at ")
                out.append(Move(id: entry.id.uuidString, date: entry.date, symbol: entry.symbol, title: "Opened \(side) \(entry.symbol)",
                                detail: "Copied\(size.isEmpty ? "" : " · \(size)")\(practice)", outcome: .copied, pnl: nil))
            case .closed:
                out.append(Move(id: entry.id.uuidString, date: entry.date, symbol: entry.symbol, title: "Closed \(side) \(entry.symbol)",
                                detail: "Closed with them\(practice)", outcome: .copied, pnl: entry.pnl))
            case .protected:
                out.append(Move(id: entry.id.uuidString, date: entry.date, symbol: entry.symbol, title: "Stop loss · \(entry.symbol)",
                                detail: entry.detail.isEmpty ? "Your stop closed it before they did" : entry.detail, outcome: .protected, pnl: entry.pnl))
            case .skipped:
                out.append(Move(id: entry.id.uuidString, date: entry.date, symbol: entry.symbol, title: "Opened \(side) \(entry.symbol)",
                                detail: entry.detail, outcome: .skipped, pnl: nil))
            case .failed:
                out.append(Move(id: entry.id.uuidString, date: entry.date, symbol: entry.symbol, title: "Traded \(entry.symbol)",
                                detail: entry.detail, outcome: .failed, pnl: nil))
            default: continue
            }
        }
        for row in spot.log where row.leader?.lowercased() == key {
            guard let side = row.side, side == "buy" || side == "sell", let symbol = row.symbol else { continue }
            let outcome: Move.Outcome = row.status == "copied" ? .copied : row.status == "failed" ? .failed : .skipped
            let amount = String(format: "$%.2f", row.ausd ?? 0)
            let detail = row.status == "copied"
                ? (side == "buy" ? "Copied · \(amount)" : "Sold with them · \(amount)")
                : (row.detail ?? "Not copied")
            out.append(Move(id: "spot-\(row.id)", date: row.date, symbol: symbol, title: "\(side == "buy" ? "Bought" : "Sold") \(symbol)",
                            detail: detail, outcome: outcome, pnl: nil))
        }
        return out.sorted { $0.date > $1.date }
    }

    // MARK: Profit

    private var unrealized: Double { open.compactMap { $0.shadowPnL(takerFeeMicros: copier.takerFee(for: $0.symbol)) }.reduce(0, +) }

    private var rangeStart: Date {
        switch range {
        case .week: .now.addingTimeInterval(-7 * 86_400)
        case .month: .now.addingTimeInterval(-30 * 86_400)
        case .all: .distantPast
        }
    }

    /// Cumulative profit from this trader: realised closes in order, then open copies' mark.
    private var profitPoints: [PortfolioChartPoint] {
        let realised = moves.compactMap { move in move.pnl.map { (move.date, $0) } }.sorted { $0.0 < $1.0 }
        var running = 0.0
        var all: [(Date, Double)] = []
        for (date, pnl) in realised { running += pnl; all.append((date, running)) }
        let start = max(rangeStart, since ?? realised.first?.0 ?? .now.addingTimeInterval(-3600))
        let before = all.last { $0.0 < start }?.1 ?? 0
        var shown = [(start, before)] + all.filter { $0.0 >= start }
        shown.append((.now, running + unrealized))
        return shown.enumerated().map { PortfolioChartPoint(id: $0.offset, date: $0.element.0, value: $0.element.1) }
    }

    private var profit: Double { (profitPoints.last?.value ?? 0) - (profitPoints.first?.value ?? 0) }

    // MARK: Body

    var body: some View {
        let moves = moves
        let points = profitPoints
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                header
                if isSpot { spotSummary(moves) } else { profitBlock(points) }
                facts(moves)
                Picker("Show", selection: $tab.animation(.snappy(duration: 0.2))) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                switch tab {
                case .positions: positions
                case .history: history(moves)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(DeskBackground())
        .deskSoftBottomEdge()
        .safeAreaInset(edge: .bottom) { actions }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        #if DEBUG
        .onAppear { if ProcessInfo.processInfo.arguments.contains("-board-history") { tab = .history } }
        #endif
        .sheet(isPresented: $editing) {
            if isSpot {
                SpotCopySheet(model: model, leader: address, name: name)
            } else {
                AutoCopySheet(address: address, name: name, copier: copier)
            }
        }
        .confirmationDialog("Stop copying \(name)?", isPresented: $confirmsStop, titleVisibility: .visible) {
            Button("Stop Copying", role: .destructive) { stop() }
        } message: {
            Text(isSpot ? "Tokens you already hold stay in your wallet." : "Copies already open stay open until you close them.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            TraderAvatar(address: address, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
                    .lineLimit(1)
                Text(sinceLine)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .lineLimit(2)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(isLive ? DeskColor.rise.color : DeskColor.action.color).frame(width: 7, height: 7)
                Text(statusWord)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
            }
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(Color.white.opacity(0.07), in: Capsule())
        }
        .padding(.top, 8)
    }

    private var statusWord: String {
        if isSpot { return spot.isPaused ? "Paused" : isLive ? "Copying" : "Starting" }
        return copied == nil ? "Stopped" : copier.isPaused ? "Paused" : "Copying"
    }

    private var sinceLine: String {
        let rules: String
        if let r = copied?.rules { rules = "$\(r.marginPerTrade) a trade · \(r.maxLeverage)×\(r.mode == .shadow ? " · practice" : "")" }
        else if let r = spotLeader?.rules { rules = r.sizing == .fixed ? "$\(Int(r.amount)) a buy" : "Up to $\(Int(r.maxPerBuy)) a buy" }
        else { rules = "" }
        let start = since.map { "Since \($0.formatted(.dateTime.day().month()))" }
        return [start, rules.isEmpty ? nil : rules].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Profit block

    private func profitBlock(_ points: [PortfolioChartPoint]) -> some View {
        let shown = selected.map { $0.value - (points.first?.value ?? 0) } ?? profit
        return VStack(alignment: .leading, spacing: 6) {
            Text(selected.map { $0.date.formatted(date: .abbreviated, time: .shortened) } ?? "Your profit from \(name)")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(DeskColor.nightMuted.color)
            Text(shown == 0 ? "$0.00" : DisplayCurrency.shared.format(shown, signed: true))
                .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(shown > 0 ? DeskColor.rise.color : shown < 0 ? DeskColor.fall.color : DeskColor.nightText.color)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.2), value: shown)
            PortfolioChart(points: points, baseline: points.first?.value ?? 0, selected: $selected, stepped: true)
                .frame(height: 140)
                .padding(.top, 4)
            Picker("Range", selection: $range.animation(.snappy(duration: 0.2))) {
                ForEach(Range.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.top, 4)
            .onChange(of: range) { _, _ in selected = nil }
        }
    }

    /// Spot copies have no mark-to-market yet: what went in and what came back.
    private func spotSummary(_ moves: [Move]) -> some View {
        let bought = spot.log.filter { $0.leader?.lowercased() == address.lowercased() && $0.side == "buy" && $0.status == "copied" }.compactMap(\.ausd).reduce(0, +)
        let sold = spot.log.filter { $0.leader?.lowercased() == address.lowercased() && $0.side == "sell" && $0.status == "copied" }.compactMap(\.ausd).reduce(0, +)
        return HStack(spacing: 12) {
            bigStat(String(format: "$%.2f", bought), "Bought with them")
            bigStat(String(format: "$%.2f", sold), "Sold back")
        }
    }

    private func bigStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit()).foregroundStyle(DeskColor.nightText.color)
            Text(label).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(DeskColor.nightMuted.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Facts

    private func facts(_ moves: [Move]) -> some View {
        let copiedCount = moves.filter { $0.outcome == .copied || $0.outcome == .protected }.count
        let inOpen = open.map(\.margin).reduce(0, +)
        return HStack(spacing: 0) {
            fact(isSpot ? "\(spot.positions.count)" : "\(open.count)", "Open")
            fact("\(copiedCount) of \(moves.count)", "Copied")
            fact(isSpot ? "—" : "$\(Self.money(inOpen))", "In open copies")
        }
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func fact(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit()).foregroundStyle(DeskColor.nightText.color).lineLimit(1)
            Text(label).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(DeskColor.nightMuted.color)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Positions

    @ViewBuilder private var positions: some View {
        if isSpot {
            if spot.positions.isEmpty {
                empty("No tokens held from copying yet.")
            } else {
                ForEach(spot.positions) { position in
                    row(symbol: position.symbol ?? "Token", title: position.symbol ?? "Token", detail: "Held from copying", trailing: nil, time: nil)
                }
            }
        } else if open.isEmpty {
            empty(isLive ? "Nothing open right now. Their next trade is copied the moment it lands." : "Nothing open.")
        } else {
            ForEach(open) { copy in
                let pnl = copy.shadowPnL(takerFeeMicros: copier.takerFee(for: copy.symbol))
                row(symbol: copy.symbol, title: "\(copy.isLong ? "Long" : "Short") \(copy.symbol) \(copy.leverage)×",
                    detail: "$\(Self.money(copy.margin))\(copy.shadowed ? " · practice" : "") · \(copy.openedAt.formatted(.relative(presentation: .named)))",
                    trailing: pnl.map { (DisplayCurrency.shared.format($0, signed: true), $0 >= 0 ? DeskColor.rise : DeskColor.fall) }, time: nil)
            }
        }
    }

    // MARK: History

    @ViewBuilder private func history(_ moves: [Move]) -> some View {
        if moves.isEmpty {
            empty("Every move they make, and what Desk did about it, shows up here.")
        }
        ForEach(Array(moves.enumerated()), id: \.element.id) { index, move in
            if index == 0 || !Calendar.current.isDate(move.date, inSameDayAs: moves[index - 1].date) {
                Text(dayLabel(move.date))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .padding(.top, index == 0 ? 0 : 10)
            }
            row(symbol: move.symbol, title: move.title, detail: move.detail,
                trailing: trailing(for: move), time: move.date.formatted(date: .omitted, time: .shortened))
                .opacity(move.outcome == .skipped ? 0.55 : 1)
        }
    }

    private func trailing(for move: Move) -> (String, DeskRGB)? {
        if let pnl = move.pnl { return (DisplayCurrency.shared.format(pnl, signed: true), pnl >= 0 ? DeskColor.rise : DeskColor.fall) }
        switch move.outcome {
        case .skipped: return ("Skipped", DeskColor.nightMuted)
        case .failed: return ("Failed", DeskColor.fall)
        default: return nil
        }
    }

    private func row(symbol: String, title: String, detail: String, trailing: (String, DeskRGB)?, time: String?) -> some View {
        HStack(alignment: .center, spacing: 12) {
            MarketTokenLogo(symbol: symbol, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if let trailing {
                    Text(trailing.0)
                        .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(trailing.1.color)
                }
                if let time {
                    Text(time)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                }
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5) }
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .foregroundStyle(DeskColor.nightMuted.color)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
    }

    private func dayLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).day().month())
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 10) {
            Button { editing = true } label: {
                Text("Adjust")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
            }
            .controlSize(.large)
            .deskSecondaryButton()
            Button(role: .destructive) { confirmsStop = true } label: {
                Text("Stop copying")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
            }
            .controlSize(.large)
            .deskSecondaryButton()
            .tint(DeskColor.fall.color)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private func stop() {
        if isSpot {
            Task { try? await spot.setRules(nil, for: address, name: name); dismiss() }
        } else {
            copier.stop(address)
            dismiss()
        }
    }

    static func money(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.2f", value)
    }
}
