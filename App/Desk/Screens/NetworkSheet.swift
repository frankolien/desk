import DeskFlow
import DeskUI
import SwiftUI

/// Testnet or mainnet, chosen once and shown everywhere after.
///
/// Two cards rather than a toggle: the difference is whether money is real, and that
/// deserves a sentence each, not a switch that looks the same in both positions.
struct NetworkSheet: View {
    let model: AppModel

    @Environment(\.dismiss) private var dismiss
    @State private var confirmsMainnet = false

    var body: some View {
        NavigationStack {
            GlassPage {
                Text("Your address is the same on both. Balances, positions and your trading account are not.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)

                GlassSection(footer: "Spot buys and trader data always use mainnet, whichever you choose here.") {
                    option(.testnet, symbol: "testtube.2", tint: .teal,
                           detail: "Free test MON and AUSD from Desk's faucet. Nothing you win or lose is real.")
                    option(.mainnet, symbol: "bolt.fill", tint: .orange,
                           detail: "Real MON and AUSD you deposit yourself. Profits and losses are real.")
                }
            }
            .navigationTitle("Network")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
            .overlay {
                if model.isWorking {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Switching network…").font(.footnote.weight(.semibold))
                    }
                    .padding(22)
                    .deskGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
            }
        }
        .preferredColorScheme(.dark)
        .confirmationDialog("Switch to Monad mainnet?", isPresented: $confirmsMainnet, titleVisibility: .visible) {
            Button("Use real funds") { switchTo(.mainnet) }
            Button("Stay on testnet", role: .cancel) {}
        } message: {
            Text("Deposits, trades and withdrawals will move real MON and AUSD.")
        }
    }

    private func option(_ network: DeskNetwork, symbol: String, tint: Color, detail: String) -> some View {
        let selected = model.network == network
        return Button {
            guard !selected else { return }
            if network.holdsRealFunds { confirmsMainnet = true } else { switchTo(network) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(network.name).fontWeight(.semibold)
                        Text("Chain \(network.chainID)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(selected ? tint : Color.secondary.opacity(0.5))
                    .contentTransition(.symbolEffect(.replace))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isWorking)
    }

    private func switchTo(_ network: DeskNetwork) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task {
            await model.switchNetwork(to: network)
            dismiss()
        }
    }
}
