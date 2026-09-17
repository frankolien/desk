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

    private var stopLoss: Binding<Bool> {
        Binding(get: { rules.stopLossPercent != nil },
                set: { rules.stopLossPercent = $0 ? 25 : nil })
    }

    private var takeProfit: Binding<Bool> {
        Binding(get: { rules.takeProfitPercent != nil },
                set: { rules.takeProfitPercent = $0 ? 50 : nil })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        TraderAvatar(address: address, size: 52)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(name)
                                .font(.title3.weight(.semibold))
                                .lineLimit(1)
                            Text("Copied to your Perpl \(copier.network.shortName.lowercased()) account")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    Picker("Margin per trade", selection: $rules.marginPerTrade) {
                        ForEach([5, 10, 25, 50, 100, 250], id: \.self) { Text("\($0) AUSD").tag($0) }
                    }
                    Stepper(value: $rules.maxLeverage, in: 1...20) {
                        LabeledContent("Leverage cap", value: "\(rules.maxLeverage)×")
                    }
                    LabeledContent("Largest position", value: "\(rules.marginPerTrade * rules.maxLeverage) AUSD")
                } header: {
                    Text("Size")
                } footer: {
                    Text("Their size fits their account, not yours. Each copy uses your margin at their leverage, up to your cap.")
                }

                Section {
                    Toggle("Stop loss", isOn: stopLoss.animation())
                    if let stop = rules.stopLossPercent {
                        Picker("Close at", selection: Binding(get: { stop }, set: { rules.stopLossPercent = $0 })) {
                            ForEach([10, 15, 25, 35, 50], id: \.self) { Text("−\($0)% of margin").tag($0) }
                        }
                    }
                    Toggle("Take profit", isOn: takeProfit.animation())
                    if let take = rules.takeProfitPercent {
                        Picker("Close at", selection: Binding(get: { take }, set: { rules.takeProfitPercent = $0 })) {
                            ForEach([25, 50, 100, 200], id: \.self) { Text("+\($0)% of margin").tag($0) }
                        }
                    }
                } header: {
                    Text("Protection")
                } footer: {
                    Text(protectionFooter)
                }

                Section {
                    Toggle("Close when they close", isOn: $rules.closeWithTrader)
                    Picker("Skip if price ran", selection: $rules.maxChaseBps) {
                        ForEach([25, 50, 100, 200], id: \.self) { Text(String(format: "%.2g%%", Double($0) / 100)).tag($0) }
                    }
                } header: {
                    Text("Execution")
                } footer: {
                    Text("Skips a copy when the price has already moved that far past their entry. Copies are sent only while Desk is open and unlocked, signed on this iPhone.")
                }

                if copier.network.holdsRealFunds {
                    Section {
                        Label("Copies on mainnet use real AUSD.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                if isActive {
                    Section {
                        Button("Stop Copying", role: .destructive) { confirmsStop = true }
                    }
                }
            }
            .tint(DeskColor.rise.color)
            .navigationTitle(isActive ? "Copy Rules" : "Auto-Copy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    copier.start(address, rules: rules)
                    dismiss()
                } label: {
                    Text(isActive ? "Save Rules" : "Start Copying")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .controlSize(.large)
                .deskProminentButton()
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }
            .confirmationDialog("Stop copying \(name)?", isPresented: $confirmsStop, titleVisibility: .visible) {
                Button("Stop Copying", role: .destructive) {
                    copier.stop(address)
                    dismiss()
                }
            } message: {
                Text("Copies already open stay open, with their stops, until you close them.")
            }
        }
    }

    private var protectionFooter: String {
        guard let stop = rules.stopLossPercent else {
            return "Without a stop, a copy stays open until they close or you do."
        }
        let move = Double(stop) / Double(rules.maxLeverage)
        return String(format: "At %d×, a −%d%% stop is a %.1f%% price move against you. Stops and take profits are placed on Perpl, so they hold after Desk closes.",
                      rules.maxLeverage, stop, move)
    }
}

