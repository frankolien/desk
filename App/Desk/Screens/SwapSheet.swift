import DeskAuth
import DeskChain
import DeskMoney
import DeskUI
import SwiftUI

/// Which way the swap runs. MON buys AUSD for the desk; AUSD buys MON for gas and tokens.
enum SwapDirection: Hashable {
    case toAUSD, toMON

    var pays: String { self == .toAUSD ? "MON" : "AUSD" }
    var receives: String { self == .toAUSD ? "AUSD" : "MON" }
    var title: String { "Swap \(pays) for \(receives)" }
}

struct SwapSheet: View {
    let model: AppModel
    let onClose: () -> Void

    @State private var direction: SwapDirection
    @State private var flow = SwapModel()
    @State private var amount = ""
    @State private var quoting: Task<Void, Never>?
    @State private var receiptShown = false
    @State private var page: WebPage?

    init(model: AppModel, direction: SwapDirection = .toAUSD, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
        _direction = State(initialValue: direction)
    }

    /// Two fees when AUSD is sold, the approval and the swap, so a little MON must already be there.
    private static let feeFloor = NativeAmount(decimalText: "0.02") ?? .zero

    private var availableMON: NativeAmount { model.swappableMON ?? .zero }
    private var availableAUSD: Money { model.swappableAUSD ?? .zero }
    private var typedMON: NativeAmount? {
        guard direction == .toAUSD, let value = NativeAmount(decimalText: amount.isEmpty ? "0" : amount), !value.isZero else { return nil }
        return value
    }
    private var typedAUSD: Money? {
        guard direction == .toMON, let value = Money(text: amount.isEmpty ? "0" : amount), !value.isZero else { return nil }
        return value
    }
    private var hasAmount: Bool { typedMON != nil || typedAUSD != nil }
    private var tooMuch: Bool {
        if let typedMON { return typedMON > availableMON }
        if let typedAUSD { return availableAUSD < typedAUSD }
        return false
    }
    private var lacksGas: Bool { direction == .toMON && (model.walletMON.value ?? .zero) < Self.feeFloor }
    private var canSwap: Bool { hasAmount && !tooMuch && !lacksGas && flow.quoted != nil && !flow.phase.isActive && !flow.isQuoting }

