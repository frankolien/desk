import DeskAuth
import DeskMoney
import DeskUI
import SwiftUI
import UIKit

struct WithdrawSheet: View {
    let model: AppModel
    let onClose: () -> Void

    private enum Destination: Hashable { case wallet, address }

    @State private var source: AppModel.WithdrawalSource = .trading
    @State private var destination: Destination = .wallet
    @State private var amount = ""
    @State private var recipientText = ""
    @FocusState private var editingRecipient: Bool
    @State private var receiptShown = false

    private var tradingBalance: Money { model.collateral.value ?? .zero }
    private var walletBalance: Money { model.walletAUSD.value ?? .zero }
    private var available: Money { source == .trading ? tradingBalance : walletBalance }

    private var requested: Money? {
        guard let value = Money(text: amount.isEmpty ? "0" : amount), value.raw > 0 else { return nil }
        return value
    }

    private var tooMuch: Bool { requested.map { $0 > available } ?? false }

    private var recipient: EthereumAddress? {
        guard destination == .address else { return nil }
        return EthereumAddress(text: recipientText)
    }

    private var recipientProblem: String? {
        guard destination == .address, !recipientText.isEmpty else { return nil }
        guard let recipient else { return "That isn't a valid Monad address. Check every character." }
        if recipient.isZero { return "That address burns anything sent to it." }
        if recipient == model.address { return "That's this wallet. Choose My wallet instead." }
        return nil
    }

    /// One transaction to the wallet, two when the funds continue to an address.
    private var transactionCount: Int { (source == .trading ? 1 : 0) + (destination == .address ? 1 : 0) }

    private var lacksGas: Bool {
        guard let gas = model.walletMON.value else { return false }
        return gas.raw < 10_000_000_000_000_000 * Int128(max(1, transactionCount))
    }

    private var canSend: Bool {
        guard requested != nil, !tooMuch, !model.withdrawal.isBusy, !lacksGas else { return false }
        if destination == .address { return recipient != nil && recipientProblem == nil }
        return source == .trading
    }

    var body: some View {
        ZStack {
            DeskBackground()
            VStack(alignment: .leading, spacing: 0) {
                header
                switch model.withdrawal {
                case .sent(let receipt): done(receipt)
                case .confirming, .withdrawing, .sending: progress
                default: entry
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)
        }
        .interactiveDismissDisabled(model.withdrawal.isBusy)
        #if DEBUG
        .task { if ProcessInfo.processInfo.arguments.contains("-withdraw-sent") { model.seedWithdrawalSentForReview() } }
        #endif
        .onAppear {
            // Open on whichever balance actually holds something.
            if tradingBalance.isZero && !walletBalance.isZero { source = .wallet }
        }
        .onChange(of: source) { _, newValue in
            // Wallet AUSD can only go somewhere else; sending it to itself is nothing.
            if newValue == .wallet { destination = .address }
            amount = ""
        }
    }

    // MARK: Entry

    private var header: some View {
        HStack {
            Text("Withdraw")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(DeskColor.nightText.color)
            if !model.network.holdsRealFunds {
                Text("Testnet")
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
                    .padding(.horizontal, 7)
                    .frame(height: 18)
                    .background(Color.white.opacity(0.14), in: Capsule())
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
            .disabled(model.withdrawal.isBusy)
            .accessibilityLabel("Close")
        }
    }

    private var entry: some View {
        VStack(alignment: .leading, spacing: 0) {
            route.padding(.top, 16)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                AmountText(amount.isEmpty ? "0" : amount, size: 44,
                           colour: tooMuch ? DeskColor.fall : DeskColor.nightText)
                Text("AUSD")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
            .padding(.top, 16)

            Text(tooMuch ? "More than the \(available.display()) AUSD available" : "\(available.display()) AUSD available")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(tooMuch ? DeskColor.fall.color : DeskColor.nightMuted.color)
                .padding(.top, 2)

            HStack(spacing: 8) {
                ForEach([25, 50, 75, 100], id: \.self) { percent in
                    Button { fill(percent) } label: {
                        Text(percent == 100 ? "Max" : "\(percent)%")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(DeskColor.nightText.color)
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                            .background(Color.white.opacity(0.08), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 12)

            if !editingRecipient {
                AmountKeypad(text: $amount)
                    .padding(.top, 6)
                    .transition(.opacity)
            }

            Spacer(minLength: 8)

            summary.padding(.bottom, 12)

            if case .failed(let reason) = model.withdrawal {
                Label(reason, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(DeskColor.fall.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 10)
            }

            HoldToConfirm(
                title: holdTitle,
                tint: DeskColor.action,
                isEnabled: canSend
            ) {
                guard let requested else { return }
                Task { await model.withdraw(requested, from: source, to: recipient) }
            }
        }
        .animation(.snappy(duration: 0.2), value: editingRecipient)
        .animation(.snappy(duration: 0.2), value: destination)
    }

    /// From above, to below, the arrow between: the sentence "from my trading balance to
    /// my wallet" drawn rather than written.
    private var route: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                label("From")
                choice("Trading", detail: tradingBalance.display(), selected: source == .trading) { source = .trading }
                choice("Wallet", detail: walletBalance.display(), selected: source == .wallet) { source = .wallet }
            }
            .padding(12)

            HStack {
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)
                Image(systemName: "arrow.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .frame(width: 24, height: 24)
                    .background(DeskColor.nightChip.color, in: Circle())
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)
            }

            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    label("To")
                    choice("My wallet", detail: model.addressShort, selected: destination == .wallet,
                           enabled: source == .trading) { destination = .wallet }
                    choice("Other address", detail: recipient.map { TraderSnapshot.short($0.checksummed) } ?? "Paste",
                           selected: destination == .address) { destination = .address }
                }
                if destination == .address { recipientField }
            }
            .padding(12)
        }
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
    }

