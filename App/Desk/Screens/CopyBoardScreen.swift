import DeskUI
import SwiftUI

/// One copied trader, laid out like an investigation board: them and you joined by a live
/// wire, every move they made on a two-lane trace with what Desk did about it (copied and
/// wired across, or a broken wire and why not), what each of you holds now, and the timeline.
/// It's the answer to "is Auto-Copy doing anything?"
struct CopyBoardScreen: View {
    let address: String
    let model: AppModel
    let copier: CopyTrader
    let directory: TraderDirectory

    @State private var leader: TraderSnapshot?
    @State private var editing = false
    @State private var range: Range = .week
    @State private var spot = SpotCopier.shared

    enum Range: String, CaseIterable { case day = "24H", week = "7D", all = "All" }

    /// One move of theirs and what came of it here.
    struct Move: Identifiable {
        enum Outcome { case copied, skipped, failed, protected }
        let id: String
        let date: Date
        let symbol: String
        let adds: Bool // opened or bought: ＋; closed or sold: −
        let theirs: String
        let outcome: Outcome
        let yours: String
        let pnl: Double?
    }

    private var copied: CopiedTrader? { copier.traders.first { $0.address.lowercased() == address.lowercased() } }
    /// Copied for their token trades, by Desk's server (spot Auto-Copy).
    private var spotLeader: SpotCopier.Leader? { spot.leaders[address.lowercased()] }
    private var spotLive: Bool { spotLeader != nil && spot.stage == "live" && !spot.isPaused }
    private var name: String { directory.name(for: address) }

    private var moves: [Move] {
        let key = address.lowercased()
        var out: [Move] = []
        for entry in copier.shownLog where entry.trader.lowercased() == key {
            let side = entry.isLong ? "long" : "short"
            switch entry.kind {
            case .opened:
                let size = [entry.margin.map { "\(Self.money($0)) AUSD" }, entry.leverage.map { "\($0)×" }].compactMap { $0 }.joined(separator: " at ")
                let speed = entry.fillSeconds.map { String(format: " · %.1fs later", $0) } ?? ""
                out.append(Move(id: entry.id.uuidString, date: entry.date, symbol: entry.symbol, adds: true,
                                theirs: "Opened \(side) \(entry.symbol)", outcome: .copied,
                                yours: "\(size.isEmpty ? "Same side, your size" : size)\(speed)\(entry.shadowed ? " · shadow" : "")", pnl: nil))
            case .closed:
                out.append(Move(id: entry.id.uuidString, date: entry.date, symbol: entry.symbol, adds: false,
                                theirs: "Closed \(side) \(entry.symbol)", outcome: .copied,
                                yours: "Closed with them\(entry.shadowed ? " · shadow" : "")", pnl: entry.pnl))
            case .protected:
                out.append(Move(id: entry.id.uuidString, date: entry.date, symbol: entry.symbol, adds: false,
                                theirs: "Still in \(entry.symbol)", outcome: .protected,
                                yours: entry.detail.isEmpty ? "Your stop closed it" : entry.detail, pnl: entry.pnl))
            case .skipped:
                out.append(Move(id: entry.id.uuidString, date: entry.date, symbol: entry.symbol, adds: true,
                                theirs: "Opened \(side) \(entry.symbol)", outcome: .skipped, yours: entry.detail, pnl: nil))
            case .failed:
                out.append(Move(id: entry.id.uuidString, date: entry.date, symbol: entry.symbol, adds: true,
                                theirs: "Traded \(entry.symbol)", outcome: .failed, yours: entry.detail, pnl: nil))
            default: continue
            }
        }
        for row in spot.log where row.leader?.lowercased() == key {
            guard let side = row.side, side == "buy" || side == "sell", let symbol = row.symbol else { continue }
            let outcome: Move.Outcome = row.status == "copied" ? .copied : row.status == "failed" ? .failed : .skipped
            let yours = row.status == "copied"
                ? (side == "buy" ? "Bought \(String(format: "%.2f", row.ausd ?? 0)) AUSD of it" : "Sold for \(String(format: "%.2f", row.ausd ?? 0)) AUSD")
                : (row.detail ?? "Not copied")
            out.append(Move(id: "spot-\(row.id)", date: row.date, symbol: symbol, adds: side == "buy",
                            theirs: "\(side == "buy" ? "Bought" : "Sold") \(symbol)", outcome: outcome, yours: yours, pnl: nil))
        }
        let since = range == .all ? Date.distantPast : Date.now.addingTimeInterval(range == .day ? -86_400 : -7 * 86_400)
        return out.filter { $0.date >= since }.sorted { $0.date > $1.date }
    }