    var body: some View {
        ZStack {
            DeskBackground()
            VStack(alignment: .leading, spacing: 0) {
                header
                switch flow.phase {
                case .done(let receipt): done(hash: receipt.hash, received: receipt.received.display(), unit: "AUSD")
                case .doneMON(let receipt): done(hash: receipt.hash, received: receipt.received.display(fractionDigits: 3), unit: "MON")
                case .checking, .signing, .approving, .sending: progress
                default: entry
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)
        }
        .interactiveDismissDisabled(flow.phase.isActive)
        .sheet(item: $page) { InAppSafari(url: $0.url).ignoresSafeArea() }
        .onChange(of: amount) { _, text in
            quoting?.cancel()
            guard let wallet = model.address else { return }
            quoting = Task { await flow.quote(amount: text, direction: direction, user: wallet) }
        }
        .onChange(of: direction) { _, _ in
            quoting?.cancel()
            amount = ""
            flow.reset()
        }
        .task { await model.refreshBalances() }
        #if DEBUG
        .task { if ProcessInfo.processInfo.arguments.contains("-swap-demo") { amount = "500" } }
        .task {
            // The direction change clears the amount, so the amount follows it.
            guard ProcessInfo.processInfo.arguments.contains("-swap-back-demo") else { return }
            direction = .toMON
            try? await Task.sleep(for: .milliseconds(80))
            amount = "25"
        }
        #endif
    }

    private var header: some View {
        HStack {
            Text(direction.title)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(DeskColor.nightText.color)
                .contentTransition(.numericText())
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

    private var entry: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Direction", selection: $direction) {
                Text("MON → AUSD").tag(SwapDirection.toAUSD)
                Text("AUSD → MON").tag(SwapDirection.toMON)
            }
            .pickerStyle(.segmented)
            .padding(.top, 14)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                AmountText(amount.isEmpty ? "0" : amount, size: 44,
                           colour: tooMuch ? DeskColor.fall : DeskColor.nightText)
                Text(direction.pays)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
            .padding(.top, 18)

            Text(availableLine)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(tooMuch || lacksGas ? DeskColor.fall.color : DeskColor.nightMuted.color)
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
                Task { await flow.swap(direction: direction, amount: amount, typedMON: typedMON, typedAUSD: typedAUSD, model: model) }
            }
        }
    }

    private var availableLine: String {
        switch direction {
        case .toAUSD:
            return tooMuch
                ? "More than the \(availableMON.display(fractionDigits: 2)) MON available"
                : "\(availableMON.display(fractionDigits: 2)) MON available · \(AppModel.gasReserve.display(fractionDigits: 2)) kept for fees"
        case .toMON:
            if lacksGas { return "Needs about \(Self.feeFloor.display(fractionDigits: 2)) MON in the wallet for the two fees" }
            return tooMuch
                ? "More than the \(availableAUSD.display()) AUSD in your wallet"
                : "\(availableAUSD.display()) AUSD in your wallet · fees are paid in MON"
        }
    }

    private var summary: some View {
        VStack(spacing: 6) {
            row("You receive", flow.quoted.map { "≈ \(Self.received($0.receive.amount, direction)) \(direction.receives)" } ?? (flow.isQuoting ? "Quoting…" : "—"))
            row("At least", flow.quoted.map { "\(Self.received($0.receive.minimum ?? $0.receive.amount, direction)) \(direction.receives)" } ?? "—")
            row("Network fee", flow.quoted.map { "≈ \(Self.mon($0.feeMON)) MON" } ?? "—")
            if let problem = flow.quoteError {
                Label(problem, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(DeskColor.action.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Label(direction == .toAUSD
                      ? "Checked on Monad before Face ID signs it. Nothing is approved; only the MON you send can move."
                      : "Checked on Monad before Face ID signs it. Only the AUSD you approve for this swap can move.",
                      systemImage: "checkmark.shield.fill")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var holdTitle: String {
        guard hasAmount else { return "Enter an amount" }
        if tooMuch { return "Not enough \(direction.pays)" }
        if lacksGas { return "Needs a little MON for the fees" }
        guard flow.quoted != nil else { return flow.isQuoting ? "Quoting…" : "No quote yet" }
        return "Hold to swap \(paidText) \(direction.pays)"
    }

    private var paidText: String {
        if let typedMON { return Self.mon(typedMON) }
        if let typedAUSD { return typedAUSD.display() }
        return amount
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(DeskColor.nightMuted.color)
            Spacer()
            Text(value).foregroundStyle(DeskColor.nightText.color).fontWeight(.semibold).monospacedDigit()
        }
        .font(.system(size: 13, design: .rounded))
    }

    /// Two decimals, rounded down: the keypad's precision, never more than is held.
    private func fill(_ percent: Int) {
        switch direction {
        case .toAUSD:
            let raw = percent == 100 ? availableMON.raw : availableMON.raw * Int128(percent) / 100
            let hundredths = raw / 10_000_000_000_000_000 * 10_000_000_000_000_000
            amount = (NativeAmount(raw: hundredths) ?? .zero).display(fractionDigits: 2, grouping: "")
        case .toMON:
            let raw = percent == 100 ? availableAUSD.raw : availableAUSD.raw * Int64(percent) / 100
            let hundredths = raw / 10_000 * 10_000
            amount = (Money(raw: hundredths) ?? .zero).display(fractionDigits: 2, grouping: "")
        }
        if amount.hasSuffix(".00") { amount.removeLast(3) }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            Text("Swapping \(paidText) \(direction.pays)")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(DeskColor.nightText.color)
            VStack(alignment: .leading, spacing: 14) {
                step("Checking the route on Monad", state: stepState(0))
                step("Confirm with Face ID", state: stepState(1))
                if direction == .toMON { step("Approving AUSD for the swap", state: stepState(2)) }
                step("Swapping", state: stepState(direction == .toMON ? 3 : 2))
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Spacer()
        }
    }

    private enum StepState { case waiting, running, done }

    private func stepState(_ index: Int) -> StepState {
        let current: Int = switch flow.phase {
        case .checking: 0
        case .signing: 1
        case .approving: 2
        case .sending: direction == .toMON ? 3 : 2
        default: 4
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

    private func done(hash: String, received: String, unit: String) -> some View {
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
                AmountText(received, size: 44)
                Text(unit)
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
                receiptRow("Paid", "\(paidText) \(direction.pays)")
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
                receiptRow("Network", model.network.name)
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
                Button { page = WebPage(url: model.network.explorer.appending(path: "tx/\(hash)")) } label: {
                    HStack(spacing: 12) {
                        Text("Swap")
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

    private static func received(_ text: String, _ direction: SwapDirection) -> String {
        direction == .toAUSD ? ausd(text) : mon(text)
    }
    private static func ausd(_ text: String) -> String { Money(text: text).map { $0.display() } ?? text }
    private static func mon(_ text: String) -> String { NativeAmount(decimalText: text).map { $0.display(fractionDigits: 3) } ?? text }
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
        case idle, checking, signing, approving, sending
        case done(AppModel.SwapReceipt)
        case doneMON(AppModel.MONSwapReceipt)
        case failed(String)

        var isActive: Bool { self == .checking || self == .signing || self == .approving || self == .sending }
    }

    private(set) var quoted: SwapQuote?
    private(set) var quoteError: String?
    private(set) var isQuoting = false
    private(set) var phase: Phase = .idle
    private var quotedAt = Date.distantPast

    private static let endpoint = "https://web-lovat-nine-49.vercel.app/api/swap-quote"

    func reset() {
        quoted = nil
        quoteError = nil
        isQuoting = false
        phase = .idle
    }

    func quote(amount: String, direction: SwapDirection, user: EthereumAddress, debounce: Bool = true) async {
        quoteError = nil
        let valid = switch direction {
        case .toAUSD: NativeAmount(decimalText: amount).map { !$0.isZero } ?? false
        case .toMON: Money(text: amount).map { !$0.isZero } ?? false
        }
        guard valid else {
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
        if direction == .toMON { components.queryItems?.append(URLQueryItem(name: "sell", value: "AUSD")) }
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

    func swap(direction: SwapDirection, amount: String, typedMON: NativeAmount?, typedAUSD: Money?, model: AppModel) async {
        guard let wallet = model.address, !phase.isActive else { return }
        // A 0x quote holds for about thirty seconds; an older one is refreshed before it runs.
        if Date.now.timeIntervalSince(quotedAt) > 20 {
            await quote(amount: amount, direction: direction, user: wallet, debounce: false)
        }
        guard let quoted else { return }
        let transaction = quoted.transaction
        let report: @MainActor (AppModel.SwapStep) -> Void = { [weak self] step in
            self?.phase = switch step {
            case .checking: .checking
            case .signing: .signing
            case .approving: .approving
            case .sending: .sending
            }
        }
        do {
            switch direction {
            case .toAUSD:
                guard let typedMON else { return }
                let checked = try AUSDSwap(
                    chainID: transaction.chainId, to: transaction.to, data: transaction.data, value: transaction.value,
                    amount: typedMON, minimumOut: Money(text: quoted.receive.minimum ?? "0") ?? .zero)
                phase = .checking
                phase = .done(try await model.swapMON(checked, progress: report))
            case .toMON:
                guard let typedAUSD else { return }
                let checked = try MONSwap(
                    chainID: transaction.chainId, to: transaction.to, data: transaction.data, value: transaction.value,
                    amount: typedAUSD, minimumOut: NativeAmount(decimalText: quoted.receive.minimum ?? "0") ?? .zero)
                phase = .checking
                phase = .doneMON(try await model.swapAUSD(checked, progress: report))
            }
        } catch is AUSDSwap.Failure {
            phase = .failed("This quote did not pass Desk's safety check, so nothing was signed.")
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
            phase = .failed("The swap could not be sent. No \(direction.pays) was taken. (\(String(describing: error)))")
        }
    }
}
