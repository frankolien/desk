import DeskAuth
import DeskFlow
import DeskUI
import SwiftUI

/// Switching Auto-Copy to Desk's server: the limits the wallet will sign, then one Face ID.
struct ServerCopySheet: View {
    let model: AppModel
    let copier: CopyTrader

    @Environment(\.dismiss) private var dismiss
    @State private var caps: ServerCopyProtocol.Caps
    @State private var isWorking = false
    @State private var problem: String?

    init(model: AppModel, copier: CopyTrader) {
        self.model = model
        self.copier = copier
        _caps = State(initialValue: .fitting(rules: copier.traders.map(\.rules), guards: copier.guards))
    }

    /// The least each limit can be and still fit the rules already set, so the server never
    /// refuses them the moment it starts.
    private var floor: ServerCopyProtocol.Caps {
        let rules = copier.traders.map(\.rules)
        return ServerCopyProtocol.Caps(
            maxMarginPerTrade: max(1, rules.map { $0.marginPerTrade * ($0.sizing == .conviction ? 2 : 1) }.max() ?? 1),
            maxLeverage: max(1, rules.map(\.maxLeverage).max() ?? 1),
            maxOpenCopies: max(1, copier.guards.maxOpenCopies),
            maxOpenNotional: max(10, copier.guards.maxMarketExposure),
            maxDailyLoss: max(1, copier.guards.dailyLossLimit),
            maxOrdersPerHour: 5)
    }

    /// Copies the phone opened with real money stay the phone's to close; the server starts clean.
    private var liveCopiesOpen: Int { copier.open.filter { !$0.shadowed }.count }

    var body: some View {
        NavigationStack {
            GlassPage {
                GlassSection(footer: model.network.holdsRealFunds ? nil : "On Perpl testnet: no real funds.") {
                    point("power", "Copies with your phone off", "Desk's server reads your traders and places the copies, day and night.")
                    point("key.fill", "A key that can only trade", "Made inside AWS for this account and never exported. It can't withdraw.")
                    point("checkmark.shield.fill", "Limits you sign", "Face ID signs the limits below. The server refuses anything past them.")
                    point("xmark.circle", "Off in one tap", "Turning it off retires the key at once.")
                }

                GlassSection("Limits", footer: "Starts roomy enough for the rules you have. Raising a limit later needs Face ID again; lowering one doesn't.") {
                    stepper("Most margin per copy", \.maxMarginPerTrade, unit: "AUSD", step: 10, range: floor.maxMarginPerTrade...10_000)
                    stepper("Most leverage", \.maxLeverage, unit: "×", step: 1, range: floor.maxLeverage...50)
                    stepper("Open copies at once", \.maxOpenCopies, unit: "", step: 1, range: floor.maxOpenCopies...50)
                    stepper("Most open in total", \.maxOpenNotional, unit: "AUSD", step: 100, range: floor.maxOpenNotional...100_000)
                    stepper("Daily loss cap", \.maxDailyLoss, unit: "AUSD", step: 10, range: floor.maxDailyLoss...10_000)
                    stepper("Orders per hour", \.maxOrdersPerHour, unit: "", step: 5, range: floor.maxOrdersPerHour...200)
                }

                if liveCopiesOpen > 0 {
                    Text("\(liveCopiesOpen) live \(liveCopiesOpen == 1 ? "copy is" : "copies are") still open on this iPhone. Close \(liveCopiesOpen == 1 ? "it" : "them") first, so nothing is copied twice.")
                        .font(.footnote)
                        .foregroundStyle(DeskColor.action.color)
                }
                if let problem {
                    Text(problem).font(.footnote).foregroundStyle(DeskColor.fall.color)
                }

                Button {
                    Task { await turnOn() }
                } label: {
                    HStack(spacing: 8) {
                        if isWorking { ProgressView().tint(DeskColor.onAction.color) }
                        Label("Turn On with Face ID", systemImage: "faceid")
                    }
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .deskProminentButton()
                .disabled(isWorking || liveCopiesOpen > 0 || model.address == nil)
            }
            .tint(DeskColor.rise.color)
            .navigationTitle("Run on Desk's Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isWorking)
    }

    private func turnOn() async {
        isWorking = true
        problem = nil
        defer { isWorking = false }
        do {
            try await copier.server.enable(model: model, caps: caps)
            // Paper copies on the phone would go stale; the server keeps its own from here.
            for copy in copier.open where copy.shadowed { copier.closeShadow(copy) }
            copier.server.syncRules(traders: copier.traders, guards: copier.guards)
            await copier.server.refresh()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
        } catch PasskeyFailure.cancelledByUser {
            problem = nil
        } catch {
            problem = error.localizedDescription
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

    private func stepper(_ title: String, _ keyPath: WritableKeyPath<ServerCopyProtocol.Caps, Int>, unit: String, step: Int, range: ClosedRange<Int>) -> some View {
        let value = caps[keyPath: keyPath]
        return Stepper(value: Binding(get: { caps[keyPath: keyPath] }, set: { caps[keyPath: keyPath] = $0 }), in: range, step: step) {
            HStack {
                Text(title)
                Spacer()
                Text(unit == "×" ? "\(value)×" : unit.isEmpty ? "\(value)" : "\(value) \(unit)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}
