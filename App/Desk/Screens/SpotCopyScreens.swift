import DeskAuth
import DeskFlow
import DeskUI
import SwiftUI

/// The wallet profile's spot Auto-Copy row: copy this wallet's token buys and sells from Desk's
/// server, or, once copying, what it spends a buy.
struct SpotCopyButton: View {
    let rules: SpotCopyProtocol.Rules?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: rules == nil ? "arrow.triangle.2.circlepath" : "arrow.triangle.2.circlepath.circle.fill")
                    .font(.body)
                    .foregroundStyle(rules == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(DeskColor.rise.color))
                    .symbolEffect(.pulse, options: .repeating, isActive: rules != nil)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(rules == nil ? "Auto-Copy Trades" : "Auto-Copying Trades").font(.subheadline.weight(.semibold))
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .deskGlass(interactive: true, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var summary: String {
        guard let rules else { return "Their token buys and sells, from your wallet, while your phone sleeps" }
        var parts = [rules.sizing == .fixed ? "\(Int(rules.amount)) AUSD a buy" : "Their size, up to \(Int(rules.maxPerBuy)) AUSD"]
        parts.append(rules.copySells ? "sells with them" : "buys only")
        return parts.joined(separator: " · ")
    }
}

/// Copying one wallet's token trades: its rules, and the first time, the limits the wallet signs.
struct SpotCopySheet: View {
    let model: AppModel
    let leader: String
    let name: String

    @Environment(\.dismiss) private var dismiss
    @State private var spot = SpotCopier.shared
    @State private var rules: SpotCopyProtocol.Rules
    @State private var limits = SpotCopyProtocol.Limits(perTrade: 25, perDay: 100)
    @State private var days = 30
    @State private var isWorking = false
    @State private var problem: String?
    @State private var confirmsStop = false
    @State private var showsActivity = false

    init(model: AppModel, leader: String, name: String) {
        self.model = model
        self.leader = leader
        self.name = name
        _rules = State(initialValue: SpotCopier.shared.rules(for: leader) ?? SpotCopyProtocol.Rules())
    }

    private var isOn: Bool { spot.isOn && spot.stage != "off" }
    private var copiesThem: Bool { spot.rules(for: leader) != nil }
    private var perTradeCap: Int { isOn ? (spot.limits?.perTrade ?? limits.perTrade) : limits.perTrade }