/// Starts auto-copy from a trader's profile, or shows it is running.
struct AutoCopyButton: View {
    let rules: CopyRules?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: rules == nil ? "bolt.fill" : "bolt.circle.fill")
                    .font(.title3)
                    .foregroundStyle(rules == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(DeskColor.rise.color))
                    .symbolEffect(.pulse, options: .repeating, isActive: rules != nil)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(rules == nil ? "Auto-Copy" : "Auto-Copying")
                        .font(.subheadline.weight(.semibold))
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .deskGlass(interactive: true, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var summary: String {
        guard let rules else { return "Mirror their trades with your own limits" }
        var parts = ["\(rules.marginPerTrade) AUSD", "up to \(rules.maxLeverage)×"]
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
                Image(systemName: copier.isPaused ? "pause.circle.fill" : "bolt.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(copier.isPaused ? AnyShapeStyle(.secondary) : AnyShapeStyle(DeskColor.rise.color))
                    .symbolEffect(.pulse, options: .repeating, isActive: !copier.isPaused && copier.readProblem == nil)
                VStack(alignment: .leading, spacing: 2) {
                    Text(copier.isPaused ? "Auto-Copy Paused" : "Auto-Copying \(copier.traders.count) \(copier.traders.count == 1 ? "Trader" : "Traders")")
                        .font(.subheadline.weight(.semibold))
                    Text(detail)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(DisplayCurrency.shared.format(copier.realisedToday, signed: true))
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(pnlTint(copier.realisedToday))
                        .contentTransition(.numericText())
                    Text("Today")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .deskGlass(interactive: true, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var detail: String {
        if let problem = copier.readProblem { return problem }
        let open = "\(copier.open.count) open"
        guard let read = copier.lastRead else { return "\(open) · starting" }
        return "\(open) · updated \(read.formatted(.relative(presentation: .numeric)))"
    }
}

private func pnlTint(_ value: Double) -> Color {
    value < 0 ? DeskColor.fall.color : (value > 0 ? DeskColor.rise.color : .primary)
}

/// Everything auto-copy has done, the limits across it, and the switch that stops it.
struct CopyActivityScreen: View {
    let copier: CopyTrader
    let directory: TraderDirectory

    @State private var editing: CopiedTrader?

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(get: { !copier.isPaused }, set: { copier.setPaused(!$0) })) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(copier.isPaused ? "Paused" : "Running")
                            Text(statusLine)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: copier.isPaused ? "pause.fill" : "bolt.fill")
                            .foregroundStyle(copier.isPaused ? AnyShapeStyle(.secondary) : AnyShapeStyle(DeskColor.rise.color))
                    }
                }
            } footer: {
                Text("Reads traders on Perpl mainnet every 4 seconds and copies to your Perpl \(copier.network.shortName.lowercased()) account. Pausing stops new copies; open ones keep their stops.")
            }

            Section("Performance") {
                LabeledContent("Realised PnL") {
                    Text(DisplayCurrency.shared.format(copier.realisedTotal, signed: true))
                        .foregroundStyle(pnlTint(copier.realisedTotal))
                        .monospacedDigit()
                }
                LabeledContent("Win rate") {
                    Text(copier.winRate.map { String(format: "%.0f%% of %d", $0 * 100, copier.closedCount) } ?? "No closes yet")
                        .monospacedDigit()
                }
                LabeledContent("Copies", value: "\(copier.copiedCount) · \(copier.open.count) open")
                LabeledContent("Time to fill") {
                    Text(copier.averageFillSeconds.map { String(format: "%.1f s after their move", $0) } ?? "—")
                        .monospacedDigit()
                }
            }

            Section {
                if copier.traders.isEmpty {
                    Text("Open a trader on Signals and turn on Auto-Copy.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(copier.traders) { trader in
                        Button { editing = trader } label: { traderRow(trader) }
                            .tint(.primary)
                            .swipeActions {
                                Button("Stop", role: .destructive) { copier.stop(trader.address) }
                            }
                    }
                }
            } header: {
                Text("Copying")
            }

            Section {
                Picker("Open copies at once", selection: Binding(
                    get: { copier.guards.maxOpenCopies },
                    set: { value in var next = copier.guards; next.maxOpenCopies = value; copier.updateGuards(next) }
                )) {
                    ForEach([1, 3, 5, 10], id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("Daily loss limit", selection: Binding(
                    get: { copier.guards.dailyLossLimit },
                    set: { value in var next = copier.guards; next.dailyLossLimit = value; copier.updateGuards(next) }
                )) {
                    ForEach([25, 50, 100, 250], id: \.self) { Text("\($0) AUSD").tag($0) }
                }
            } header: {
                Text("Limits")
            } footer: {
                Text("Auto-Copy pauses itself once today's closed copies have lost this much.")
            }

            Section("Log") {
                if copier.log.isEmpty {
                    ContentUnavailableView(
                        "No Copies Yet",
                        systemImage: "bolt.horizontal",
                        description: Text("The first reading of each trader is a baseline. Copies start from their next move."))
                } else {
                    ForEach(copier.log) { entry in
                        CopyLogRow(entry: entry, name: directory.name(for: entry.trader))
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .tint(DeskColor.rise.color)
        .navigationTitle("Auto-Copy")
        .navigationBarTitleDisplayMode(.large)
        .toolbar(.visible, for: .navigationBar)
        .sheet(item: $editing) { trader in
            AutoCopySheet(address: trader.address, name: directory.name(for: trader.address), copier: copier)
        }
    }

    private var statusLine: String {
        if let problem = copier.readProblem { return problem }
        guard let read = copier.lastRead else { return copier.isPaused ? "No new copies" : "Starting" }
        return "Updated \(read.formatted(date: .omitted, time: .standard))"
    }

    private func traderRow(_ trader: CopiedTrader) -> some View {
        HStack(spacing: 12) {
            TraderAvatar(address: trader.address, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(directory.name(for: trader.address))
                    .foregroundStyle(.primary)
                Text("\(trader.rules.marginPerTrade) AUSD · up to \(trader.rules.maxLeverage)× · \(trader.rules.stopLossPercent.map { "stop −\($0)%" } ?? "no stop")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }
}

private struct CopyLogRow: View {
    let entry: CopyLogEntry
    let name: String

    private var icon: (name: String, tint: Color) {
        switch entry.kind {
        case .opened: ("arrow.up.right.circle.fill", DeskColor.rise.color)
        case .closed: ("checkmark.circle.fill", .secondary)
        case .protected: ("shield.lefthalf.filled", .blue)
        case .skipped: ("forward.circle.fill", .secondary)
        case .failed: ("exclamationmark.circle.fill", DeskColor.fall.color)
        case .paused: ("pause.circle.fill", .orange)
        }
    }

    private var title: String {
        let side = "\(entry.isLong ? "Long" : "Short") \(entry.symbol)\(entry.leverage.map { " \($0)×" } ?? "")"
        return switch entry.kind {
        case .opened: "Copied \(side)"
        case .closed: "Closed \(side)"
        case .protected: "\(side) closed on Perpl"
        case .skipped: "Skipped \(side)"
        case .failed: "Couldn't copy \(side)"
        case .paused: "Auto-Copy paused"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon.name)
                .font(.title3)
                .foregroundStyle(icon.tint)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4 }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    if let pnl = entry.pnl {
                        Text(DisplayCurrency.shared.format(pnl, signed: true))
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(pnlTint(pnl))
                    }
                }
                Text(entry.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var footnote: String {
        [name,
         entry.date.formatted(.relative(presentation: .named)),
         entry.fillSeconds.map { String(format: "filled in %.1f s", $0) }]
            .compactMap { $0 }.joined(separator: " · ")
    }
}
