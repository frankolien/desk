import DeskAuth
import DeskFlow
import DeskUI
import SwiftUI
import UIKit

struct AccountScreen: View {
    let model: AppModel

    @Environment(\.dismiss) private var dismiss
    @State private var showsWithdraw = false
    @State private var showsFunding = false
    @State private var showsNetwork = false
    @State private var showsCurrency = false
    @State private var showsNad = false
    @State private var didCopyAddress = false
    @State private var nad = NadNamesModel()

    private var versionDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "Desk v\(version) (\(build))"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                DeskBackground()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        walletCard

                        settingsSection("FUNDS") {
                            SettingsRow(
                                icon: "dollarsign",
                                tint: .green,
                                title: "AUSD balances",
                                subtitle: "Fund your wallet or trading balance",
                                value: model.collateral.value.map { "\($0.display()) AUSD" },
                                action: { showsFunding = true }
                            )

                            sectionDivider

                            SettingsRow(
                                icon: "arrow.up.right",
                                tint: .orange,
                                title: "Withdraw",
                                subtitle: "Face ID confirmation required",
                                action: { showsWithdraw = true }
                            )
                        }

                        settingsSection("IDENTITY") {
                            SettingsRow(
                                icon: "at",
                                tint: .purple,
                                title: "Nad name",
                                subtitle: nad.primary == nil ? "Show, set and manage your .nad identity" : "Primary name on Monad",
                                value: nad.primary,
                                action: { showsNad = true }
                            )
                        }

                        settingsSection("PREFERENCES") {
                            SettingsRow(
                                icon: "dollarsign.circle.fill",
                                tint: .green,
                                title: "Currency",
                                subtitle: "Balances and profit",
                                value: "\(DisplayCurrency.shared.option.flag)  \(DisplayCurrency.shared.code)",
                                action: { showsCurrency = true }
                            )

                            sectionDivider

                            SettingsRow(
                                icon: "bell.badge.fill",
                                tint: .purple,
                                title: "Price alerts",
                                subtitle: "Levels broken, 5% days",
                                value: TradeAlerts.shared.priceAlerts ? "On" : "Off",
                                action: { Task { await TradeAlerts.shared.setPriceAlerts(!TradeAlerts.shared.priceAlerts) } }
                            )

                            sectionDivider

                            SettingsRow(
                                icon: "network",
                                tint: model.network.holdsRealFunds ? .orange : .purple,
                                title: "Network",
                                subtitle: model.network.holdsRealFunds ? "Real funds" : "Test funds only",
                                value: model.network.name,
                                action: { showsNetwork = true }
                            )
                        }

                        settingsSection("SECURITY") {
                            SettingsRow(
                                icon: "faceid",
                                tint: .indigo,
                                title: "Face ID trading key",
                                subtitle: model.isKeyUnlocked
                                    ? "Unlocked on this device"
                                    : "Locked — unlock before trading",
                                value: model.isKeyUnlocked ? "Lock" : "Unlock",
                                action: toggleTradingKey
                            )

                            sectionDivider

                            SettingsRow(
                                icon: "lock.shield.fill",
                                tint: .cyan,
                                title: "Security & privacy",
                                subtitle: "Key locks after a short absence or when your phone locks"
                            )
                        }

                        settingsSection("ABOUT DESK") {
                            SettingsRow(
                                icon: "bubble.left.and.bubble.right.fill",
                                tint: .mint,
                                title: "Contact support",
                                subtitle: "olien@frankolien.com",
                                action: contactSupport
                            )

                            sectionDivider

                            SettingsRow(
                                icon: "info.circle.fill",
                                tint: .blue,
                                title: "About Desk",
                                subtitle: "Fast, self-custodial trading"
                            )
                        }

                        footer
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showsNad, onDismiss: { Task { if let address = model.address { await nad.load(address: address.checksummed) } } }) {
            NadNameSheet(model: model) { showsNad = false }
        }
        .task(id: model.address) { if let address = model.address { await nad.load(address: address.checksummed) } }
        #if DEBUG
        .task { if ProcessInfo.processInfo.arguments.contains("-open-nad") { showsNad = true } }
        #endif
        .sheet(isPresented: $showsFunding) {
            AddFundsSheet(model: model)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color(.systemBackground))
        }
        #if DEBUG
        .task { if ProcessInfo.processInfo.arguments.contains("-open-currency") { showsCurrency = true } }
        #endif
        .sheet(isPresented: $showsCurrency) {
            CurrencySheet()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showsNetwork) {
            NetworkSheet(model: model)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showsWithdraw) {
            WithdrawSheet(model: model) { showsWithdraw = false }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color(.systemBackground))
        }
        .animation(.easeInOut(duration: 0.2), value: model.isKeyUnlocked)
    }

    private var walletCard: some View {
        Button {
            model.copyAddress()
            didCopyAddress = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                didCopyAddress = false
            }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.indigo.opacity(0.2))
                        .frame(width: 52, height: 52)

                    Image(systemName: "faceid")
                        .font(.system(size: 23, weight: .medium))
                        .foregroundStyle(.indigo)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("ACTIVE WALLET")
                        .font(.caption2.weight(.bold))
                        .tracking(1)
                        .foregroundStyle(.secondary)

                    Text(model.addressShort)
                        .font(.subheadline.weight(.semibold).monospaced())
                        .foregroundStyle(.primary)

                    HStack(spacing: 6) {
                        Text(walletBalanceText)
                        Text("•")
                        Text(model.collateral.value.map { "\($0.display()) trading" } ?? "Trading unavailable")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                }

                Spacer(minLength: 4)

                Image(systemName: didCopyAddress ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(didCopyAddress ? Color.green : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .deskGlass(interactive: true, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Copies wallet address")
    }

    private var footer: some View {
        VStack(spacing: 14) {
            Button(role: .destructive) {
                Task {
                    await model.endSession()
                    dismiss()
                }
            } label: {
                Text("Sign out")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }

            VStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tertiary)
                Text(versionDescription)
                    .font(.caption.weight(.semibold))
                Text("Built for fast markets.")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }

    private var sectionDivider: some View {
        Divider().padding(.leading, 54)
    }

    @ViewBuilder
    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption2.weight(.bold))
                .tracking(1.1)
                .foregroundStyle(.secondary)
                .padding(.leading, 8)

            VStack(spacing: 0) {
                content()
            }
            .padding(.vertical, 3)
            .deskGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
    }

    private func toggleTradingKey() {
        if model.isKeyUnlocked {
            Task { await model.lock() }
        } else {
            Task { _ = await model.unlock() }
        }
    }

    private var walletBalanceText: String {
        let amount = model.walletAUSD.value?.display() ?? "—"
        return "\(amount) AUSD wallet"
    }

    private func contactSupport() {
        guard let url = URL(string: "mailto:olien@frankolien.com") else { return }
        UIApplication.shared.open(url)
    }
}

private struct SettingsRow: View {
    let icon: String
    let tint: Color
    let title: String
    var subtitle: String?
    var value: String?
    var action: (() -> Void)?

    var body: some View {
        Group {
            if let action {
                Button(action: action) { rowContent }
                    .buttonStyle(.plain)
            } else {
                rowContent
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var rowContent: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(tint.gradient)
                    .frame(width: 36, height: 36)

                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            if let value {
                Text(value)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            }

            if action != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 56)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