    var body: some View {
        let moves = moves
        ScrollViewReader { reader in
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                link
                scoreboard(moves)
                Picker("Range", selection: $range.animation(.snappy(duration: 0.2))) {
                    ForEach(Range.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                CopyTrace(moves: moves, start: traceStart(moves),
                          followedAt: copied?.since ?? spotLeader?.since.map { Date(timeIntervalSince1970: $0 / 1000) })
                    .frame(height: 150)
                rightNow
                timeline(moves).id("timeline")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 60)
        }
        #if DEBUG
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-board-timeline") else { return }
            try? await Task.sleep(for: .seconds(1))
            reader.scrollTo("timeline", anchor: .top)
        }
        #endif
        }
        .background(DeskBackground())
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = true } label: { Label("Rules", systemImage: "slider.horizontal.3") }
            }
        }
        .sheet(isPresented: $editing) {
            if copied == nil && spotLeader != nil {
                SpotCopySheet(model: model, leader: address, name: name)
            } else {
                AutoCopySheet(address: address, name: name, copier: copier)
            }
        }
        .task(id: address) {
            while !Task.isCancelled {
                leader = await directory.trader(address) ?? leader
                try? await Task.sleep(for: .seconds(20))
            }
        }
        .refreshable { leader = await directory.trader(address) ?? leader }
    }

    // MARK: The link

    private var link: some View {
        VStack(spacing: 14) {
            HStack(alignment: .center, spacing: 0) {
                party(address: address, title: name, caption: "Leader")
                LiveWire(active: isLive)
                    .frame(height: 30)
                    .padding(.horizontal, 6)
                party(address: model.address?.checksummed ?? "", title: "You", caption: copied?.rules.mode == .shadow ? "Shadow" : copied == nil && spotLeader != nil ? "Token copies" : "Live money")
            }
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack(spacing: 8) {
                    Circle()
                        .fill(isLive ? DeskColor.rise.color : DeskColor.action.color)
                        .frame(width: 8, height: 8)
                        .shadow(color: (isLive ? DeskColor.rise.color : .clear).opacity(0.9), radius: 5)
                        .phaseAnimator([false, true]) { dot, on in dot.opacity(on ? 1 : 0.35) } animation: { _ in .easeInOut(duration: 0.9) }
                    Text(statusLine)
                        .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(DeskColor.nightText.color)
                }
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(Color.white.opacity(0.06), in: Capsule())
            }
            if let rules = spotLeader?.rules, copied == nil {
                Text("\(rules.sizing == .fixed ? "\(Int(rules.amount)) AUSD a buy" : "Their size, up to \(Int(rules.maxPerBuy)) AUSD")\(rules.copySells ? " · sells with them" : "")")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
            if let rules = copied?.rules {
                Text("\(rules.marginPerTrade) AUSD a copy · up to \(rules.maxLeverage)×\(rules.direction == .fade ? " · fading them" : "")")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private func party(address: String, title: String, caption: String) -> some View {
        VStack(spacing: 6) {
            TraderAvatar(address: address, size: 58)
                .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 1))
            Text(title).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(DeskColor.nightText.color).lineLimit(1)
            Text(caption).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(DeskColor.nightMuted.color)
        }
        .frame(width: 92)
    }

    /// Who's watching for this trader, and how recently it looked.
    private var lastLook: (who: String, at: Date?) {
        if copier.server.isOn {
            let ago = copier.server.snapshot?.engine.lastSweepAgoMs
            let at = copier.server.checkedAt.map { $0.addingTimeInterval(-(ago ?? 0) / 1000) }
            return ("Desk's server", at)
        }
        return ("This iPhone", copier.lastRead)
    }

    private var isLive: Bool {
        if copied == nil { return spotLive }
        guard !copier.isPaused, let at = lastLook.at else { return false }
        return Date.now.timeIntervalSince(at) < 180
    }

    private var statusLine: String {
        if copied == nil {
            guard spotLeader != nil else { return "Not copying them" }
            if spot.isPaused { return "Paused" }
            return spotLive ? "Watching · Desk's server, every few seconds" : "Turning on…"
        }
        if copier.isPaused { return "Paused" }
        let look = lastLook
        guard let at = look.at else { return "\(look.who) · starting…" }
        let seconds = Int(Date.now.timeIntervalSince(at))
        let ago = seconds < 60 ? "\(max(1, seconds))s ago" : seconds < 3600 ? "\(seconds / 60)m ago" : "\(seconds / 3600)h ago"
        return isLive ? "Watching · \(look.who) checked \(ago)" : "\(look.who) last checked \(ago)"
    }

    // MARK: Scoreboard

    private func scoreboard(_ moves: [Move]) -> some View {
        let theirs = moves.count
        let copiedCount = moves.filter { $0.outcome == .copied }.count
        let pnl = moves.compactMap(\.pnl).reduce(0, +)
        return HStack(spacing: 0) {
            stat("\(theirs)", "Their moves")
            divider
            stat("\(copiedCount)", "Copied", tint: copiedCount > 0 ? DeskColor.rise : DeskColor.nightText)
            divider
            stat(theirs == 0 ? "—" : "\(theirs - copiedCount)", "Skipped")
            divider
            stat(pnl == 0 ? "$0" : DisplayCurrency.shared.format(pnl, signed: true), "Your P&L",
                 tint: pnl > 0 ? DeskColor.rise : pnl < 0 ? DeskColor.fall : DeskColor.nightText)
        }
        .padding(.vertical, 14)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var divider: some View { Rectangle().fill(Color.white.opacity(0.08)).frame(width: 0.5, height: 34) }

    private func stat(_ value: String, _ label: String, tint: DeskRGB = DeskColor.nightText) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.system(size: 18, weight: .bold, design: .rounded).monospacedDigit()).foregroundStyle(tint.color).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(DeskColor.nightMuted.color)
        }
        .frame(maxWidth: .infinity)
    }

    /// The trace spans what happened, not the whole range: five moves in the last few hours of
    /// a week would sit in a clump at the edge. A tenth of the span is left before the first.
    private func traceStart(_ moves: [Move]) -> Date {
        let floor = Date.now.addingTimeInterval(range == .day ? -86_400 : range == .week ? -7 * 86_400 : -365 * 86_400)
        var first = moves.last?.date ?? .now.addingTimeInterval(-3600)
        if let since = copied?.since, since > floor { first = min(first, since) }
        let span = max(3600, Date.now.timeIntervalSince(first))
        return max(floor, first.addingTimeInterval(-span * 0.1))
    }

    // MARK: Right now

    @ViewBuilder private var rightNow: some View {
        let mine = copier.shownOpen.filter { $0.trader.lowercased() == address.lowercased() }
        let theirs = leader?.positions ?? []
        let markets = Array(Set(theirs.map(\.market) + mine.map(\.symbol))).sorted()
        VStack(alignment: .leading, spacing: 10) {
            boardTitle("Right now", detail: markets.isEmpty ? "Neither of you holds anything" : "Their positions next to yours")
            ForEach(markets, id: \.self) { market in
                let their = theirs.first { $0.market == market }
                let yours = mine.first { $0.symbol == market }
                HStack(spacing: 0) {
                    holding(their.map { "\($0.isLong ? "Long" : "Short") \(market)\($0.leverage.map { String(format: " %.0f×", $0) } ?? "")" },
                            detail: their.map { "\($0.isProfit ? "+" : "")\($0.pnl) PnL" }, up: their?.isProfit)
                    ZStack {
                        Rectangle()
                            .fill(their != nil && yours != nil ? DeskColor.rise.color : Color.white.opacity(0.15))
                            .frame(height: 2)
                        Image(systemName: their != nil && yours != nil ? "link" : "link.badge.plus")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(their != nil && yours != nil ? DeskColor.rise.color : DeskColor.nightMuted.color)
                            .padding(5)
                            .background(Circle().fill(Color.black))
                    }
                    .frame(width: 44)
                    holding(yours.map { "\($0.isLong ? "Long" : "Short") \(market) \($0.leverage)×" },
                            detail: yours.map { "\(Self.money($0.margin)) AUSD\($0.shadowed ? " · shadow" : "")" }, up: nil)
                }
            }
        }
    }

    private func holding(_ title: String?, detail: String?, up: Bool?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title ?? "Not in it").font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(title == nil ? DeskColor.nightMuted.color : DeskColor.nightText.color).lineLimit(1)
            if let detail {
                Text(detail).font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(up == nil ? DeskColor.nightMuted.color : (up! ? DeskColor.rise.color : DeskColor.fall.color)).lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(title == nil ? 0.03 : 0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Timeline

    private func timeline(_ moves: [Move]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            boardTitle("Every move", detail: "Theirs on the left, what Desk did on the right")
            if moves.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(DeskColor.rise.color)
                        .symbolEffect(.variableColor.iterative, options: .repeating, isActive: isLive)
                    Text(isLive ? "Waiting for their next move. Desk copies it the moment it lands." : "Nothing in this range yet.")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            }
            ForEach(Array(moves.enumerated()), id: \.element.id) { index, move in
                if index == 0 || !Calendar.current.isDate(move.date, inSameDayAs: moves[index - 1].date) {
                    Text(move.date.formatted(.dateTime.weekday(.wide).day().month()))
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .padding(.top, index == 0 ? 0 : 8)
                }
                MoveRow(move: move)
            }
        }
    }

    private func boardTitle(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(DeskColor.nightText.color)
            Text(detail).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(DeskColor.nightMuted.color)
        }
    }

    static func money(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.2f", value)
    }
}

