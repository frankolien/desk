import DeskAuth
import DeskMoney
import DeskUI
import SwiftUI
import UIKit

/// Sending AUSD: who it's for, one big amount, where it comes from, the keypad, and one
/// button. Face ID is the confirmation, so there's no hold step. Money in trading comes out
/// of Perpl first, in the same Face ID. Opened from someone's profile the recipient is fixed;
/// opened as Withdraw the person types or pastes one, or picks their own wallet to move
/// trading money back into it.
struct SendSheet: View {
    let model: AppModel
    var recipient: String? = nil
    var name: String? = nil
    var title: String? = nil
    let onClose: () -> Void

    @State private var source: AppModel.WithdrawalSource = .wallet
    @State private var amount = ""
    @State private var typed = ""
    @FocusState private var typing: Bool
    @State private var page: WebPage?
    /// A typed tag or name, once the directory has turned it into a wallet.
    @State private var found: (query: String, address: String, identity: Identity?)?
    @State private var lookup: Lookup = .idle

    enum Lookup: Equatable { case idle, looking, missing, unavailable }

    private var editable: Bool { recipient == nil }
    private var typedText: String { typed.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Something other than an address that could be a Desk tag or a name service name.
    private var typedIsName: Bool { editable && !typedText.isEmpty && EthereumAddress(text: typedText) == nil && Self.nameLike(typedText) }
    private var address: String {
        if let recipient { return recipient }
        if let found, found.query == typedText { return found.address }
        return typedText
    }
    private var to: EthereumAddress? { EthereumAddress(text: address) }
    private var toMyself: Bool { to != nil && to == model.address }
    private var foundName: String? { found.flatMap { $0.query == typedText ? ($0.identity?.handle ?? $0.identity?.name ?? typedText) : nil } }
    private var walletBalance: Money { model.walletAUSD.value ?? .zero }
    private var tradingBalance: Money { model.collateral.value ?? .zero }
    private var available: Money { source == .wallet ? walletBalance : tradingBalance }
    private var requested: Money? { Money(text: amount).flatMap { $0.raw > 0 ? $0 : nil } }
    private var tooMuch: Bool { requested.map { $0 > available } ?? false }
    private var lacksGas: Bool { (model.walletMON.value?.raw ?? .max) < 10_000_000_000_000_000 * (source == .trading ? 2 : 1) }
    private var shortAddress: String { "\(address.prefix(6))…\(address.suffix(4))" }
    private var recipientTitle: String { toMyself ? "My wallet" : (name ?? shortAddress) }

    /// Why the typed address won't do, in one line.
    private var addressProblem: String? {
        guard editable, !typed.isEmpty else { return nil }
        if typedIsName && to == nil {
            switch lookup {
            case .missing: return "No Desk tag or name answers to \(typedText)."
            case .unavailable: return "Names can't be looked up right now. Paste the address instead."
            default: return nil
            }
        }
        guard let to else { return "That isn't a Monad address. Check every character." }
        if to.isZero { return "That address burns anything sent to it." }
        if toMyself && source == .wallet { return "That's this wallet. Pick Trading balance to move money into it." }
        return nil
    }

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
        .task(id: typedText) {
            guard typedIsName else { lookup = .idle; return }
            if let found, found.query == typedText { return }
            lookup = .looking
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            switch await IdentityDirectory.shared.lookup(typedText) {
            case .wallet(let address, let identity):
                found = (typedText, address, identity)
                lookup = .idle
            case .solana, .notFound: lookup = .missing
            case .unavailable: lookup = .unavailable
            }
        }
        #if DEBUG
        .task { if editable, ProcessInfo.processInfo.arguments.contains("-withdraw-sent") { model.seedWithdrawalSentForReview() } }
        #endif
    }

    /// "@frank", "frank", "frank.desk", "salmo.nad", "vitalik.eth": worth asking the directory about.
    static func nameLike(_ text: String) -> Bool {
        if text.hasPrefix("@") { return text.count >= 4 }
        if text.contains(".") { return !text.contains(" ") }
        return text.count >= 3 && text.count <= 20 && text.first?.isLetter == true
            && text.allSatisfy { ($0.isLetter && $0.isASCII) || $0.isNumber || $0 == "_" }
    }

    // MARK: Entry

    private var entry: some View {
        VStack(spacing: 0) {
            header.padding(.top, 22)
            if editable { toField.padding(.horizontal, 20).padding(.top, 18) }

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

            if !typing {
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
            }

            footer
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 12)
        }
        .disabled(model.withdrawal.isBusy)
        .animation(.snappy(duration: 0.2), value: typing)
    }

    private var header: some View {
        HStack(spacing: 12) {
            if editable {
                Text(title ?? "Send")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
            } else {
                TraderAvatar(address: address, size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(recipientTitle)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                        .lineLimit(1)
                    Text(name == nil ? model.network.name : shortAddress)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                }
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

    /// Who the money goes to: typed or pasted, or this wallet itself for trading money.
    private var toField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if to != nil && addressProblem == nil {
                    TraderAvatar(address: address, size: 28)
                } else {
                    Text("To")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                }
                if toMyself && !typing {
                    Text("My wallet · \(shortAddress)")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { typing = true }
                } else if let foundName, !typing {
                    Text("\(foundName) · \(shortAddress)")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { typing = true }
                } else {
                    TextField("", text: $typed, prompt: Text("@tag or Monad address").foregroundStyle(DeskColor.nightMuted.color))
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($typing)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if lookup == .looking {
                    ProgressView().controlSize(.small).padding(.trailing, 8)
                } else if typed.isEmpty {
                    Button("Paste") {
                        typed = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        typing = false
                    }
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(Color.white.opacity(0.12), in: Capsule())
                } else {
                    Button { typed = ""; typing = true } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(DeskColor.nightMuted.color)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear address")
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: 52)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            if let addressProblem {
                Text(addressProblem)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.fall.color)
            } else if !toMyself, source == .trading, let mine = model.address {
                Button {
                    typed = mine.checksummed
                    typing = false
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    Label("Move it to my wallet instead", systemImage: "wallet.bifold")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(DeskColor.action.color)
                }
                .buttonStyle(.plain)
            }
        }
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
        requested != nil && !tooMuch && !lacksGas && to != nil && addressProblem == nil && !model.withdrawal.isBusy
    }

    private var buttonTitle: String {
        switch model.withdrawal {
        case .confirming: return "Confirm with Face ID"
        case .withdrawing: return "Moving from trading…"
        case .sending: return "Sending…"
        default:
            if editable && to == nil { return typedIsName ? "Finding \(typedText)…" : "Add a tag or address" }
            guard let requested else { return "Enter an amount" }
            return toMyself ? "Move $\(requested.display()) to wallet" : "Send $\(requested.display())"
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
        typing = false
        Task { await model.withdraw(requested, from: source, to: to) }
    }

    // MARK: Sent

    private func sent(_ receipt: AppModel.WithdrawalReceipt) -> some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack(alignment: .bottomTrailing) {
                TraderAvatar(address: receipt.recipient?.checksummed ?? model.address?.checksummed ?? address, size: 88)
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
            Text(receipt.recipient == nil ? "Moved to your wallet" : "Sent to \(recipientTitle)")
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