    private var recipientField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("0x… address on \(model.network.name)", text: $recipientText)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($editingRecipient)
                    .foregroundStyle(DeskColor.nightText.color)
                if recipient != nil && recipientProblem == nil {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(DeskColor.rise.color)
                } else if recipientText.isEmpty {
                    Button("Paste") {
                        recipientText = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        editingRecipient = false
                    }
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.action.color)
                    .buttonStyle(.plain)
                } else {
                    Button { recipientText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(DeskColor.nightMuted.color)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if let recipientProblem {
                Text(recipientProblem)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(DeskColor.fall.color)
            }
        }
    }

    private var summary: some View {
        VStack(spacing: 6) {
            row("You send", requested.map { "\($0.display()) AUSD" } ?? "—")
            row("Network fee", transactionCount == 2 ? "≈ 0.02 MON · 2 transactions" : "≈ 0.01 MON")
            if lacksGas {
                Label("Add MON to this wallet to pay the network fee.", systemImage: "fuelpump.fill")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(DeskColor.action.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Label("Signed by your wallet key with Face ID, not your trading session.", systemImage: "faceid")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var holdTitle: String {
        guard let requested else { return destination == .address && recipient == nil ? "Add an address" : "Enter an amount" }
        // The destination is already drawn in the route above; the button names only the amount.
        return "Hold to send \(requested.display()) AUSD"
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(DeskColor.nightMuted.color)
            .frame(width: 36, alignment: .leading)
    }

    private func choice(_ title: String, detail: String, selected: Bool, enabled: Bool = true,
                        action: @escaping () -> Void) -> some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            action()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
                Text(detail)
                    .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(selected ? Color.white.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(selected ? Color.white.opacity(0.35) : Color.white.opacity(0.08), lineWidth: selected ? 1 : 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(DeskColor.nightMuted.color)
            Spacer()
            Text(value).foregroundStyle(DeskColor.nightText.color).fontWeight(.semibold).monospacedDigit()
        }
        .font(.system(size: 13, design: .rounded))
    }

    private func fill(_ percent: Int) {
        let raw = percent == 100 ? available.raw : available.raw * Int64(percent) / 100
        // Two decimals, rounded down: the keypad's precision, never more than is held.
        let cents = raw / 10_000 * 10_000
        amount = (Money(raw: cents) ?? .zero).display(grouping: "")
        editingRecipient = false
    }

    // MARK: Progress and done

    private var progress: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            Text("Sending \(requested?.display() ?? amount) AUSD")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(DeskColor.nightText.color)
            VStack(alignment: .leading, spacing: 14) {
                step("Confirm with Face ID", state: stepState(0))
                if source == .trading { step("Withdraw from Perpl", state: stepState(1)) }
                if destination == .address, let recipient {
                    step("Send to \(TraderSnapshot.short(recipient.checksummed))", state: stepState(2))
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Spacer()
        }
    }

    private enum StepState { case waiting, running, done }

    private func stepState(_ index: Int) -> StepState {
        let current = switch model.withdrawal {
        case .confirming: 0
        case .withdrawing: 1
        case .sending: 2
        default: 3
        }
        return index < current ? .done : (index == current ? .running : .waiting)
    }

    private func step(_ title: String, state: StepState) -> some View {
        HStack(spacing: 12) {
            Group {
                switch state {
                case .waiting: Image(systemName: "circle").foregroundStyle(DeskColor.nightMuted.color)
                case .running: ProgressView().controlSize(.small)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(DeskColor.rise.color)
                }
            }
            .frame(width: 22)
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(state == .waiting ? DeskColor.nightMuted.color : DeskColor.nightText.color)
        }
    }

    private func done(_ receipt: AppModel.WithdrawalReceipt) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()

            // The mark, lit once. A green tick is what every app shows; this is the
            // one moment the app's own face belongs on the screen, and one ring of its
            // own colour around it says "done" without a symbol saying so.
            ZStack {
                Circle()
                    .stroke(DeskColor.action.color.opacity(0.28), lineWidth: 1)
                    .frame(width: 112, height: 112)
                    .scaleEffect(receiptShown ? 1 : 0.7)
                    .opacity(receiptShown ? 1 : 0)
                Circle()
                    .fill(DeskColor.action.color.opacity(0.10))
                    .frame(width: 88, height: 88)
                DeskBrandMark(size: 56)
                    .scaleEffect(receiptShown ? 1 : 0.86)
            }
            .frame(width: 112, height: 112)
            .padding(.bottom, 28)

            Text("SENT")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .tracking(2)
                .foregroundStyle(DeskColor.nightMuted.color)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                AmountText(receipt.amount.display(), size: 44)
                Text("AUSD")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
            .padding(.top, 6)

            // Only rendered after every receipt came back, so this is a fact, not a hope.
            Text(receipt.recipient.map { "Confirmed on \(model.network.name). It's at \(TraderSnapshot.short($0.checksummed)) now." }
                 ?? "Confirmed on \(model.network.name). It's in your wallet now.")
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(DeskColor.nightMuted.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            receiptCard(receipt)
                .padding(.top, 24)

            Spacer()
            PrimaryButton(title: "Done", tint: DeskColor.action) { close() }
        }
        .onAppear {
            withAnimation(.spring(duration: 0.55, bounce: 0.3)) { receiptShown = true }
        }
    }

    /// One line per thing that happened, in the order it happened, each a link to the
    /// explorer. Named by what it was — a withdrawal off the desk, a transfer out — so
    /// two hashes read as two steps rather than as two of the same thing.
    private func receiptCard(_ receipt: AppModel.WithdrawalReceipt) -> some View {
        let labels: [String] = switch (receipt.transactions.count, receipt.recipient == nil) {
        case (2, _): ["Withdrawal from Perpl", "Transfer"]
        case (1, true): ["Withdrawal from Perpl"]
        default: ["Transfer"]
        }
        return VStack(spacing: 0) {
            receiptRow("To", receipt.recipient.map { TraderSnapshot.short($0.checksummed) } ?? "Your wallet")
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
            receiptRow("Network", model.network.name)
            ForEach(Array(receipt.transactions.enumerated()), id: \.element) { index, hash in
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
                Link(destination: model.network.explorer.appending(path: "tx/\(hash)")) {
                    HStack(spacing: 12) {
                        Text(labels.indices.contains(index) ? labels[index] : "Transaction")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(DeskColor.nightText.color)
                        Spacer(minLength: 8)
                        Text(hash)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(DeskColor.nightMuted.color)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 150)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(DeskColor.action.color)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 46)
                    .contentShape(Rectangle())
                }
            }
        }
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 0.6))
    }

    private func receiptRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(DeskColor.nightMuted.color)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(DeskColor.nightText.color)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private func close() {
        model.clearWithdrawal()
        onClose()
    }
}