/// Them and you, joined: a dashed wire whose dashes run toward you while copying is live, with
/// a pulse travelling along it.
struct LiveWire: View {
    let active: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !active)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height / 2))
                path.addCurve(to: CGPoint(x: size.width, y: size.height / 2),
                              control1: CGPoint(x: size.width * 0.3, y: 0), control2: CGPoint(x: size.width * 0.7, y: size.height))
                let tint = active ? DeskColor.rise.color : Color.white.opacity(0.25)
                canvas.stroke(path, with: .color(tint.opacity(0.35)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                canvas.stroke(path, with: .color(tint), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 7], dashPhase: active ? -CGFloat(t * 24) : 0))
                if active {
                    let progress = (t.truncatingRemainder(dividingBy: 1.6)) / 1.6
                    if let point = path.trimmedPath(from: 0, to: progress).currentPoint {
                        canvas.fill(Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)), with: .color(DeskColor.rise.color))
                    }
                }
            }
        }
    }
}

/// Two lanes over time: their moves on top, yours below, copied pairs wired across and the
/// moves Desk let pass left hanging with a cross.
struct CopyTrace: View {
    let moves: [CopyBoardScreen.Move]
    let start: Date
    let followedAt: Date?

    var body: some View {
        Canvas { canvas, size in
            let left: CGFloat = 46, right: CGFloat = 12
            let top = size.height * 0.28, bottom = size.height * 0.78
            // Evenly spaced in order, like a transit map: a burst of moves in one hour stays
            // readable next to a quiet week. "You followed" takes a stop of its own.
            let ordered = moves.reversed().map(\.date)
            var stops = ordered
            if let followedAt, followedAt > start { stops.append(followedAt) }
            stops.sort()
            let slots = CGFloat(max(stops.count, 1))
            let x = { (date: Date) -> CGFloat in
                let index = CGFloat(stops.firstIndex(of: date) ?? 0)
                return left + 12 + (index + 0.5) / slots * (size.width - left - right - 24)
            }

            for (label, y) in [("THEM", top), ("YOU", bottom)] {
                var lane = Path()
                lane.move(to: CGPoint(x: left, y: y))
                lane.addLine(to: CGPoint(x: size.width - right, y: y))
                canvas.stroke(lane, with: .color(.white.opacity(0.12)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                canvas.draw(Text(label).font(.system(size: 10, weight: .heavy, design: .rounded)).foregroundStyle(.white.opacity(0.5)),
                            at: CGPoint(x: 4, y: y), anchor: .leading)
            }
            if let followedAt, followedAt > start {
                let fx = x(followedAt)
                var mark = Path()
                mark.move(to: CGPoint(x: fx, y: 8))
                mark.addLine(to: CGPoint(x: fx, y: size.height - 8))
                canvas.stroke(mark, with: .color(DeskColor.action.color.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                canvas.draw(Text("you followed").font(.system(size: 9, weight: .bold, design: .rounded)).foregroundStyle(DeskColor.action.color),
                            at: CGPoint(x: fx + 4, y: 8), anchor: .topLeading)
            }
            for move in moves.reversed() {
                let mx = x(move.date)
                let tint = move.adds ? DeskColor.rise.color : DeskColor.fall.color
                var wire = Path()
                wire.move(to: CGPoint(x: mx, y: top))
                switch move.outcome {
                case .copied, .protected:
                    wire.addCurve(to: CGPoint(x: mx + 8, y: bottom), control1: CGPoint(x: mx, y: (top + bottom) / 2), control2: CGPoint(x: mx + 8, y: (top + bottom) / 2))
                    canvas.stroke(wire, with: .color(tint.opacity(0.7)), lineWidth: 1.5)
                    node(canvas, at: CGPoint(x: mx + 8, y: bottom), sign: move.adds ? "+" : "−", tint: tint, filled: true)
                case .skipped, .failed:
                    let end = CGPoint(x: mx, y: (top + bottom) / 2)
                    wire.addLine(to: end)
                    canvas.stroke(wire, with: .color(.white.opacity(0.3)), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                    canvas.draw(Text("✕").font(.system(size: 10, weight: .bold)).foregroundStyle(move.outcome == .failed ? DeskColor.fall.color : .white.opacity(0.5)),
                                at: end, anchor: .center)
                }
                node(canvas, at: CGPoint(x: mx, y: top), sign: move.adds ? "+" : "−", tint: tint, filled: false)
            }
            let label = { (date: Date) in
                Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened) : date.formatted(.dateTime.month(.abbreviated).day())
            }
            if let first = stops.first {
                canvas.draw(Text(label(first)).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.4)),
                            at: CGPoint(x: left, y: size.height), anchor: .bottomLeading)
            }
            canvas.draw(Text(stops.last.map(label) ?? "now").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.4)),
                        at: CGPoint(x: size.width - right, y: size.height), anchor: .bottomTrailing)
        }
        .padding(10)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.06)))
        .accessibilityLabel("\(moves.count) moves, \(moves.filter { $0.outcome == .copied }.count) copied")
    }

    private func node(_ canvas: GraphicsContext, at point: CGPoint, sign: String, tint: Color, filled: Bool) {
        let rect = CGRect(x: point.x - 9, y: point.y - 9, width: 18, height: 18)
        canvas.fill(Path(ellipseIn: rect), with: .color(filled ? tint : .black))
        canvas.stroke(Path(ellipseIn: rect), with: .color(tint), lineWidth: 1.5)
        canvas.draw(Text(sign).font(.system(size: 12, weight: .heavy, design: .rounded)).foregroundStyle(filled ? .black : tint), at: point, anchor: .center)
    }
}

