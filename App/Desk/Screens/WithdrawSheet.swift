import DeskMoney
import DeskUI
import SwiftUI

/// Taking collateral back out.
///
/// The one screen in the app where the wallet key signs rather than the trading key, and
/// it says so. That distinction is the product: a trading session deliberately cannot move
/// money, so a withdrawal is a fresh Face ID prompt — which is exactly the moment a person
/// wants to be asked.
///
/// Ordered like the ticket: the figure, then what it costs, then the action. Max is a
/// button rather than a hint, because the most common withdrawal is all of it and making
/// someone type a balance they can see is a small insult.
struct WithdrawSheet: View {
    let model: AppModel
    let onClose: () -> Void

    @State private var amount = ""

    private var available: Money { model.collateral.value ?? .zero }

    private var requested: Money? {
        guard let value = Money(text: amount.isEmpty ? "0" : amount), value.raw > 0 else { return nil }
        return value
    }

    /// Refused before signing rather than after. A transaction that reverts on chain still
    /// costs gas, and on Monad the gas limit is the bill.
    private var tooMuch: Bool {
        guard let requested else { return false }
        return requested > available
    }

    private var canSend: Bool {
        requested != nil && !tooMuch && !model.withdrawal.isBusy
    }

    var body: some View {
        ZStack {
            DeskBackground()

            VStack(alignment: .leading, spacing: 0) {
                header

                if case .sent(let hash) = model.withdrawal {
                    sent(hash)
                } else {
                    entry
                }
            }
            .padding(24)
        }
    }

    private var header: some View {
        HStack {
            Text("Withdraw")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(DeskColor.nightText.color)
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .frame(width: 34, height: 34)
                    .background(DeskColor.nightChip.color, in: Circle())
            }
            .accessibilityLabel("Close")
        }
    }

    private var entry: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("$")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
                AmountText(amount.isEmpty ? "0" : amount, size: 52,
                           colour: tooMuch ? DeskColor.fall : DeskColor.nightText)
            }
            .padding(.top, 26)

            HStack(spacing: 10) {
                Text(tooMuch
                     ? "More than your collateral"
                     : "\(available.display()) AUSD available")
                    .font(DeskType.caption)
                    .foregroundStyle(tooMuch ? DeskColor.fall.color : DeskColor.nightMuted.color)

                Spacer()

                // The commonest withdrawal is all of it.
                Button("Max") { amount = available.display(grouping: "") }
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.action.color)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(DeskColor.action.color.opacity(0.12), in: Capsule())
            }
            .padding(.top, 12)

            AmountKeypad(text: $amount)
                .padding(.top, 18)

            Spacer(minLength: 12)

            // Named, because the whole point is that this key is not the trading key.
            HStack(spacing: 8) {
                Image(systemName: "faceid")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DeskColor.identity.color)
                Text("Signed by your wallet key, not your trading session. "
                     + "Face ID is required even while you are signed in.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 14)

            if case .failed(let reason) = model.withdrawal {
                Text(reason)
                    .font(DeskType.caption)
                    .foregroundStyle(DeskColor.fall.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 12)
            }

            HoldToConfirm(
                title: model.withdrawal.isBusy
                    ? "Withdrawing…"
                    : "Hold to withdraw \(amount.isEmpty ? "0" : amount) AUSD",
                tint: DeskColor.action,
                isEnabled: canSend
            ) {
                guard let requested else { return }
                Task { await model.withdraw(requested) }
            }
        }
    }

    private func sent(_ hash: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(DeskColor.rise.color)
            Text("Withdrawn")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(DeskColor.nightText.color)
            // The receipt, not the hash alone: this only renders after the transaction has
            // been confirmed on chain, so it is a fact rather than a hope.
            Text("Confirmed on Monad. Your collateral is back in your wallet.")
                .font(DeskType.caption)
                .foregroundStyle(DeskColor.nightMuted.color)
            Text(hash)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(DeskColor.nightMuted.color.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            PrimaryButton(title: "Done", tint: DeskColor.action) { close() }
        }
    }

    private func close() {
        model.clearWithdrawal()
        onClose()
    }
}
