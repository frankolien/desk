import DeskFlow
import DeskUI
import SwiftUI

/// The rules for copying one trader, set before anything is sent.
struct AutoCopySheet: View {
    let address: String
    let name: String
    let copier: CopyTrader

    @Environment(\.dismiss) private var dismiss
    @State private var rules: CopyRules
    @State private var confirmsStop = false

    init(address: String, name: String, copier: CopyTrader) {
        self.address = address
        self.name = name
        self.copier = copier
        _rules = State(initialValue: copier.rules(for: address) ?? CopyRules())
    }

    private var isActive: Bool { copier.rules(for: address) != nil }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        TraderAvatar(address: address, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Auto-copy \(name)")
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text("Their entries and exits, on your Perpl \(copier.network.shortName.lowercased()) account")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.white.opacity(0.55))
                                .lineLimit(2)
                        }
                    }
                    .padding(.top, 28)

                    section("Margin per trade (AUSD)", detail: "What each copy puts at risk, whatever size they trade.") {
                        chips([5, 10, 25, 50, 100], selection: $rules.marginPerTrade) { "\($0)" }
                    }
                    section("Leverage cap", detail: "Their leverage is followed up to this, never past it.") {
                        chips([2, 3, 5, 10], selection: $rules.maxLeverage) { "\($0)×" }
                    }
                    section("Stop loss", detail: stopDetail) {
                        chips([nil, 10, 25, 50], selection: $rules.stopLossPercent) { $0.map { "−\($0)%" } ?? "Off" }
                    }
                    section("Take profit", detail: "Of the margin. Also held on Perpl.") {
                        chips([nil, 25, 50, 100], selection: $rules.takeProfitPercent) { $0.map { "+\($0)%" } ?? "Off" }
                    }
                    section("Don't chase", detail: "Skip a copy if the price has already run this far past their entry.") {
                        chips([50, 100, 200], selection: $rules.maxChaseBps) { String(format: "%.1f%%", Double($0) / 100) }
                    }

                    Toggle(isOn: $rules.closeWithTrader) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Close when they close")
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                            Text("Flips close your copy before opening the new side.")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.white.opacity(0.5))
                        }
                    }
                    .tint(DeskColor.rise.color)
                    .padding(.top, 24)

                    Label {
                        Text("New copies are sent only while Desk is open and unlocked, signed on this phone. Stops and take profits live on Perpl, so they protect you after Desk closes.")
                    } icon: {
                        Image(systemName: "lock.shield")
                    }
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.top, 22)

                    if copier.network.holdsRealFunds {
                        Label("Mainnet copies use real AUSD.", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(DeskColor.action.color)
                            .padding(.top, 12)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }

            VStack(spacing: 4) {
                PrimaryButton(title: isActive ? "Save rules" : "Start copying") {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    copier.start(address, rules: rules)
                    dismiss()
                }
                if isActive {
                    Button("Stop copying", role: .destructive) { confirmsStop = true }
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 6)
        }
        .background(Color(red: 0.07, green: 0.07, blue: 0.08).ignoresSafeArea())
        .confirmationDialog("Stop copying \(name)?", isPresented: $confirmsStop, titleVisibility: .visible) {
            Button("Stop copying", role: .destructive) {
                copier.stop(address)
                dismiss()
            }
        } message: {
            Text("Copies already open stay open, with their stops, until you close them.")
        }
    }

    private var stopDetail: String {
        guard let stop = rules.stopLossPercent else { return "No stop. A copy runs until they close or you do." }
        let move = Double(stop) / Double(rules.maxLeverage)
        return String(format: "Of the margin. At %d×, that is a %.1f%% move against you.", rules.maxLeverage, move)
    }

    private func section(_ title: String, detail: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
        .padding(.top, 24)
    }

    private func chips<Value: Hashable>(
        _ values: [Value], selection: Binding<Value>, label: @escaping (Value) -> String
    ) -> some View {
        HStack(spacing: 8) {
            ForEach(values, id: \.self) { value in
                let selected = selection.wrappedValue == value
                Button {
                    UISelectionFeedbackGenerator().selectionChanged()
                    withAnimation(.snappy(duration: 0.18)) { selection.wrappedValue = value }
                } label: {
                    Text(label(value))
                        .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(selected ? Color.black : Color.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(selected ? Color.white : Color.white.opacity(0.08), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// The line on a trader's profile that starts auto-copy, or says it is running.
struct AutoCopyButton: View {
    let rules: CopyRules?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: rules == nil ? "bolt" : "bolt.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(rules == nil ? Color.white : DeskColor.rise.color)
                    .frame(width: 30, height: 30)
                    .background((rules == nil ? Color.white : DeskColor.rise.color).opacity(0.1), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(rules == nil ? "Auto-copy this trader" : "Auto-copying")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(summary)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.35))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var summary: String {
        guard let rules else { return "Mirror their entries and exits with your own limits" }
        var parts = ["\(rules.marginPerTrade) AUSD per trade", "max \(rules.maxLeverage)×"]
        if let stop = rules.stopLossPercent { parts.append("stop −\(stop)%") }
        return parts.joined(separator: " · ")
    }
}

/// Auto-copy at a glance, above the traders on Signals.
struct CopyStatusCard: View {
    let copier: CopyTrader
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill((copier.isPaused ? Color.white : DeskColor.rise.color).opacity(0.12))
                    Image(systemName: copier.isPaused ? "pause.fill" : "bolt.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(copier.isPaused ? Color.white.opacity(0.7) : DeskColor.rise.color)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 3) {
                    Text(copier.isPaused ? "Auto-copy paused" : "Auto-copying \(copier.traders.count) \(copier.traders.count == 1 ? "trader" : "traders")")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(detail)
                        .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(Color.white.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(DisplayCurrency.shared.format(copier.realisedToday, signed: true))
                        .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(copier.realisedToday < 0 ? DeskColor.fall.color
                                         : (copier.realisedToday > 0 ? DeskColor.rise.color : .white))
                    Text("Today")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.45))
                }
            }
            .padding(14)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var detail: String {
        if let problem = copier.readProblem { return problem }
        let open = "\(copier.open.count) open"
        guard let read = copier.lastRead else { return "\(open) · starting" }
        return "\(open) · read \(read.formatted(.relative(presentation: .numeric)))"
    }
}

/// Everything auto-copy has done, the limits across it, and the switch that stops it.
struct CopyActivityScreen: View {
    let copier: CopyTrader
    let directory: TraderDirectory

    @Environment(\.dismiss) private var dismiss
    @State private var editing: CopiedTrader?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .deskGlass(interactive: true, in: Circle())
                        Spacer()
                    }
                    .padding(.top, 6)

                    Text("Auto-copy")
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.top, 14)
                    Text("Reads traders on Perpl mainnet every few seconds. Copies go to your Perpl \(copier.network.shortName.lowercased()) account.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)

                    pauseRow.padding(.top, 18)
                    stats.padding(.top, 12)

                    header("Copying")
                    if copier.traders.isEmpty {
                        empty("No one yet. Open a trader on Signals and turn on auto-copy.")
                    } else {
                        VStack(spacing: 0) {
                            ForEach(copier.traders) { trader in
                                Button { editing = trader } label: { traderRow(trader) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }

                    header("Limits")
                    limits

                    header("Log")
                    if copier.log.isEmpty {
                        empty("Nothing yet. The first reading of each trader is a baseline; copies start from their next move.")
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(copier.log) { entry in
                                CopyLogRow(entry: entry, name: directory.name(for: entry.trader))
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 60)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $editing) { trader in
            AutoCopySheet(address: trader.address, name: directory.name(for: trader.address), copier: copier)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private var pauseRow: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(copier.isPaused ? Color.white.opacity(0.35) : DeskColor.rise.color)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(copier.isPaused ? "Paused" : "Running")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(copier.isPaused ? "No new copies. Open copies keep their stops." : "\(copier.open.count) open · last read \(copier.lastRead.map { $0.formatted(date: .omitted, time: .standard) } ?? "not yet")")
                    .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            Spacer()
            Toggle("Running", isOn: Binding(get: { !copier.isPaused }, set: { copier.setPaused(!$0) }))
                .labelsHidden()
                .tint(DeskColor.rise.color)
        }
        .padding(14)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var stats: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                stat("Realised PnL", DisplayCurrency.shared.format(copier.realisedTotal, signed: true),
                     tint: copier.realisedTotal < 0 ? DeskColor.fall.color : (copier.realisedTotal > 0 ? DeskColor.rise.color : .white))
                stat("Win rate", copier.winRate.map { String(format: "%.0f%%", $0 * 100) } ?? Unavailable.text,
                     detail: "\(copier.closedCount) closed")
            }
            GridRow {
                stat("Copies", "\(copier.copiedCount)", detail: "\(copier.open.count) open")
                stat("Time to fill", copier.averageFillSeconds.map { String(format: "%.1fs", $0) } ?? Unavailable.text,
                     detail: "from their move")
            }
        }
    }

    private func stat(_ title: String, _ value: String, detail: String? = nil, tint: Color = .white) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.5))
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail ?? " ")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var limits: some View {
        VStack(alignment: .leading, spacing: 14) {
            limitRow("Open copies at once", values: [1, 3, 5, 10], selected: copier.guards.maxOpenCopies, label: { "\($0)" }) { value in
                var next = copier.guards
                next.maxOpenCopies = value
                copier.updateGuards(next)
            }
            limitRow("Pause after losing today", values: [25, 50, 100, 250], selected: copier.guards.dailyLossLimit, label: { "\($0)" }) { value in
                var next = copier.guards
                next.dailyLossLimit = value
                copier.updateGuards(next)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func limitRow(
        _ title: String, values: [Int], selected: Int, label: @escaping (Int) -> String, onSelect: @escaping (Int) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title + (title.hasPrefix("Pause") ? " (AUSD)" : ""))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.8))
            HStack(spacing: 8) {
                ForEach(values, id: \.self) { value in
                    Button {
                        UISelectionFeedbackGenerator().selectionChanged()
                        onSelect(value)
                    } label: {
                        Text(label(value))
                            .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(value == selected ? Color.black : Color.white)
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .background(value == selected ? Color.white : Color.white.opacity(0.08), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func traderRow(_ trader: CopiedTrader) -> some View {
        HStack(spacing: 12) {
            TraderAvatar(address: trader.address, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(directory.name(for: trader.address))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text("\(trader.rules.marginPerTrade) AUSD · max \(trader.rules.maxLeverage)× · \(trader.rules.stopLossPercent.map { "stop −\($0)%" } ?? "no stop")")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            Spacer()
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.4))
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 18, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.top, 28)
            .padding(.bottom, 8)
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.5))
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct CopyLogRow: View {
    let entry: CopyLogEntry
    let name: String

    private var symbol: (name: String, tint: Color) {
        switch entry.kind {
        case .opened: ("arrow.up.right", DeskColor.rise.color)
        case .closed: ("checkmark", Color.white)
        case .protected: ("shield.lefthalf.filled", Color.white)
        case .skipped: ("forward.end", Color.white.opacity(0.5))
        case .failed: ("exclamationmark", DeskColor.fall.color)
        case .paused: ("pause", DeskColor.action.color)
        }
    }

    private var title: String {
        let side = "\(entry.isLong ? "long" : "short") \(entry.symbol)\(entry.leverage.map { " \($0)×" } ?? "")"
        return switch entry.kind {
        case .opened: "Copied \(name)'s \(side)"
        case .closed: "Closed \(side)"
        case .protected: "\(side.prefix(1).uppercased() + side.dropFirst()) closed on Perpl"
        case .skipped: "Skipped \(name)'s \(side)"
        case .failed: "Couldn't copy \(name)'s \(side)"
        case .paused: "Auto-copy paused"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol.name)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(symbol.tint)
                .frame(width: 30, height: 30)
                .background(Color.white.opacity(0.07), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(entry.detail)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                Text([entry.date.formatted(.relative(presentation: .named)),
                      entry.fillSeconds.map { String(format: "filled %.1fs after their move", $0) }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.35))
            }
            Spacer(minLength: 8)
            if let pnl = entry.pnl {
                Text(DisplayCurrency.shared.format(pnl, signed: true))
                    .font(.system(size: 14, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(pnl < 0 ? DeskColor.fall.color : DeskColor.rise.color)
            }
        }
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5).padding(.leading, 42)
        }
    }
}