/// Their move, the wire, and what came of it.
private struct MoveRow: View {
    let move: CopyBoardScreen.Move

    var body: some View {
        HStack(spacing: 0) {
            card(top: move.theirs, bottom: move.date.formatted(date: .omitted, time: .shortened),
                 sign: move.adds ? "+" : "−", tint: move.adds ? DeskColor.rise : DeskColor.fall, dim: false)
            wire.frame(width: 34)
            card(top: outcomeTitle, bottom: move.yours, sign: nil, tint: outcomeTint, dim: move.outcome == .skipped)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var outcomeTitle: String {
        switch move.outcome {
        case .copied: move.pnl.map { "Copied · \(DisplayCurrency.shared.format($0, signed: true))" } ?? "Copied"
        case .protected: move.pnl.map { "Protected · \(DisplayCurrency.shared.format($0, signed: true))" } ?? "Protected"
        case .skipped: "Not copied"
        case .failed: "Didn't go through"
        }
    }

    private var outcomeTint: DeskRGB {
        switch move.outcome {
        case .copied: DeskColor.rise
        case .protected: DeskColor.action
        case .skipped: DeskColor.nightMuted
        case .failed: DeskColor.fall
        }
    }

    private var wire: some View {
        ZStack {
            if move.outcome == .copied || move.outcome == .protected {
                Rectangle().fill(outcomeTint.color).frame(height: 2)
                Circle().fill(outcomeTint.color).frame(width: 8, height: 8)
            } else {
                HStack(spacing: 0) {
                    Rectangle().fill(Color.white.opacity(0.25)).frame(height: 1.5)
                    Image(systemName: "xmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(outcomeTint.color)
                    Spacer(minLength: 6)
                }
            }
        }
    }

    private func card(top: String, bottom: String, sign: String?, tint: DeskRGB, dim: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if let sign {
                Text(sign)
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(tint.color)
                    .frame(width: 22, height: 22)
                    .overlay(Circle().stroke(tint.color, lineWidth: 1.5))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(top).font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(sign == nil ? tint.color : DeskColor.nightText.color)
                    .lineLimit(2)
                Text(bottom).font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(dim ? 0.03 : 0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(sign == nil && !dim ? tint.color.opacity(0.35) : Color.clear, lineWidth: 1))
    }
}