    var body: some View {
        NavigationStack {
            GlassPage {
                GlassSection {
                    HStack(spacing: 12) {
                        TraderAvatar(address: leader, size: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name).font(.headline).lineLimit(1)
                            Text("Copies their token trades on Monad, paid in AUSD").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                if !isOn {
                    GlassSection {
                        point("moon.zzz.fill", "Copies while your phone sleeps", "Desk's server sees their trade and copies it within seconds, day and night.")
                        point("lock.shield.fill", "Your wallet, your keys", "Desk's key can only swap AUSD for what they buy, and back, through 0x. It can't withdraw, and it never touches your other tokens.")
                        point("checkmark.seal.fill", "Limits on-chain", "Face ID signs the limits below into your wallet. Nothing, Desk included, can spend past them.")
                        point("xmark.circle", "Ends on its own", "It stops by itself after the time you pick, or the moment you turn it off.")
                    }
                }

                GlassSection("Each buy") {
                    Picker("Size", selection: $rules.sizing) {
                        Text("Fixed").tag(SpotCopyProtocol.Rules.Sizing.fixed)
                        Text("Match theirs").tag(SpotCopyProtocol.Rules.Sizing.match)
                    }
                    .pickerStyle(.segmented)
                    if rules.sizing == .fixed {
                        amountStepper("Spend", value: $rules.amount, range: 1...Double(perTradeCap))
                    } else {
                        amountStepper("Up to", value: $rules.maxPerBuy, range: 1...Double(perTradeCap))
                    }
                    Toggle("Sell when they sell", isOn: $rules.copySells)
                    Toggle("Buy each token once", isOn: $rules.buyOnce)
                }

                GlassSection("Skip", footer: "Small buys are often noise; huge ones can be bait for copiers.") {
                    Stepper(value: $rules.minLeaderUsd, in: 0...10_000, step: rules.minLeaderUsd < 100 ? 25 : 250) {
                        row("Their buys under", rules.minLeaderUsd == 0 ? "Copy all" : "$\(Int(rules.minLeaderUsd))")
                    }
                    Toggle("Skip their buys over $50K", isOn: Binding(get: { rules.maxLeaderUsd != nil }, set: { rules.maxLeaderUsd = $0 ? 50_000 : nil }))
                    GlassRow("Slippage") {
                        Picker("Slippage", selection: $rules.slippageBps) {
                            ForEach([100, 300, 500, 1000], id: \.self) { Text("\($0 / 100)%").tag($0) }
                        }
                        .labelsHidden()
                    }
                }

                if !isOn {
                    GlassSection("Limits you sign", footer: "For every wallet you copy together. Changing them later needs Face ID again.") {
                        Stepper(value: $limits.perTrade, in: 5...5_000, step: limits.perTrade < 50 ? 5 : 25) { row("Most per buy", "\(limits.perTrade) AUSD") }
                        Stepper(value: $limits.perDay, in: max(limits.perTrade, 10)...50_000, step: limits.perDay < 200 ? 10 : 100) { row("Most per day", "\(limits.perDay) AUSD") }
                        GlassRow("Runs for") {
                            Picker("Runs for", selection: $days) {
                                Text("7 days").tag(7)
                                Text("30 days").tag(30)
                                Text("90 days").tag(90)
                            }
                            .labelsHidden()
                        }
                    }
                } else if let limits = spot.limits {
                    GlassSection {
                        Button { showsActivity = true } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Activity and limits").font(.subheadline.weight(.semibold))
                                    Text(limitsLine(limits)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text(footnote).font(.footnote).foregroundStyle(.secondary)
                if let problem { Text(problem).font(.footnote).foregroundStyle(DeskColor.fall.color) }

                if copiesThem {
                    GlassSection {
                        Button("Stop Copying \(name)", role: .destructive) { confirmsStop = true }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .tint(DeskColor.rise.color)
            .navigationTitle(copiesThem ? "Copy Rules" : "Auto-Copy Trades")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .safeAreaInset(edge: .bottom) { primary.padding(.horizontal, 20).padding(.bottom, 8) }
            .navigationDestination(isPresented: $showsActivity) { SpotCopyActivityScreen(model: model) }
            .confirmationDialog("Stop copying \(name)?", isPresented: $confirmsStop, titleVisibility: .visible) {
                Button("Stop Copying", role: .destructive) { Task { await save(nil) } }
            } message: {
                Text("What the copies bought stays in your wallet.")
            }
        }
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isWorking)
        .task {
            spot.bind(address: model.address?.checksummed)
            await spot.refresh()
            if let saved = spot.rules(for: leader) { rules = saved }
            if !isOn, spot.feeBps == nil, let wallet = model.address?.checksummed { _ = try? await spot.prepare(wallet: wallet) }
        }
    }

    @ViewBuilder private var primary: some View {
        Button {
            Task { isOn ? await save(rules) : await turnOn() }
        } label: {
            HStack(spacing: 8) {
                if isWorking { ProgressView().tint(DeskColor.onAction.color) }
                if isOn { Text(copiesThem ? "Save Rules" : "Start Copying") } else { Label("Turn On with Face ID", systemImage: "faceid") }
            }
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .deskProminentButton()
        .disabled(isWorking || model.address == nil || !model.network.holdsRealFunds)
    }

    private var footnote: String {
        var parts: [String] = []
        if let bps = spot.feeBps, bps > 0 {
            let percent = Double(bps) / 100
            parts.append("Desk takes \(percent.formatted(.number.precision(.fractionLength(0...2))))% of each copied trade, in AUSD, and pays the network fees.")
        } else {
            parts.append("Desk pays the network fees for every copy.")
        }
        if !isOn { parts.append("While it's on, your wallet keeps 10 MON back whenever you send MON: Monad's rule for smart wallets.") }
        if !model.network.holdsRealFunds { parts.append("Switch to mainnet: token copies are real trades.") }
        return parts.joined(separator: " ")
    }

    private func limitsLine(_ limits: SpotCopyProtocol.Limits) -> String {
        var parts = ["Up to \(limits.perTrade) AUSD a buy", "\(limits.perDay) a day"]
        if let left = spot.remainingToday { parts.append("\(Int(left)) left today") }
        return parts.joined(separator: " · ")
    }

    private func turnOn() async {
        isWorking = true
        problem = nil
        defer { isWorking = false }
        do {
            var rules = rules
            rules.maxPerBuy = min(rules.maxPerBuy, Double(limits.perTrade))
            rules.amount = min(rules.amount, Double(limits.perTrade))
            try await spot.enable(model: model, limits: limits, days: days, leader: leader, name: name, rules: rules)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
        } catch PasskeyFailure.cancelledByUser {
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private func save(_ rules: SpotCopyProtocol.Rules?) async {
        isWorking = true
        problem = nil
        defer { isWorking = false }
        do {
            try await spot.setRules(rules, for: leader, name: name)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }

    private func amountStepper(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        Stepper(value: value, in: range, step: value.wrappedValue < 50 ? 5 : 25) {
            row(title, "\(Int(value.wrappedValue)) AUSD")
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private func point(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DeskColor.rise.color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

/// What spot Auto-Copy has done and holds, and the switches that need Face ID.
struct SpotCopyActivityScreen: View {
    let model: AppModel

    @State private var spot = SpotCopier.shared
    @State private var limits = SpotCopyProtocol.Limits(perTrade: 25, perDay: 100)
    @State private var days = 30
    @State private var editsLimits = false
    @State private var confirmsOff = false
    @State private var isWorking = false
    @State private var problem: String?

    var body: some View {
        GlassPage {
            GlassSection(footer: statusFooter) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusTitle).font(.headline)
                        if let current = spot.limits {
                            Text("Up to \(current.perTrade) AUSD a buy · \(current.perDay) a day").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if spot.stage == "live" {
                        Button(spot.isPaused ? "Resume" : "Pause") { Task { await spot.setPaused(!spot.isPaused) } }
                            .buttonStyle(.bordered)
                    }
                }
            }

            if !spot.positions.isEmpty {
                GlassSection("Held by copies") {
                    ForEach(spot.positions) { position in
                        HStack {
                            Text(position.symbol ?? String(position.token.prefix(8))).font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("Sells with the trader").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            GlassSection("Copying") {
                if spot.leaders.isEmpty {
                    Text("Nobody yet. Open a wallet you follow and tap Auto-Copy Trades.").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(spot.leaders.keys.sorted(), id: \.self) { address in
                    let entry = spot.leaders[address]
                    HStack(spacing: 10) {
                        TraderAvatar(address: address, size: 26)
                        Text(entry?.name ?? "\(address.prefix(6))…\(address.suffix(4))").font(.subheadline).lineLimit(1)
                        Spacer()
                        if let rules = entry?.rules {
                            Text(rules.sizing == .fixed ? "\(Int(rules.amount)) AUSD" : "≤ \(Int(rules.maxPerBuy)) AUSD").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            GlassSection("Activity") {
                if spot.log.isEmpty { Text("Copies show up here as they happen.").font(.footnote).foregroundStyle(.secondary) }
                ForEach(spot.log.prefix(60)) { row in logRow(row) }
            }

            if let problem { Text(problem).font(.footnote).foregroundStyle(DeskColor.fall.color) }

            if spot.stage == "live" {
                GlassSection {
                    Button("Change Limits") {
                        limits = spot.limits ?? limits
                        editsLimits = true
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Turn Off Spot Auto-Copy", role: .destructive) { confirmsOff = true }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .tint(DeskColor.rise.color)
        .navigationTitle("Spot Auto-Copy")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await spot.refresh() }
        .task {
            spot.bind(address: model.address?.checksummed)
            while !Task.isCancelled {
                await spot.refresh()
                try? await Task.sleep(for: .seconds(spot.stage == "enabling" || spot.stage == "stopping" ? 3 : 15))
            }
        }
        .confirmationDialog("Turn off spot Auto-Copy?", isPresented: $confirmsOff, titleVisibility: .visible) {
            Button("Turn Off with Face ID", role: .destructive) { Task { await turnOff() } }
        } message: {
            Text("Copying stops now and Desk's key comes off your wallet. What the copies bought stays yours.")
        }
        .sheet(isPresented: $editsLimits) { limitsSheet }
    }

    private var statusTitle: String {
        switch spot.stage {
        case "enabling": "Turning on…"
        case "live": spot.isPaused ? (spot.snapshot?.copier.pausedBy == "failures" ? "Paused after failed copies" : "Paused") : "On"
        case "stopping": "Turning off…"
        case "failed": "Didn't turn on"
        case "off": "Off"
        default: "Checking…"
        }
    }

    private var statusFooter: String? {
        if let error = spot.snapshot?.copier.error { return error }
        var parts: [String] = []
        if let left = spot.remainingToday { parts.append("\(Int(left)) AUSD left to copy today") }
        if let expiry = spot.expiry { parts.append("ends \(expiry.formatted(date: .abbreviated, time: .omitted))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func logRow(_ row: SpotCopier.LogRow) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(row)).foregroundStyle(tint(row)).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title(row)).font(.subheadline.weight(.medium)).lineLimit(2)
                if let detail = row.detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer(minLength: 6)
            Text(row.date, style: .relative).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
        }
    }

    private func title(_ row: SpotCopier.LogRow) -> String {
        let symbol = row.symbol ?? "token"
        switch (row.status, row.side) {
        case ("copied", "buy"): return "Bought \(symbol) for \(String(format: "%.2f", row.ausd ?? 0)) AUSD"
        case ("copied", "sell"): return "Sold \(symbol) for \(String(format: "%.2f", row.ausd ?? 0)) AUSD"
        case ("skipped", _): return "Didn't copy \(symbol) \(row.side ?? "")"
        case ("failed", "enable"), ("failed", "disable"), ("failed", "limits"): return "Couldn't change Auto-Copy"
        case ("failed", _): return "Couldn't copy \(symbol) \(row.side ?? "")"
        case ("on", _): return "Spot Auto-Copy turned on"
        case ("off", _): return "Spot Auto-Copy turned off"
        case ("paused", _): return "Paused"
        default: return row.status.capitalized
        }
    }

    private func icon(_ row: SpotCopier.LogRow) -> String {
        switch row.status {
        case "copied": row.side == "buy" ? "arrow.down.circle.fill" : "arrow.up.circle.fill"
        case "skipped": "minus.circle"
        case "failed": "exclamationmark.triangle.fill"
        case "paused": "pause.circle.fill"
        default: "power.circle.fill"
        }
    }

    private func tint(_ row: SpotCopier.LogRow) -> Color {
        switch row.status {
        case "copied", "on": DeskColor.rise.color
        case "failed": DeskColor.fall.color
        default: .secondary
        }
    }

    private var limitsSheet: some View {
        NavigationStack {
            GlassPage {
                GlassSection("Limits you sign", footer: "Face ID signs these into your wallet; Desk relays them.") {
                    Stepper(value: $limits.perTrade, in: 5...5_000, step: limits.perTrade < 50 ? 5 : 25) {
                        HStack { Text("Most per buy"); Spacer(); Text("\(limits.perTrade) AUSD").foregroundStyle(.secondary) }
                    }
                    Stepper(value: $limits.perDay, in: max(limits.perTrade, 10)...50_000, step: limits.perDay < 200 ? 10 : 100) {
                        HStack { Text("Most per day"); Spacer(); Text("\(limits.perDay) AUSD").foregroundStyle(.secondary) }
                    }
                    GlassRow("Runs for") {
                        Picker("Runs for", selection: $days) {
                            Text("7 days").tag(7)
                            Text("30 days").tag(30)
                            Text("90 days").tag(90)
                        }
                        .labelsHidden()
                    }
                }
                if let problem { Text(problem).font(.footnote).foregroundStyle(DeskColor.fall.color) }
                Button {
                    Task { await saveLimits() }
                } label: {
                    HStack(spacing: 8) {
                        if isWorking { ProgressView().tint(DeskColor.onAction.color) }
                        Label("Save with Face ID", systemImage: "faceid")
                    }
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .deskProminentButton()
                .disabled(isWorking)
            }
            .tint(DeskColor.rise.color)
            .navigationTitle("Change Limits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editsLimits = false } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func saveLimits() async {
        isWorking = true
        problem = nil
        defer { isWorking = false }
        do {
            try await spot.changeLimits(model: model, limits: limits, days: days)
            editsLimits = false
        } catch PasskeyFailure.cancelledByUser {
        } catch {
            problem = error.localizedDescription
        }
    }

    private func turnOff() async {
        isWorking = true
        problem = nil
        defer { isWorking = false }
        do { try await spot.disable(model: model) }
        catch PasskeyFailure.cancelledByUser {}
        catch { problem = error.localizedDescription }
    }
}
