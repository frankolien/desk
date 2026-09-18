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
            ? "Shadow sends nothing: each copy fills at the live mainnet price with fees, against a 1,000 AUSD paper balance, and is liquidated where the venue would liquidate it."
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

/// Auto-copy in one glance: the result, the switch, who is being copied and what just
/// happened. Limits and the Live Activity live behind the settings button.
struct CopyActivityScreen: View {
    let copier: CopyTrader
    let directory: TraderDirectory

    @State private var editing: CopiedTrader?
    @State private var showsBasket = false
    @State private var showsSettings = false
    @State private var showsShadow = true

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

            summary

            GlassSection("Copying") {
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
                Button { showsBasket = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DeskColor.action.color)
                            .frame(width: 30, height: 30)
                            .background(DeskColor.action.color.opacity(0.16), in: Circle())
                        VStack(alignment: .leading, spacing: 1) {
                            Text(copier.basket.map { "Top \($0.size) Basket" } ?? "Copy the Top Traders")
                            Text(basketLine).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        chevron
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if !openCopies.isEmpty {
                GlassSection("Open") {
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

            GlassSection("Recent") {
                if entries.isEmpty {
                    Text("Copies show up here from your traders' next move.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(entries.prefix(4)) { entry in
                        CopyLogRow(entry: entry, name: name(for: entry), compact: true)
                    }
                    if entries.count > 4 {
                        NavigationLink {
                            CopyLogScreen(entries: entries, shadow: showsShadow, name: name(for:))
                        } label: {
                            HStack {
                                Text("See All")
                                Spacer()
                                Text("\(entries.count)").foregroundStyle(.secondary).monospacedDigit()
                                chevron
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .tint(DeskColor.rise.color)
        .navigationTitle("Auto-Copy")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Settings", systemImage: "slider.horizontal.3") { showsSettings = true }
            }
        }
        .sheet(item: $editing) { trader in
            AutoCopySheet(address: trader.address, name: directory.name(for: trader.address), copier: copier)
        }
        .sheet(isPresented: $showsBasket) { CopyBasketSheet(copier: copier) }
        .sheet(isPresented: $showsSettings) { CopySettingsSheet(copier: copier) }
        #if DEBUG
        .task { if ProcessInfo.processInfo.arguments.contains("-copy-settings") { showsSettings = true } }
        #endif
    }

    // MARK: - Summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusTint)
                    .frame(width: 7, height: 7)
                Text(statusText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusTint)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(.black.opacity(0.35), in: Capsule())

            VStack(alignment: .leading, spacing: 2) {
                Text(DisplayCurrency.shared.format(figures.realised, signed: true))
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(pnlTint(figures.realised))
                    .contentTransition(.numericText(value: figures.realised))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text(showsShadow ? "Shadow result · no money moved" : "Live result on Perpl \(copier.network.shortName.lowercased())")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.62))
            }

            HStack(spacing: 22) {
                stat(figures.winRate.map { String(format: "%.0f%%", $0 * 100) } ?? "—", "Win rate")
                stat("\(figures.copies)", "Copies")
                stat(figures.averageFillSeconds.map { String(format: "%.1fs", $0) } ?? "—", "To fill")
            }
            .padding(.top, 2)

            Button { copier.setPaused(!copier.isPaused) } label: {
                Label(copier.isPaused ? "Resume" : "Pause", systemImage: copier.isPaused ? "play.fill" : "pause.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(copier.isPaused ? DeskColor.onAction.color : .white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
            }
            .controlSize(.large)
            .modifier(PauseButtonStyle(isPaused: copier.isPaused))
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The share card's artwork, so the result reads like the card it can become: its D
        // sits on the right, and the text keeps the dark side.
        .background {
            GeometryReader { proxy in
                ZStack(alignment: .topTrailing) {
                    DeskColor.night.color
                    Image("TradeShareCardBackground")
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width * 0.95, height: proxy.size.width * 0.95 * 1402 / 1122)
                        .offset(x: proxy.size.width * 0.06, y: -proxy.size.width * 0.05)
                    LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0),
                                           .init(color: .black.opacity(0.1), location: 0.6),
                                           .init(color: .clear, location: 1)],
                                   startPoint: .leading, endPoint: .trailing)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topTrailing)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(DeskColor.action.color.opacity(0.28), lineWidth: 0.8)
        }
    }

    private var isLive: Bool { !copier.isPaused && copier.readProblem == nil && !copier.traders.isEmpty }

    private var statusText: String {
        if copier.isPaused { return "Paused" }
        if copier.readProblem != nil { return "Reconnecting" }
        if copier.traders.isEmpty { return "Nobody to copy yet" }
        return copier.isStreaming ? "Copying live" : "Copying"
    }

    private var statusTint: Color {
        if copier.isPaused || copier.readProblem != nil { return DeskColor.action.color }
        return copier.traders.isEmpty ? .secondary : DeskColor.rise.color
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.headline.monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    // MARK: - Rows

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
    }

    private var basketLine: String {
        guard let basket = copier.basket else { return "The leaderboard's best, re-picked for you" }
        let every = basket.rotateHours == 168 ? "week" : "\(basket.rotateHours)h"
        return "\(basket.rules.mode == .shadow ? "Shadow" : "Live") · re-picked every \(every)"
    }

    private func name(for entry: CopyLogEntry) -> String {
        entry.trader.isEmpty ? "Auto-Copy" : directory.name(for: entry.trader)
    }

    private func traderRow(_ trader: CopiedTrader) -> some View {
        let record = copier.record(for: trader.address)
        let result = trader.rules.mode == .shadow ? record.shadow : record.live
        return HStack(spacing: 10) {
            TraderAvatar(address: trader.address, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(directory.name(for: trader.address)).lineLimit(1)
                Text("\(trader.rules.mode == .shadow ? "Shadow" : "Live")\(trader.rules.direction == .fade ? " · Fade" : "") · \(trader.rules.marginPerTrade) AUSD · \(trader.rules.maxLeverage)×")
                    .font(.caption)
                    .foregroundStyle(trader.rules.mode == .shadow ? AnyShapeStyle(.secondary) : AnyShapeStyle(DeskColor.rise.color))
            }
            Spacer(minLength: 8)
            if record.trades > 0 {
                Text(DisplayCurrency.shared.format(result, signed: true))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(pnlTint(result))
            }
            chevron
        }
        .contentShape(Rectangle())
    }
}

private struct PauseButtonStyle: ViewModifier {
    let isPaused: Bool

