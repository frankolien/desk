import DeskAuth
import DeskChain
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
    /// For an EVM recipient: which chain the money lands on. Monad unless the person picks another.
    @State private var chainID: UInt64 = AnyChainSend.monad
    @State private var prepared: AnyChainPrepared?
    @State private var preparing = false
    @State private var prepareProblem: String?
    @State private var delivery: Delivery = .idle

    enum Delivery: Equatable {
        case idle, signing, submitting
        case queued(id: String), sending(id: String, hash: String?)
        case sent(id: String, hash: String?, requestID: String?, filled: Bool)
        case failed(String)
        var isBusy: Bool { switch self { case .signing, .submitting, .queued, .sending: true; default: false } }
    }

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
    /// A Solana address typed or pasted: money goes there as USDC, through Relay.
    private var solanaRecipient: String? { editable && to == nil && TrackedWallets.isSolana(typedText) ? typedText : nil }
    private var hasRecipient: Bool { to != nil || solanaRecipient != nil }
    private var destinationChainID: UInt64 { solanaRecipient != nil ? AnyChainSend.solana : chainID }
    private var destinationChainName: String { AnyChainSend.chains.first { $0.id == destinationChainID }?.name ?? "Monad" }
    /// Wallet money goes out through DeskSend with Desk paying the gas; trading money still
    /// comes out of Perpl first, which needs MON, and then takes the old road.
    private var usesGasless: Bool { source == .wallet && hasRecipient && !toMyself }
    private var preparedIsCurrent: Bool {
        guard let prepared, let requested else { return false }
        return prepared.amountRaw == String(requested.raw) && prepared.recipient.lowercased() == (solanaRecipient ?? address).lowercased()
            && prepared.chainId == destinationChainID && prepared.expiresAt > Date.now.timeIntervalSince1970 * 1000 + 25_000
    }
    private var foundName: String? { found.flatMap { $0.query == typedText ? ($0.identity?.handle ?? $0.identity?.name ?? typedText) : nil } }
    private var walletBalance: Money { model.walletAUSD.value ?? .zero }
    private var tradingBalance: Money { model.collateral.value ?? .zero }
    private var available: Money { source == .wallet ? walletBalance : tradingBalance }
    private var requested: Money? { Money(text: amount).flatMap { $0.raw > 0 ? $0 : nil } }
    private var tooMuch: Bool { requested.map { $0 > available } ?? false }
    private var lacksGas: Bool { !usesGasless && (model.walletMON.value?.raw ?? .max) < 10_000_000_000_000_000 * (source == .trading ? 2 : 1) }
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
        if solanaRecipient != nil {
            return source == .trading ? "Move trading money to your wallet first, then send it to Solana." : nil
        }
        guard let to else { return "That isn't a Monad or Solana address. Check every character." }
        if to.isZero { return "That address burns anything sent to it." }
        if toMyself && source == .wallet { return "That's this wallet. Pick Trading balance to move money into it." }
        if source == .trading && chainID != AnyChainSend.monad { return "Move trading money to your wallet first, then send it to \(destinationChainName)." }
        return nil
    }

    private var quoteKey: String { "\(usesGasless)|\(solanaRecipient ?? address)|\(destinationChainID)|\(requested?.raw ?? 0)|\(tooMuch)" }

    var body: some View {
        ZStack {
            DeskBackground()
            switch (model.withdrawal, delivery) {
            case (.sent(let receipt), _): sent(receipt)
            case (_, .sent): delivered
            default: entry
            }
        }
        .interactiveDismissDisabled(model.withdrawal.isBusy || delivery.isBusy)
        .task(id: quoteKey) {
            prepared = nil
            prepareProblem = nil
            guard usesGasless, let requested, !tooMuch, addressProblem == nil, let user = model.address?.checksummed else { preparing = false; return }
            preparing = true
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            do {
                prepared = try await AnyChainSendAPI.prepare(user: user, to: solanaRecipient ?? address, chainID: destinationChainID, amount: requested.display(grouping: ""))
            } catch {
                if !Task.isCancelled { prepareProblem = (error as? AnyChainSendAPI.Failure)?.sentence ?? "The route couldn't be checked. Try again." }
            }
            preparing = false
        }
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
        .task {
            // -send-to <address> -send-amount <n> [-send-chain <id>] [-send-go]: drive a send without taps.
            let arguments = ProcessInfo.processInfo.arguments
            guard editable, let index = arguments.firstIndex(of: "-send-to"), index + 1 < arguments.count else { return }
            typed = arguments[index + 1]
            if let at = arguments.firstIndex(of: "-send-amount"), at + 1 < arguments.count { amount = arguments[at + 1] }
            if let at = arguments.firstIndex(of: "-send-chain"), at + 1 < arguments.count, let id = UInt64(arguments[at + 1]) { chainID = id }
            guard arguments.contains("-send-go") else { return }
            for _ in 0..<40 where !canSend { try? await Task.sleep(for: .milliseconds(250)) }
            if canSend { send() }
        }
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

            if usesGasless, requested != nil, !tooMuch, addressProblem == nil { arrival.padding(.top, 8) }

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
        .disabled(model.withdrawal.isBusy || delivery.isBusy)
        .animation(.snappy(duration: 0.2), value: typing)
    }

    /// What lands on the other side, from the live route: the token, the chain, the amount after
    /// Relay's fee, and how long. Desk pays Monad's gas, so there is nothing else to pay.
    private var arrival: some View {
        Group {
            if let prepareProblem {
                Label(prepareProblem, systemImage: "exclamationmark.circle.fill").foregroundStyle(DeskColor.fall.color)
            } else if let prepared, preparedIsCurrent {
                if prepared.chainId == AnyChainSend.monad {
                    Text("Arrives on Monad · no fee")
                } else {
                    Text("Arrives as \(prepared.symbol) on \(prepared.chain) · $\(prepared.arrives ?? prepared.amount) · \(prepared.seconds <= 5 ? "seconds" : "about \(Int(prepared.seconds)) s")")
                }
            } else {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Checking the route…") }
            }
        }
        .font(.system(size: 14, weight: .medium, design: .rounded).monospacedDigit())
        .foregroundStyle(DeskColor.nightMuted.color)
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .padding(.horizontal, 28)
        .animation(.snappy(duration: 0.2), value: prepared?.id)
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
                    TextField("", text: $typed, prompt: Text("@tag, name or any address").foregroundStyle(DeskColor.nightMuted.color))
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
            } else if solanaRecipient != nil {
                Label("A Solana address · arrives as USDC", systemImage: "arrow.turn.down.right")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
            } else if to != nil, !toMyself, source == .wallet {
                chainPicker
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

    /// An EVM address lives on many chains: AUSD lands on the one picked here, Monad by default.
    private var chainPicker: some View {
        Menu {
            Picker("Chain", selection: $chainID) {
                ForEach(AnyChainSend.chains, id: \.id) { chain in Text(chain.name).tag(chain.id) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 12, weight: .bold))
                Text("On \(destinationChainName)")
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .bold))
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(DeskColor.action.color)
        }
        .onChange(of: chainID) { _, _ in UISelectionFeedbackGenerator().selectionChanged() }
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
                } else if case .failed(let reason) = delivery {
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
                    if model.withdrawal.isBusy || delivery.isBusy { ProgressView().tint(DeskColor.onAction.color) }
                    Text(buttonTitle)
                }
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity)
                .frame(height: 56)
            }
            .buttonStyle(.plain)
            .foregroundStyle(canSend || model.withdrawal.isBusy || delivery.isBusy ? DeskColor.onAction.color : DeskColor.nightMuted.color)
            .background(canSend || model.withdrawal.isBusy || delivery.isBusy ? DeskColor.action.color : Color.white.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .disabled(!canSend)
        }
    }

    private var canSend: Bool {
        guard requested != nil, !tooMuch, !lacksGas, hasRecipient, addressProblem == nil, !model.withdrawal.isBusy, !delivery.isBusy else { return false }
        return usesGasless ? preparedIsCurrent && prepareProblem == nil : to != nil
    }

    private var buttonTitle: String {
        switch delivery {
        case .signing: return "Confirm with Face ID"
        case .submitting, .queued: return "Sending…"
        case .sending: return "On its way…"
        default: break
        }
        switch model.withdrawal {
        case .confirming: return "Confirm with Face ID"
        case .withdrawing: return "Moving from trading…"
        case .sending: return "Sending…"
        default:
            if editable && !hasRecipient { return typedIsName ? "Finding \(typedText)…" : "Add a tag or address" }
            guard let requested else { return "Enter an amount" }
            if usesGasless, preparing, !preparedIsCurrent { return "Checking the route…" }
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
        guard let requested else { return }
        typing = false
        if usesGasless { Task { await sendAnywhere(requested) }; return }
        guard let to else { return }
        Task { await model.withdraw(requested, from: source, to: to) }
    }

    /// Wallet money, anywhere: check what the API prepared against what was asked, sign the
    /// Send and the permit with one Face ID, hand them in, and follow the send to the far chain.
    private func sendAnywhere(_ requested: Money) async {
        guard let wallet = model.address, let prepared, preparedIsCurrent else { return }
        // An EVM address is hashed lowercased, as the server hashes it; a Solana one as typed.
        let recipient = solanaRecipient ?? address.lowercased()
        delivery = .signing
        do {
            let checked = try AnyChainSend(
                wallet: wallet, amountRaw: String(requested.raw), destinationChainID: destinationChainID, recipient: recipient,
                calls: prepared.calls.map { (to: $0.to, data: $0.data) }, nonce: prepared.intent.nonce, deadline: prepared.intent.deadline,
                callsHash: prepared.intent.callsHash, destination: prepared.intent.destination,
                send: prepared.typedData.send, permit: prepared.typedData.permit)
            let signed = try await model.signAnyChainSend(checked)
            delivery = .submitting
            try await AnyChainSendAPI.submit(id: prepared.id, signature: signed.signature, permit: signed.permit)
            delivery = .queued(id: prepared.id)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            await follow(prepared.id, crossChain: prepared.chainId != AnyChainSend.monad)
        } catch PasskeyFailure.cancelledByUser {
            delivery = .idle
        } catch let failure as AnyChainSendAPI.Failure {
            delivery = .failed(failure.sentence)
        } catch let failure as AnyChainSend.Failure {
            delivery = .failed("This send didn't check out (\(failure)). Nothing was signed.")
        } catch {
            delivery = .failed(AppModel.withdrawSentence(for: error))
        }
    }

    private func follow(_ id: String, crossChain: Bool) async {
        var refreshed = false
        for _ in 0..<80 {
            try? await Task.sleep(for: .milliseconds(1_500))
            guard let status = try? await AnyChainSendAPI.status(id: id) else { continue }
            switch status.status {
            case "queued": delivery = .queued(id: id)
            case "sending": delivery = .sending(id: id, hash: status.hash)
            case "sent", "filled":
                if !refreshed { refreshed = true; UINotificationFeedbackGenerator().notificationOccurred(.success); await model.refreshBalances() }
                delivery = .sent(id: id, hash: status.hash, requestID: status.requestId, filled: !crossChain || status.status == "filled")
                if !crossChain || status.status == "filled" { return }
            case "failed", "refunded":
                delivery = .failed(Self.failureSentence(status.reason))
                return
            default: break
            }
        }
        if case .queued = delivery { delivery = .failed("Desk hasn't sent it yet. Your AUSD hasn't moved; try again in a minute.") }
    }

    private static func failureSentence(_ reason: String?) -> String {
        switch reason {
        case "not-enough-ausd": return "There wasn't enough AUSD in the wallet when Desk went to send it."
        case "expired", "already-used": return "The send timed out before Desk could place it. Nothing moved; try again."
        case "refunded": return "Relay couldn't deliver it, so the AUSD came back to your wallet."
        case "permit-rejected": return "AUSD didn't accept the signature. Update Desk and try again; nothing moved."
        case "route-failed": return "Relay couldn't take the route. Nothing moved; try again in a moment."
        default: return "The send couldn't be placed. Your AUSD hasn't moved."
        }
    }

    // MARK: Delivered

    private var delivered: some View {
        let (hash, requestID, filled): (String?, String?, Bool) = {
            if case .sent(_, let hash, let requestID, let filled) = delivery { return (hash, requestID, filled) }
            return (nil, nil, false)
        }()
        let crossChain = destinationChainID != AnyChainSend.monad
        let who = solanaRecipient.map { "\($0.prefix(4))…\($0.suffix(4))" } ?? recipientTitle
        return VStack(spacing: 0) {
            Spacer()
            ZStack(alignment: .bottomTrailing) {
                if solanaRecipient == nil { TraderAvatar(address: address, size: 88) } else {
                    Image(systemName: "paperplane.circle.fill").font(.system(size: 88)).foregroundStyle(DeskColor.action.color)
                }
                Image(systemName: filled ? "checkmark.circle.fill" : "clock.fill")
                    .font(.system(size: 30))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(DeskColor.onAction.color, filled ? DeskColor.rise.color : DeskColor.action.color)
                    .background(Circle().fill(Color.black).padding(2))
                    .offset(x: 6, y: 6)
            }
            Text("$" + (prepared?.amount ?? amount))
                .font(.system(size: 52, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(DeskColor.nightText.color)
                .padding(.top, 24)
            Text(crossChain ? "Sent to \(who) · \(prepared?.symbol ?? "USDC") on \(destinationChainName)" : "Sent to \(who)")
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(DeskColor.nightMuted.color)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.top, 4)
            if crossChain {
                HStack(spacing: 8) {
                    if !filled { ProgressView().controlSize(.small) }
                    Text(filled ? "Delivered" : "On its way · seconds")
                }
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(filled ? DeskColor.rise.color : DeskColor.nightMuted.color)
                .padding(.top, 14)
            }
            if let hash {
                Button("View on explorer") { page = WebPage(url: model.network.explorer.appending(path: "tx/\(hash)")) }
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(DeskColor.action.color)
                    .padding(.top, 14)
            }
            if crossChain, let requestID, let url = URL(string: "https://relay.link/transaction/\(requestID)") {
                Button("Track on Relay") { page = WebPage(url: url) }
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(DeskColor.action.color)
                    .padding(.top, 8)
            }
            Spacer()
            PrimaryButton(title: "Done", tint: DeskColor.action) { close() }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
        }
        .animation(.snappy(duration: 0.25), value: filled)
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

// MARK: - Any-chain send: the wire

/// What the API prepared for one send: the calls DeskSend will run, the Send and the permit
/// to sign, and what will arrive. Checked by `AnyChainSend` before anything is signed.
struct AnyChainPrepared: Decodable, Equatable {
    struct Call: Decodable, Equatable { let to: String; let data: String }
    struct Intent: Decodable, Equatable { let amount: String; let nonce: String; let deadline: String; let callsHash: String; let destination: String }
    struct Typed: Decodable { let send: EIP712.TypedData; let permit: EIP712.TypedData }
    let id: String
    let contract: String
    let expiresAt: Double
    let calls: [Call]
    let intent: Intent
    let typedData: Typed
    let chainId: UInt64
    let chain: String
    let recipient: String
    let symbol: String
    let amount: String
    let arrives: String?
    let feeUsd: Double
    let seconds: Double
    var amountRaw: String { intent.amount }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

enum AnyChainSendAPI {
    struct Failure: Error { let sentence: String }
    struct Status: Decodable { let status: String; let hash: String?; let reason: String?; let requestId: String? }
    private static var base: URL {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-api-base"), index + 1 < arguments.count, let url = URL(string: arguments[index + 1] + "/api/relay-quote") { return url }
        #endif
        return URL(string: "https://web-lovat-nine-49.vercel.app/api/relay-quote")!
    }

    static func prepare(user: String, to: String, chainID: UInt64, amount: String) async throws -> AnyChainPrepared {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "view", value: "send"), .init(name: "user", value: user), .init(name: "to", value: to), .init(name: "chainId", value: String(chainID)), .init(name: "amount", value: amount)]
        let data = try await call(URLRequest(url: components.url!, timeoutInterval: 25))
        return try JSONDecoder().decode(AnyChainPrepared.self, from: data)
    }

    static func submit(id: String, signature: String, permit: String) async throws {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "view", value: "send-submit")]
        var request = URLRequest(url: components.url!, timeoutInterval: 25)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["id": id, "signature": signature, "permit": permit])
        _ = try await call(request)
    }

    static func status(id: String) async throws -> Status {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "view", value: "send-status"), .init(name: "id", value: id)]
        return try JSONDecoder().decode(Status.self, from: try await call(URLRequest(url: components.url!, timeoutInterval: 15)))
    }

    private static func call(_ request: URLRequest) async throws -> Data {
        guard let (data, response) = try? await URLSession.shared.data(for: request), let status = (response as? HTTPURLResponse)?.statusCode else {
            throw Failure(sentence: "Desk couldn't be reached. Check the connection and try again.")
        }
        guard status == 200 else {
            let reason = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw Failure(sentence: reason ?? "Desk couldn't prepare this send right now.")
        }
        return data
    }
}
