import DeskAuth
import DeskMoney
import DeskUI
import SwiftUI
import UIKit

/// Sending AUSD to someone from their profile: who it's for, one big amount, where it comes
/// from, the keypad, and one button. Face ID is the confirmation, so there's no hold step.
/// Money in trading comes out of Perpl first, in the same Face ID.
struct SendSheet: View {
    let model: AppModel
    let recipient: String
    var name: String?
    let onClose: () -> Void

    @State private var source: AppModel.WithdrawalSource = .wallet
    @State private var amount = ""
    @State private var page: WebPage?

    private var to: EthereumAddress? { EthereumAddress(text: recipient) }
    private var walletBalance: Money { model.walletAUSD.value ?? .zero }
    private var tradingBalance: Money { model.collateral.value ?? .zero }
    private var available: Money { source == .wallet ? walletBalance : tradingBalance }
    private var requested: Money? { Money(text: amount).flatMap { $0.raw > 0 ? $0 : nil } }
    private var tooMuch: Bool { requested.map { $0 > available } ?? false }
    private var lacksGas: Bool { (model.walletMON.value?.raw ?? .max) < 10_000_000_000_000_000 * (source == .trading ? 2 : 1) }
    private var shortAddress: String { "\(recipient.prefix(6))…\(recipient.suffix(4))" }
    private var title: String { name ?? shortAddress }

    var body: some View {
        ZStack {
            DeskBackground()
            switch model.withdrawal {
            case .sent(let receipt): sent(receipt)
            default: entry
            }
        }
        .interactiveDismissDisabled(model.withdrawal.isBusy)
        .sheet(item: $page) { InAppSafari(url: $0.url).ignoresSafeArea() }
        .onAppear {
            model.clearWithdrawal()
            if walletBalance.isZero && !tradingBalance.isZero { source = .trading }
        }
    }

    // MARK: Entry

    private var entry: some View {
        VStack(spacing: 0) {
            header.padding(.top, 22)

            Spacer(minLength: 12)

            Text(amount.isEmpty ? "$0" : "$" + amount)
                .font(.system(size: 64, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(amount.isEmpty ? DeskColor.nightMuted.color.opacity(0.6)
                                 : tooMuch ? DeskColor.fall.color : DeskColor.nightText.color)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.15), value: amount)
                .padding(.horizontal, 24)

            sourcePill.padding(.top, 14)

            Spacer(minLength: 12)

            HStack(spacing: 10) {
                ForEach([10, 25, 50, 100], id: \.self) { percent in
                    Button { fill(percent) } label: {
                        Text(percent == 100 ? "Max" : "\(percent)%")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(DeskColor.nightText.color)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)

            AmountKeypad(text: $amount, keyHeight: 58)
                .padding(.horizontal, 20)
                .padding(.top, 10)

            footer
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 12)
        }
        .disabled(model.withdrawal.isBusy)
    }

    private var header: some View {
        HStack(spacing: 12) {
            TraderAvatar(address: recipient, size: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
                    .lineLimit(1)
                Text(name == nil ? model.network.name : shortAddress)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .frame(width: 32, height: 32)
                    .background(DeskColor.nightChip.color, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 20)
    }

    /// Which balance it comes from; trading money comes out of Perpl first.
    private var sourcePill: some View {
        Menu {
            Picker("Send from", selection: $source) {
                Label("Wallet · \(walletBalance.display()) AUSD", systemImage: "wallet.bifold").tag(AppModel.WithdrawalSource.wallet)
                Label("Trading · \(tradingBalance.display()) AUSD", systemImage: "chart.line.uptrend.xyaxis").tag(AppModel.WithdrawalSource.trading)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "dollarsign")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DeskColor.nightText.color)
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.08), in: Circle())
                Text(source == .wallet ? "Wallet balance" : "Trading balance")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
            .padding(.leading, 6)
            .padding(.trailing, 16)
            .frame(height: 42)
            .background(Color.white.opacity(0.06), in: Capsule())
        }
        .onChange(of: source) { _, _ in UISelectionFeedbackGenerator().selectionChanged() }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if case .failed(let reason) = model.withdrawal {
                    Label(reason, systemImage: "exclamationmark.circle.fill").foregroundStyle(DeskColor.fall.color)
                } else if lacksGas {
                    Label("Add a little MON to pay the network fee.", systemImage: "fuelpump.fill").foregroundStyle(DeskColor.action.color)
                } else if tooMuch {
                    Text("More than the $\(available.display()) available").foregroundStyle(DeskColor.fall.color)
                } else {
                    Text("$\(available.display()) available").foregroundStyle(DeskColor.nightMuted.color)
                }
            }
            .font(.system(size: 15, weight: .medium, design: .rounded))
            .lineLimit(2)

            Button(action: send) {
                HStack(spacing: 8) {
                    if model.withdrawal.isBusy { ProgressView().tint(DeskColor.onAction.color) }
                    Text(buttonTitle)
                }
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity)
                .frame(height: 56)
            }
            .buttonStyle(.plain)
            .foregroundStyle(canSend || model.withdrawal.isBusy ? DeskColor.onAction.color : DeskColor.nightMuted.color)
            .background(canSend || model.withdrawal.isBusy ? DeskColor.action.color : Color.white.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .disabled(!canSend)
        }
    }

    private var canSend: Bool {
        requested != nil && !tooMuch && !lacksGas && to != nil && !model.withdrawal.isBusy
    }

    private var buttonTitle: String {
        switch model.withdrawal {
        case .confirming: return "Confirm with Face ID"
        case .withdrawing: return "Moving from trading…"
        case .sending: return "Sending…"
        default: return requested.map { "Send $\($0.display())" } ?? "Enter an amount"
        }
    }

    private func fill(_ percent: Int) {
        UISelectionFeedbackGenerator().selectionChanged()
        let raw = percent == 100 ? available.raw : available.raw * Int64(percent) / 100
        // Two decimals, rounded down: never more than is held.
        let cents = raw / 10_000 * 10_000
        amount = cents == 0 ? "" : (Money(raw: cents) ?? .zero).display(grouping: "")
    }

    private func send() {
        guard let requested, let to else { return }
        Task { await model.withdraw(requested, from: source, to: to) }
    }

    // MARK: Sent

    private func sent(_ receipt: AppModel.WithdrawalReceipt) -> some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack(alignment: .bottomTrailing) {
                TraderAvatar(address: recipient, size: 88)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 30))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(DeskColor.onAction.color, DeskColor.rise.color)
                    .background(Circle().fill(Color.black).padding(2))
                    .offset(x: 6, y: 6)
            }
            Text("$" + receipt.amount.display())
                .font(.system(size: 52, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(DeskColor.nightText.color)
                .padding(.top, 24)
            Text("Sent to \(title)")
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(DeskColor.nightMuted.color)
                .padding(.top, 4)
            if let hash = receipt.transactions.last {
                Button("View on explorer") { page = WebPage(url: model.network.explorer.appending(path: "tx/\(hash)")) }
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(DeskColor.action.color)
                    .padding(.top, 14)
            }
            Spacer()
            PrimaryButton(title: "Done", tint: DeskColor.action) { close() }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
        }
        .onAppear { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    }

    private func close() {
        model.clearWithdrawal()
        onClose()
    }
}