    func body(content: Content) -> some View {
        if isPaused {
            content.deskProminentButton()
        } else {
            content.deskSecondaryButton()
        }
    }
}

/// Limits and the Live Activity, out of the way of the result.
struct CopySettingsSheet: View {
    let copier: CopyTrader

    @Environment(\.dismiss) private var dismiss
    @AppStorage(AutoCopyPublisher.liveActivityKey) private var showsLiveActivity = true

    var body: some View {
        NavigationStack {
            GlassPage {
                GlassSection("Limits", footer: "Auto-Copy pauses itself if today's copies lose the daily limit.") {
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
                    GlassRow("Max per market") {
                        Picker("Max per market", selection: guardBinding(\.maxMarketExposure)) {
                            ForEach([100, 250, 500, 1000], id: \.self) { Text("\($0) AUSD").tag($0) }
                        }
                        .labelsHidden()
                    }
                }

                GlassSection(footer: "Traders are read on Perpl mainnet the moment they trade. Copying runs while Desk is open.") {
                    Toggle(isOn: $showsLiveActivity) {
                        GlassRow("Live Activity", subtitle: "Lock Screen and Dynamic Island") { EmptyView() }
                    }
                }
            }
            .tint(DeskColor.rise.color)
            .navigationTitle("Auto-Copy Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func guardBinding(_ keyPath: WritableKeyPath<CopyGuards, Int>) -> Binding<Int> {
        Binding(get: { copier.guards[keyPath: keyPath] },
                set: { value in
                    var next = copier.guards
                    next[keyPath: keyPath] = value
                    copier.updateGuards(next)
                })
    }
}

/// Every copy, skip and close, with the detail the summary leaves out.
struct CopyLogScreen: View {
    let entries: [CopyLogEntry]
    let shadow: Bool
    let name: (CopyLogEntry) -> String

    var body: some View {
        GlassPage {
            GlassSection {
                ForEach(entries.prefix(200)) { entry in
                    CopyLogRow(entry: entry, name: name(entry), compact: false)
                }
            }
        }
        .navigationTitle(shadow ? "Shadow Activity" : "Live Activity")
        .navigationBarTitleDisplayMode(.inline)
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
                Text("\(name) · \(copy.openedAt.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))")
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
    var compact = false

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
        case .paused: entry.detail.hasPrefix("Basket") ? "Basket updated"
            : (entry.detail.contains("resumed") ? "Auto-Copy resumed" : "Auto-Copy paused")
        }
    }

    var body: some View {
        if compact { compactBody } else { fullBody }
    }

    private var compactBody: some View {
        HStack(spacing: 10) {
            Image(systemName: icon.name)
                .font(.body)
                .foregroundStyle(icon.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                Text("\(name) · \(entry.date.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let pnl = entry.pnl {
                Text(DisplayCurrency.shared.format(pnl, signed: true))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(pnlTint(pnl))
            }
        }
    }

    private var fullBody: some View {
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
         entry.slippageBps.map { String(format: "%+d bps vs mark", $0) }]
            .compactMap { $0 }.joined(separator: " · ")
    }
}
