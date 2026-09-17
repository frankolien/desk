import DeskAuth
import DeskMoney
import DeskUI
import SwiftUI
import UIKit

/// Taking AUSD out, on one screen: where it comes from, where it goes, how much, then one
/// hold and one Face ID prompt.
///
/// The wallet key signs here, never the trading session, and the sheet says so. A
/// withdrawal to another address is two transactions — out of the exchange, then on to
/// the address — and both are shown as they happen, because the moment between them is
/// when the AUSD is safe in this wallet and a failure should say exactly that.
struct WithdrawSheet: View {
    let model: AppModel
    let onClose: () -> Void

    private enum Destination: Hashable { case wallet, address }

    @State private var source: AppModel.WithdrawalSource = .trading
    @State private var destination: Destination = .wallet
    @State private var amount = ""
    @State private var recipientText = ""
    @FocusState private var editingRecipient: Bool

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
        NavigationStack {
            ZStack {
                DeskBackground()
                Group {
                    switch model.withdrawal {
                    case .sent(let receipt): done(receipt)
                    case .confirming, .withdrawing, .sending: progress
                    default: entry
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 10)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("Withdraw").font(.subheadline.weight(.semibold))
                        if !model.network.holdsRealFunds {
                            Text("Testnet").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: close)
                        .disabled(model.withdrawal.isBusy)
                }
            }
        }
        .interactiveDismissDisabled(model.withdrawal.isBusy)
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

    private var entry: some View {
        VStack(alignment: .leading, spacing: 0) {
            route

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                AmountText(amount.isEmpty ? "0" : amount, size: 38,
                           colour: tooMuch ? DeskColor.fall : DeskColor.nightText)
                Text("AUSD")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 14)

            Text(tooMuch ? "More than the \(available.display()) AUSD available" : "\(available.display()) AUSD available")
                .font(.caption)
                .foregroundStyle(tooMuch ? DeskColor.fall.color : .secondary)
                .monospacedDigit()

            HStack(spacing: 8) {
                ForEach([25, 50, 75, 100], id: \.self) { percent in
                    Button { fill(percent) } label: {
                        Text(percent == 100 ? "Max" : "\(percent)%")
                            .font(.footnote.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.small)
                    .deskSecondaryButton()
                }
            }
            .tint(.white)
            .padding(.top, 10)

            if !editingRecipient {
                AmountKeypad(text: $amount)
                    .padding(.top, 4)
                    .transition(.opacity)
            }

            Spacer(minLength: 8)

            summary.padding(.bottom, 10)

            if case .failed(let reason) = model.withdrawal {
                Label(reason, systemImage: "exclamationmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DeskColor.fall.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
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

    /// Where it comes from and where it goes, as two native segmented choices.
    private var route: some View {
        GlassSection {
            GlassRow("From", subtitle: "\(available.display()) AUSD") {
                Picker("From", selection: $source) {
                    Text("Trading").tag(AppModel.WithdrawalSource.trading)
                    Text("Wallet").tag(AppModel.WithdrawalSource.wallet)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            GlassRow("To", subtitle: destination == .wallet ? model.addressShort : "Any Monad address") {
                if source == .trading {
                    Picker("To", selection: $destination) {
                        Text("My wallet").tag(Destination.wallet)
                        Text("Address").tag(Destination.address)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                } else {
                    Text("Another address").foregroundStyle(.secondary)
                }
            }
            if destination == .address { recipientField }
        }
    }

    private var recipientField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("0x… on \(model.network.name)", text: $recipientText)
                    .font(.footnote.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($editingRecipient)
                if recipient != nil && recipientProblem == nil {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(DeskColor.rise.color)
                } else if recipientText.isEmpty {
                    Button("Paste") {
                        recipientText = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        editingRecipient = false
                    }
                    .font(.footnote.weight(.semibold))
                    .controlSize(.mini)
                    .deskSecondaryButton()
                } else {
                    Button { recipientText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear address")
                }
            }
            if let recipientProblem {
                Text(recipientProblem)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(DeskColor.fall.color)
            }
        }
    }

    private var summary: some View {
        GlassSection(footer: lacksGas ? "Add MON to this wallet to pay the network fee."
                     : "Signed by your wallet key with Face ID, not your trading session.") {
            GlassRow("You send", value: requested.map { "\($0.display()) AUSD" } ?? "—")
            GlassRow("Network fee", value: transactionCount == 2 ? "≈ 0.02 MON · 2 transactions" : "≈ 0.01 MON")
        }
    }

    private var holdTitle: String {
        guard let requested else { return destination == .address && recipient == nil ? "Add an address" : "Enter an amount" }
        let target = destination == .address ? recipient.map { TraderSnapshot.short($0.checksummed) } ?? "address" : "wallet"
        return "Hold to send \(requested.display()) AUSD to \(target)"
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
        VStack(alignment: .leading, spacing: 14) {
            Spacer()
            Text("Sending \(requested?.display() ?? amount) AUSD")
                .font(.title3.weight(.bold))
            GlassSection {
                step("Confirm with Face ID", state: stepState(0))
                if source == .trading { step("Withdraw from Perpl", state: stepState(1)) }
                if destination == .address, let recipient {
                    step("Send to \(TraderSnapshot.short(recipient.checksummed))", state: stepState(2))
                }
            }
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
            .frame(width: 20)
            Text(title)
                .fontWeight(.medium)
                .foregroundStyle(state == .waiting ? .secondary : .primary)
        }
    }

    private func done(_ receipt: AppModel.WithdrawalReceipt) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(DeskColor.rise.color)
                .symbolEffect(.bounce, value: receipt.amount.raw)
            Text("\(receipt.amount.display()) AUSD sent")
                .font(.title3.weight(.bold))
            // Only rendered after every receipt came back, so this is a fact, not a hope.
            Text(receipt.recipient.map { "Confirmed on \(model.network.name). It's at \(TraderSnapshot.short($0.checksummed)) now." }
                 ?? "Confirmed on \(model.network.name). It's in your wallet now.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            GlassSection("Transactions") {
                ForEach(receipt.transactions, id: \.self) { hash in
                    Link(destination: model.network.explorer.appending(path: "tx/\(hash)")) {
                        HStack {
                            Text(hash)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 12)
                            Image(systemName: "arrow.up.right").font(.caption.weight(.bold))
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 6)
            Spacer()
            Button(action: close) {
                Text("Done")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
            }
            .controlSize(.large)
            .deskProminentButton()
        }
    }

    private func close() {
        model.clearWithdrawal()
        onClose()
    }
}
