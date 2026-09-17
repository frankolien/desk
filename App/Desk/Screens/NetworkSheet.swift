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
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Your address is the same on both. Balances, positions and your trading account are not.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 6)

                    option(.testnet, symbol: "testtube.2", tint: .teal,
                           lines: ["Free test MON and AUSD from Desk's faucet", "Nothing you win or lose is real"])
                    option(.mainnet, symbol: "bolt.fill", tint: .orange,
                           lines: ["Real MON and AUSD you deposit yourself", "Profits and losses are real"])

                    Label("Spot buys and trader data always use mainnet, whichever you choose here.",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
                .padding(20)
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
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text("Switching network…").font(.subheadline.weight(.semibold))
                    }
                    .padding(28)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
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

    private func option(_ network: DeskNetwork, symbol: String, tint: Color, lines: [String]) -> some View {
        let selected = model.network == network
        return Button {
            guard !selected else { return }
            if network.holdsRealFunds { confirmsMainnet = true } else { switchTo(network) }
        } label: {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.gradient)
                    Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(network.name).font(.headline)
                        Text("Chain \(network.chainID)")
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    ForEach(lines, id: \.self) { line in
                        Text(line).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(selected ? tint : Color.secondary.opacity(0.5))
            }
            .padding(16)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(selected ? tint.opacity(0.7) : .clear, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
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
