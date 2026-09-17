import DeskFlow
import DeskUI
import SwiftUI

/// The rule sections shared by copying one trader and copying a basket.
private struct CopyRulesSections: View {
    @Binding var rules: CopyRules
    let network: DeskNetwork

    private var stopLoss: Binding<Bool> {
        Binding(get: { rules.stopLossPercent != nil }, set: { rules.stopLossPercent = $0 ? 25 : nil })
    }

    private var takeProfit: Binding<Bool> {
        Binding(get: { rules.takeProfitPercent != nil }, set: { rules.takeProfitPercent = $0 ? 50 : nil })
    }

    var body: some View {
        GlassSection("Strategy", footer: strategyFooter) {
            GlassRow("Mode") {
                Picker("Mode", selection: $rules.mode.animation()) {
                    Text("Shadow").tag(CopyMode.shadow)
                    Text("Live").tag(CopyMode.live)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            GlassRow("Direction") {
                Picker("Direction", selection: $rules.direction.animation()) {
                    Text("Follow").tag(CopyDirection.follow)
                    Text("Fade").tag(CopyDirection.fade)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            GlassRow("Sizing") {
                Picker("Sizing", selection: $rules.sizing.animation()) {
                    Text("Fixed").tag(CopySizing.fixed)
                    Text("Conviction").tag(CopySizing.conviction)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }

        GlassSection("Size", footer: sizeFooter) {
            GlassRow(rules.sizing == .conviction ? "Base margin" : "Margin per trade") {
                Picker("Margin per trade", selection: $rules.marginPerTrade) {
                    ForEach([5, 10, 25, 50, 100, 250], id: \.self) { Text("\($0) AUSD").tag($0) }
                }
                .labelsHidden()
            }
            GlassRow("Leverage cap") {
                Text("\(rules.maxLeverage)×")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Stepper("Leverage cap", value: $rules.maxLeverage.animation(), in: 1...20)
                    .labelsHidden()
            }
            GlassRow("Largest position",
                     value: "\(rules.marginPerTrade * rules.maxLeverage * (rules.sizing == .conviction ? 2 : 1)) AUSD")
        }

        GlassSection("Protection", footer: protectionFooter) {
            Toggle("Stop loss", isOn: stopLoss.animation())
            if let stop = rules.stopLossPercent {
                GlassRow("Loss of margin") {
                    Picker("Stop loss", selection: Binding(get: { stop }, set: { rules.stopLossPercent = $0 })) {
                        ForEach([10, 15, 25, 35, 50], id: \.self) { Text("−\($0)%").tag($0) }
                    }
                    .labelsHidden()
                }
            }
            Toggle("Take profit", isOn: takeProfit.animation())
            if let take = rules.takeProfitPercent {
                GlassRow("Gain on margin") {
                    Picker("Take profit", selection: Binding(get: { take }, set: { rules.takeProfitPercent = $0 })) {
                        ForEach([25, 50, 100, 200], id: \.self) { Text("+\($0)%").tag($0) }
                    }
                    .labelsHidden()
                }
            }
        }

        GlassSection("Execution", footer: "Price-protected: an order can never fill further than this from their entry, and a copy is skipped if the market is already past it.") {
            Toggle("Close when they close", isOn: $rules.closeWithTrader)
            GlassRow("Max from their entry") {
                Picker("Max from their entry", selection: $rules.maxChaseBps) {
                    ForEach([25, 50, 100, 200], id: \.self) { Text(String(format: "%.2g%%", Double($0) / 100)).tag($0) }
                }
                .labelsHidden()
            }
        }

        if rules.mode == .live && network.holdsRealFunds {
            GlassSection {
                Label("Live copies on mainnet use real AUSD.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var strategyFooter: String {
        let mode = rules.mode == .shadow
            ? "Shadow sends nothing: each copy fills at the live mainnet price with fees, so you see what it would have made."
            : "Live sends real orders to your Perpl \(network.shortName.lowercased()) account, signed on this iPhone."
        let direction = rules.direction == .fade ? " Fade takes the opposite side of every trade they make." : ""
        return mode + direction
    }

    private var sizeFooter: String {
        rules.sizing == .conviction
            ? "Conviction scales the base margin by how much of their own account they put in: a tenth is 1×, half is 2×, a sliver is 0.5×."
            : "Their size fits their account, not yours. Each copy uses your margin at their leverage, up to your cap."
    }

    private var protectionFooter: String {
        guard let stop = rules.stopLossPercent else {
            return "Without a stop, a copy stays open until they close or you do."
        }
        let move = Double(stop) / Double(rules.maxLeverage)
        return String(format: "At %d×, a −%d%% stop is a %.1f%% price move against you. Live stops are placed on Perpl, so they hold after Desk closes.",
                      rules.maxLeverage, stop, move)
    }
}

private struct PrimaryBarButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            action()
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
        }
        .controlSize(.large)
        .deskProminentButton()
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }
}

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
        NavigationStack {
            GlassPage {
                GlassSection {
                    HStack(spacing: 12) {
                        TraderAvatar(address: address, size: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name).font(.headline).lineLimit(1)
                            Text(recordLine).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                CopyRulesSections(rules: $rules, network: copier.network)
                if isActive {
                    GlassSection {
                        Button("Stop Copying", role: .destructive) { confirmsStop = true }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .tint(DeskColor.rise.color)
            .navigationTitle(isActive ? "Copy Rules" : "Auto-Copy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                PrimaryBarButton(title: isActive ? "Save Rules" : (rules.mode == .shadow ? "Start Shadow Copy" : "Start Copying")) {
                    copier.start(address, rules: rules)
                    dismiss()
                }
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

    private var recordLine: String {
        let record = copier.record(for: address)
        guard record.trades > 0 else { return "Try Shadow first: no money moves until you go live." }
        let shadow = DisplayCurrency.shared.format(record.shadow, signed: true)
        let live = DisplayCurrency.shared.format(record.live, signed: true)
        return "Copying so far: \(live) live · \(shadow) shadow"
    }
}

/// Copy the leaderboard's top traders as one portfolio, re-picked on a schedule.
struct CopyBasketSheet: View {
    let copier: CopyTrader

    @Environment(\.dismiss) private var dismiss
    @State private var rules: CopyRules
    @State private var size: Int
    @State private var rotateHours: Int

    init(copier: CopyTrader) {
        self.copier = copier
        _rules = State(initialValue: copier.basket?.rules ?? CopyRules(marginPerTrade: 5, maxLeverage: 3))
        _size = State(initialValue: copier.basket?.size ?? 5)
        _rotateHours = State(initialValue: copier.basket?.rotateHours ?? 24)
    }

    var body: some View {
        NavigationStack {
            GlassPage {
                GlassSection("Basket", footer: "Desk copies the top traders on Perpl's leaderboard who are in the market, and re-picks them on this schedule. Traders who drop out stop being copied; their open copies keep their stops.") {
                    GlassRow("Traders") {
                        Picker("Traders", selection: $size) {
                            ForEach([3, 5, 10], id: \.self) { Text("Top \($0)").tag($0) }
                        }
                        .labelsHidden()
                    }
                    GlassRow("Re-pick every") {
                        Picker("Re-pick every", selection: $rotateHours) {
                            Text("6 hours").tag(6)
                            Text("Day").tag(24)
                            Text("Week").tag(168)
                        }
                        .labelsHidden()
                    }
                }
                CopyRulesSections(rules: $rules, network: copier.network)
                if copier.basket != nil {
                    GlassSection {
                        Button("Stop Basket", role: .destructive) {
                            copier.stopBasket()
                            dismiss()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .tint(DeskColor.rise.color)
            .navigationTitle("Copy a Basket")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                PrimaryBarButton(title: copier.basket == nil ? "Start Basket" : "Save Basket") {
                    copier.startBasket(size: size, rules: rules, rotateHours: rotateHours)
                    dismiss()
                }
            }
        }
    }
}

/// Starts auto-copy from a trader's profile, or shows it is running.
struct AutoCopyButton: View {
    let rules: CopyRules?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: rules == nil ? "bolt.fill" : (rules?.mode == .shadow ? "eye.circle.fill" : "bolt.circle.fill"))
                    .font(.body)
                    .foregroundStyle(rules == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(DeskColor.rise.color))
                    .symbolEffect(.pulse, options: .repeating, isActive: rules != nil)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .deskGlass(interactive: true, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var title: String {
        guard let rules else { return "Auto-Copy" }
        return rules.mode == .shadow ? "Shadow-Copying" : (rules.direction == .fade ? "Fading" : "Auto-Copying")
    }

    private var summary: String {
        guard let rules else { return "Shadow or live, follow or fade, with your own limits" }
        var parts = ["\(rules.marginPerTrade) AUSD", "up to \(rules.maxLeverage)×"]
        if rules.sizing == .conviction { parts.append("conviction") }
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
                    .font(.system(size: 24))
                    .foregroundStyle(copier.isPaused ? AnyShapeStyle(.secondary) : AnyShapeStyle(DeskColor.rise.color))
                    .symbolEffect(.pulse, options: .repeating, isActive: !copier.isPaused && copier.readProblem == nil)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline).font(.subheadline.weight(.semibold))
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
                    Text("Today").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .deskGlass(interactive: true, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var headline: String {
        if copier.isPaused { return "Auto-Copy Paused" }
        let count = copier.traders.count
        return "Copying \(count) \(count == 1 ? "Trader" : "Traders")" + (copier.basket != nil ? " · Basket" : "")
    }

    private var detail: String {
        if let problem = copier.readProblem { return problem }
        return "\(copier.open.count) open · \(copier.isStreaming ? "live from the chain" : "checking every few seconds")"
    }
}

private func pnlTint(_ value: Double) -> Color {
    value < 0 ? DeskColor.fall.color : (value > 0 ? DeskColor.rise.color : .primary)
}

/// Everything auto-copy has done, split into shadow and live, with the limits across it
/// and the switch that stops it.
struct CopyActivityScreen: View {
    let copier: CopyTrader
    let directory: TraderDirectory

    @State private var editing: CopiedTrader?
    @State private var showsBasket = false
    @State private var showsShadow = true
    @AppStorage(AutoCopyPublisher.liveActivityKey) private var showsLiveActivity = true

    private var figures: CopyTrader.Figures { copier.figures(shadow: showsShadow) }
    private var openCopies: [OpenCopy] { copier.open.filter { $0.shadowed == showsShadow } }
    private var entries: [CopyLogEntry] { copier.log.filter { $0.shadowed == showsShadow } }

    var body: some View {
        GlassPage {
            Picker("Results", selection: $showsShadow.animation(.snappy(duration: 0.2))) {
                Text("Shadow").tag(true)
                Text("Live").tag(false)
            }
            .pickerStyle(.segmented)

            GlassSection(footer: "Reads traders on Perpl mainnet the moment they trade. Live copies go to your Perpl \(copier.network.shortName.lowercased()) account; shadow copies send nothing. Pausing stops new copies.") {
                Toggle(isOn: Binding(get: { !copier.isPaused }, set: { copier.setPaused(!$0) })) {
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(copier.isPaused ? "Paused" : "Running")
                            Text(copier.readProblem ?? (copier.isStreaming ? "Live from the chain" : "Checking every 4 seconds"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: copier.isStreaming ? "dot.radiowaves.left.and.right" : "bolt.fill")
                            .foregroundStyle(copier.isPaused ? AnyShapeStyle(.secondary) : AnyShapeStyle(DeskColor.rise.color))
                            .symbolEffect(.variableColor.iterative, options: .repeating, isActive: copier.isStreaming && !copier.isPaused)
                    }
                }
                Toggle(isOn: $showsLiveActivity) {
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Live Activity")
                            Text("Lock Screen and Dynamic Island")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "platter.filled.top.iphone")
                            .foregroundStyle(DeskColor.action.color)
                    }
                }
            }

            GlassSection(showsShadow ? "Shadow Performance" : "Live Performance",
                         footer: showsShadow ? "Simulated at the mainnet mark with slippage and taker fees both ways. Nothing was sent." : nil) {
                GlassRow("Realised PnL") {
                    Text(DisplayCurrency.shared.format(figures.realised, signed: true))
                        .foregroundStyle(pnlTint(figures.realised))
                        .monospacedDigit()
                }
                GlassRow("Win rate", value: figures.winRate.map { String(format: "%.0f%% of %d", $0 * 100, figures.closed) } ?? "No closes yet")
                GlassRow("Copies", value: "\(figures.copies) · \(openCopies.count) open")
                GlassRow("Time to fill", value: figures.averageFillSeconds.map { String(format: "%.1f s after their move", $0) } ?? "—")
                GlassRow("Vs their entry", value: figures.averageSlippageBps.map { String(format: "%+.1f bps avg", $0) } ?? "—")
            }

            if !openCopies.isEmpty {
                GlassSection("Open Copies") {
                    ForEach(openCopies) { copy in
                        OpenCopyRow(copy: copy, name: directory.name(for: copy.trader),
                                    pnl: copy.shadowPnL(takerFeeMicros: copier.takerFee(for: copy.symbol)))
                            .contextMenu {
                                if copy.shadowed {
                                    Button("Close Shadow Copy", systemImage: "xmark.circle") { copier.closeShadow(copy) }
                                }
                            }
                    }
                }
            }

            GlassSection("Copying", footer: copier.traders.isEmpty ? nil : "Touch and hold a trader to go live, edit or stop.") {
                if copier.traders.isEmpty {
                    Text("Open a trader on Signals and turn on Auto-Copy, or copy a basket below.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(copier.traders) { trader in
                        Button { editing = trader } label: { traderRow(trader) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                if trader.rules.mode == .shadow {
                                    Button("Go Live", systemImage: "bolt.fill") { copier.setMode(.live, for: trader.address) }
                                } else {
                                    Button("Back to Shadow", systemImage: "eye") { copier.setMode(.shadow, for: trader.address) }
                                }
                                Button("Edit Rules", systemImage: "slider.horizontal.3") { editing = trader }
                                Button("Stop Copying", systemImage: "stop.circle", role: .destructive) { copier.stop(trader.address) }
                            }
                    }
                }
            }

            GlassSection("Basket") {
                Button { showsBasket = true } label: {
                    GlassRow(copier.basket.map { "Top \($0.size) traders" } ?? "Copy a basket",
                             subtitle: basketLine) {
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            GlassSection("Limits", footer: "Auto-Copy pauses itself once today's closed copies have lost the daily limit. Exposure caps what copies hold on one side of one market, so two traders long BTC don't double your risk.") {
                GlassRow("Open copies at once") {
                    Picker("Open copies at once", selection: guardBinding(\.maxOpenCopies)) {
                        ForEach([1, 3, 5, 10], id: \.self) { Text("\($0)").tag($0) }
                    }
                    .labelsHidden()
                }
                GlassRow("Daily loss limit") {
                    Picker("Daily loss limit", selection: guardBinding(\.dailyLossLimit)) {
                        ForEach([25, 50, 100, 250], id: \.self) { Text("\($0) AUSD").tag($0) }
                    }
                    .labelsHidden()
                }
                GlassRow("Exposure per market") {
                    Picker("Exposure per market", selection: guardBinding(\.maxMarketExposure)) {
                        ForEach([100, 250, 500, 1000], id: \.self) { Text("\($0) AUSD").tag($0) }
                    }
                    .labelsHidden()
                }
            }

            GlassSection("Log") {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "No Copies Yet",
                        systemImage: "bolt.horizontal",
                        description: Text("The first reading of each trader is a baseline. Copies start from their next move."))
                } else {
                    ForEach(entries.prefix(100)) { entry in
                        CopyLogRow(entry: entry, name: entry.trader.isEmpty ? "Basket" : directory.name(for: entry.trader))
                    }
                }
            }
        }
        .tint(DeskColor.rise.color)
        .navigationTitle("Auto-Copy")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .sheet(item: $editing) { trader in
            AutoCopySheet(address: trader.address, name: directory.name(for: trader.address), copier: copier)
        }
        .sheet(isPresented: $showsBasket) { CopyBasketSheet(copier: copier) }
    }

    private var basketLine: String {
        guard let basket = copier.basket else { return "The leaderboard's best as one portfolio" }
        let every = basket.rotateHours == 168 ? "week" : "\(basket.rotateHours)h"
        return "\(basket.rules.mode == .shadow ? "Shadow" : "Live") · re-picked every \(every)"
    }

    private func guardBinding(_ keyPath: WritableKeyPath<CopyGuards, Int>) -> Binding<Int> {
        Binding(get: { copier.guards[keyPath: keyPath] },
                set: { value in
                    var next = copier.guards
                    next[keyPath: keyPath] = value
                    copier.updateGuards(next)
                })
    }

    private func traderRow(_ trader: CopiedTrader) -> some View {
        HStack(spacing: 10) {
            TraderAvatar(address: trader.address, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(directory.name(for: trader.address)).foregroundStyle(.primary)
                    Text(trader.rules.mode == .shadow ? "SHADOW" : "LIVE")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(trader.rules.mode == .shadow ? Color.secondary : DeskColor.rise.color)
                    if trader.isFromBasket {
                        Image(systemName: "square.stack.3d.up.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text("\(trader.rules.direction == .fade ? "Fade · " : "")\(trader.rules.marginPerTrade) AUSD · up to \(trader.rules.maxLeverage)×\(trader.rules.sizing == .conviction ? " · conviction" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

private struct OpenCopyRow: View {
    let copy: OpenCopy
    let name: String
    let pnl: Double?

    var body: some View {
        HStack(spacing: 10) {
            MarketTokenLogo(symbol: copy.symbol, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(copy.isLong ? "Long" : "Short") \(copy.symbol) \(copy.leverage)×").fontWeight(.medium)
                Text("\(name) · \(String(format: "%.2f", copy.margin)) AUSD · \(copy.openedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let pnl {
                Text(DisplayCurrency.shared.format(pnl, signed: true))
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(pnlTint(pnl))
                    .contentTransition(.numericText())
            } else {
                Text("On Perpl").font(.caption).foregroundStyle(.secondary)
            }
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
        case .paused: ("info.circle.fill", .orange)
        }
    }

    private var title: String {
        let side = "\(entry.isLong ? "Long" : "Short") \(entry.symbol)\(entry.leverage.map { " \($0)×" } ?? "")"
        return switch entry.kind {
        case .opened: "Copied \(side)"
        case .closed: "Closed \(side)"
        case .protected: "\(side) closed by its trigger"
        case .skipped: "Skipped \(side)"
        case .failed: "Couldn't copy \(side)"
        case .paused: entry.symbol.isEmpty ? "Basket updated" : "Auto-Copy paused"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon.name)
                .font(.body)
                .foregroundStyle(icon.tint)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4 }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.footnote.weight(.semibold))
                    Spacer(minLength: 8)
                    if let pnl = entry.pnl {
                        Text(DisplayCurrency.shared.format(pnl, signed: true))
                            .font(.footnote.weight(.semibold).monospacedDigit())
                            .foregroundStyle(pnlTint(pnl))
                    }
                }
                Text(entry.detail).font(.caption2).foregroundStyle(.secondary)
                Text(footnote).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var footnote: String {
        [name,
         entry.date.formatted(.relative(presentation: .named)),
         entry.fillSeconds.map { String(format: "%.1f s after their move", $0) },
         entry.slippageBps.map { String(format: "%+d bps vs their entry", $0) }]
            .compactMap { $0 }.joined(separator: " · ")
    }
}
