import DeskAuth
import DeskChain
import DeskMoney
import DeskUI
import SwiftUI

/// MON in the wallet becomes AUSD, on Monad mainnet, without leaving Desk.
///
/// A person who withdrew MON from an exchange lands here with the one token the venue
/// does not take. The sheet quotes through Desk's server, checks the route by running it
/// unsigned, then asks for Face ID once.
struct SwapSheet: View {
    let model: AppModel
    let onClose: () -> Void

    @State private var flow = SwapModel()
    @State private var amount = ""
    @State private var quoting: Task<Void, Never>?
    @State private var receiptShown = false

    private var available: NativeAmount { model.swappableMON ?? .zero }
    private var typed: NativeAmount? {
        guard let value = NativeAmount(decimalText: amount.isEmpty ? "0" : amount), !value.isZero else { return nil }
        return value
    }
    private var tooMuch: Bool { typed.map { $0 > available } ?? false }
    private var canSwap: Bool { typed != nil && !tooMuch && flow.quoted != nil && !flow.phase.isActive && !flow.isQuoting }

    var body: some View {
        ZStack {
            DeskBackground()
            VStack(alignment: .leading, spacing: 0) {
                header
                switch flow.phase {
                case .done(let receipt): done(receipt)
                case .checking, .signing, .sending: progress
                default: entry
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)
        }
        .interactiveDismissDisabled(flow.phase.isActive)
        .onChange(of: amount) { _, text in
            quoting?.cancel()
            guard let wallet = model.address else { return }
            quoting = Task { await flow.quote(amount: text, user: wallet) }
        }
        .task { await model.refreshBalances() }
        #if DEBUG
        .task { if ProcessInfo.processInfo.arguments.contains("-swap-demo") { amount = "500" } }
        #endif
    }

    private var header: some View {
        HStack {
            Text("Swap MON for AUSD")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(DeskColor.nightText.color)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .frame(width: 32, height: 32)
                    .background(DeskColor.nightChip.color, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(flow.phase.isActive)
            .accessibilityLabel("Close")
        }
    }

    // MARK: Entry

    private var entry: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                AmountText(amount.isEmpty ? "0" : amount, size: 44,
                           colour: tooMuch ? DeskColor.fall : DeskColor.nightText)
                Text("MON")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
            .padding(.top, 20)

            Text(tooMuch
                 ? "More than the \(available.display(fractionDigits: 2)) MON available"
                 : "\(available.display(fractionDigits: 2)) MON available · \(AppModel.gasReserve.display(fractionDigits: 2)) kept for fees")
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

            AmountKeypad(text: $amount)
                .padding(.top, 6)

            Spacer(minLength: 8)

            summary.padding(.bottom, 12)

            if case .failed(let reason) = flow.phase {
                Label(reason, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(DeskColor.fall.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 10)
            }

            HoldToConfirm(title: holdTitle, tint: DeskColor.action, isEnabled: canSwap) {
                guard let typed else { return }
                Task { await flow.swap(typed: typed, amount: amount, model: model) }
            }
        }
    }

    private var summary: some View {
        VStack(spacing: 6) {
            row("You receive", flow.quoted.map { "≈ \(Self.ausd($0.receive.amount)) AUSD" } ?? (flow.isQuoting ? "Quoting…" : "—"))
            row("At least", flow.quoted.map { "\(Self.ausd($0.receive.minimum ?? $0.receive.amount)) AUSD" } ?? "—")
            row("Network fee", flow.quoted.map { "≈ \(Self.mon($0.feeMON)) MON" } ?? "—")
            if let problem = flow.quoteError {
                Label(problem, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(DeskColor.action.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Label("Checked on Monad before Face ID signs it. Nothing is approved; only the MON you send can move.",
                      systemImage: "checkmark.shield.fill")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var holdTitle: String {
        guard let typed else { return "Enter an amount" }
        if tooMuch { return "Not enough MON" }
        guard flow.quoted != nil else { return flow.isQuoting ? "Quoting…" : "No quote yet" }
        return "Hold to swap \(Self.mon(typed)) MON"
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
        let raw = percent == 100 ? available.raw : available.raw * Int128(percent) / 100
        // Two decimals, rounded down: the keypad's precision, never more than is held.
        let hundredths = raw / 10_000_000_000_000_000 * 10_000_000_000_000_000
        amount = (NativeAmount(raw: hundredths) ?? .zero).display(fractionDigits: 2, grouping: "")
        if amount.hasSuffix(".00") { amount.removeLast(3) }
    }

    // MARK: Progress and done

    private var progress: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            Text("Swapping \(typed.map(Self.mon) ?? amount) MON")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(DeskColor.nightText.color)
            VStack(alignment: .leading, spacing: 14) {
                step("Checking the route on Monad", state: stepState(0))
                step("Confirm with Face ID", state: stepState(1))
                step("Swapping", state: stepState(2))
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Spacer()
        }
    }

    private enum StepState { case waiting, running, done }

    private func stepState(_ index: Int) -> StepState {
        let current = switch flow.phase {
        case .checking: 0
        case .signing: 1
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

    private func done(_ receipt: AppModel.SwapReceipt) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
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

            Text("SWAPPED")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .tracking(2)
                .foregroundStyle(DeskColor.nightMuted.color)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                AmountText(receipt.received.display(), size: 44)
                Text("AUSD")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
            .padding(.top, 6)

            Text("Confirmed on \(model.network.name). It's in your wallet now.")
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(DeskColor.nightMuted.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            VStack(spacing: 0) {
                receiptRow("Paid", "\(typed.map(Self.mon) ?? amount) MON")
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
                receiptRow("Network", model.network.name)
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
                Link(destination: model.network.explorer.appending(path: "tx/\(receipt.hash)")) {
                    HStack(spacing: 12) {
                        Text("Swap")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(DeskColor.nightText.color)
                        Spacer(minLength: 8)
                        Text(receipt.hash)
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
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 0.6))
            .padding(.top, 24)

            Spacer()
            PrimaryButton(title: "Done", tint: DeskColor.action) { onClose() }
        }
        .onAppear {
            withAnimation(.spring(duration: 0.55, bounce: 0.3)) { receiptShown = true }
        }
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

    private static func ausd(_ text: String) -> String { Money(text: text).map { $0.display() } ?? text }
    private static func mon(_ text: String) -> String { NativeAmount(decimalText: text).map { $0.display(fractionDigits: 3) } ?? text }
    /// Whole MON when it is whole, two places otherwise: "500", not "500.00".
    private static func mon(_ amount: NativeAmount) -> String {
        let text = amount.display(fractionDigits: 2)
        return text.hasSuffix(".00") ? String(text.dropLast(3)) : text
    }
}

struct SwapQuote: Decodable, Sendable {
    struct Side: Decodable, Sendable {
        let amount: String
        let minimum: String?
    }
    struct Transaction: Decodable, Sendable {
        let chainId: UInt64
        let to: String
        let data: String
        let value: String
    }
    let receive: Side
    let feeMON: String
    let transaction: Transaction
}

@MainActor @Observable
final class SwapModel {
    enum Phase: Equatable {
        case idle, checking, signing, sending
        case done(AppModel.SwapReceipt)
        case failed(String)

        var isActive: Bool { self == .checking || self == .signing || self == .sending }
    }

    private(set) var quoted: SwapQuote?
    private(set) var quoteError: String?
    private(set) var isQuoting = false
    private(set) var phase: Phase = .idle
    private var quotedAt = Date.distantPast

    private static let endpoint = "https://web-lovat-nine-49.vercel.app/api/swap-quote"

    func quote(amount: String, user: EthereumAddress, debounce: Bool = true) async {
        quoteError = nil
        guard let typed = NativeAmount(decimalText: amount), !typed.isZero else {
            quoted = nil
            return
        }
        isQuoting = true
        defer { isQuoting = false }
        if debounce {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
        }
        var components = URLComponents(string: Self.endpoint)!
        components.queryItems = [
            URLQueryItem(name: "view", value: "swap"),
            URLQueryItem(name: "user", value: user.checksummed),
            URLQueryItem(name: "amount", value: amount),
        ]
        do {
            let (data, response) = try await URLSession.shared.data(from: components.url!)
            guard !Task.isCancelled else { return }
            if (response as? HTTPURLResponse)?.statusCode == 200 {
                quoted = try JSONDecoder().decode(SwapQuote.self, from: data)
                quotedAt = .now
            } else {
                quoted = nil
                let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                quoteError = body?["error"] as? String ?? "A live quote is unavailable right now."
            }
        } catch {
            guard !Task.isCancelled else { return }
            quoted = nil
            quoteError = "The quote service could not be reached."
        }
    }

    func swap(typed: NativeAmount, amount: String, model: AppModel) async {
        guard let wallet = model.address, !phase.isActive else { return }
        // A 0x quote holds for about thirty seconds; an older one is refreshed rather
        // than run at a rate that has already moved.
        if Date.now.timeIntervalSince(quotedAt) > 20 {
            await quote(amount: amount, user: wallet, debounce: false)
        }
        guard let quoted else { return }
        let checked: AUSDSwap
        do {
            checked = try AUSDSwap(
                chainID: quoted.transaction.chainId, to: quoted.transaction.to,
                data: quoted.transaction.data, value: quoted.transaction.value,
                amount: typed, minimumOut: Money(text: quoted.receive.minimum ?? "0") ?? .zero)
        } catch {
            phase = .failed("This quote did not pass Desk's safety check, so nothing was signed.")
            return
        }
        phase = .checking
        do {
            let receipt = try await model.swapMON(checked) { [weak self] step in
                self?.phase = switch step {
                case .checking: .checking
                case .signing: .signing
                case .sending: .sending
                }
            }
            phase = .done(receipt)
        } catch PasskeyFailure.cancelledByUser {
            phase = .idle
        } catch let failure as PasskeyFailure {
            phase = .failed(failure.sentence)
        } catch AppModel.SwapFailure.underdelivers(let gain) {
            phase = .failed("Run against Monad right now, this route would leave \(gain.display()) AUSD, less than quoted. Nothing was signed. Try again.")
        } catch AppModel.SwapFailure.routeReverts {
            phase = .failed("This route fails on Monad right now, so nothing was signed. Try again in a moment.")
        } catch TransactionSender.Failure.reverted {
            phase = .failed("The swap was rejected on Monad. Only gas was spent.")
        } catch TransactionSender.Failure.notMinedInTime {
            phase = .failed("Monad has not confirmed the swap yet. Your balances will update when it does.")
        } catch {
            phase = .failed("The swap could not be sent. No MON was taken. (\(String(describing: error)))")
        }
    }
}
