import DeskAuth
import DeskChain
import DeskMoney
import DeskUI
import SwiftUI

/// USDC already on Monad into AUSD, the money the desk trades with: one 0x swap, the USDC
/// approved for exactly the typed amount first, Face ID once.
struct USDCSwapSheet: View {
    let model: AppModel
    let onDone: () -> Void
    @State private var flow = USDCSwapModel()
    @State private var amount = ""
    @State private var balance: (raw: Int128, decimals: Int)?
    @State private var page: WebPage?

    private var held: Decimal? {
        balance.flatMap { Decimal(string: USDCSwapModel.readable($0.raw, decimals: $0.decimals), locale: Locale(identifier: "en_US_POSIX")) }
    }
    private var typed: Decimal? { Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")).flatMap { $0 > 0 ? $0 : nil } }
    private var tooMuch: Bool { if let typed, let held { typed > held } else { false } }
    private var lacksGas: Bool { (model.walletMON.value ?? .zero).raw < NativeAmount(decimalText: "0.01")!.raw }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            payCard
            if flow.phase.isActive || flow.phase.isFinished {
                progress
            } else {
                receipt
                if let error = flow.quoteError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.yellow)
                }
            }
            Spacer(minLength: 0)
            action
        }
        .padding(24)
        .preferredColorScheme(.dark)
        .task { await load() }
        .task(id: amount) {
            guard !flow.phase.isActive, let address = model.address else { return }
            await flow.quote(amount: amount, user: address)
        }
        .interactiveDismissDisabled(flow.phase.isActive)
        .sheet(item: $page) { InAppSafari(url: $0.url).ignoresSafeArea() }
    }

    private func load() async {
        guard let usdc = try? AppModel.ethereumAddress(String(ChainTable.monadUSDC.dropFirst(2))) else { return }
        balance = try? await model.tokenBalance(usdc)
        await model.refreshBalances()
    }

    private var header: some View {
        HStack(spacing: 12) {
            TokenLogo(asset: .ausd, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Swap USDC for AUSD").font(.system(size: 22, weight: .heavy, design: .rounded))
                Text("On Monad through 0x · lands in your wallet")
                    .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onDone) {
                Image(systemName: "xmark.circle.fill").font(.title2).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(flow.phase.isActive)
        }
    }

    private var payCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("YOU PAY").font(.system(size: 10, weight: .heavy, design: .rounded)).tracking(1.2).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                TextField("0", text: $amount)
                    .keyboardType(.decimalPad)
                    .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                    .disabled(flow.phase.isActive || flow.phase.isFinished)
                Text("USDC").font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
            }
            HStack {
                Text("Balance \(balance.map { USDCSwapModel.readable($0.raw, decimals: $0.decimals) } ?? "—") USDC")
                    .foregroundStyle(tooMuch ? DeskColor.fall.color : .secondary)
                Spacer()
                Button("Max") {
                    if let balance { amount = USDCSwapModel.readable(balance.raw, decimals: balance.decimals) }
                }
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .disabled(balance == nil || balance?.raw == 0 || flow.phase.isActive || flow.phase.isFinished)
            }
            .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
        }
        .padding(16)
        .deskGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var receipt: some View {
        VStack(spacing: 9) {
            row("You receive", value: flow.quoted.map { "≈ \($0.receive.amount ?? "—") AUSD" }, emphasised: true)
            row("At least", value: flow.quoted.map { "\($0.receive.minimum ?? "—") AUSD" })
            row("Network fee", value: flow.quoted.map { "\($0.feeMON ?? "—") MON" })
            row("Arrives in", value: flow.quoted.map { _ in "This block" })
        }
        .font(.system(size: 13, design: .rounded))
        .redacted(reason: flow.isQuoting ? .placeholder : [])
    }

    private func row(_ title: String, value: String?, emphasised: Bool = false) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value ?? "—")
                .fontWeight(emphasised ? .bold : .semibold)
                .foregroundStyle(emphasised ? .primary : .secondary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 12) {
            step("Signed with Face ID", state: flow.phase.stepState(0))
            step("Approved USDC for exactly this swap", state: flow.phase.stepState(1))
            step("Swapped for AUSD on Monad", state: flow.phase.stepState(2))
            switch flow.phase {
            case .done(let receipt):
                TradeReceiptCard(
                    title: "Swapped for \(receipt.received.display()) AUSD",
                    rows: [("Paid", "\(amount) USDC"), ("On", "Monad mainnet"), ("Network fee", flow.quoted.map { "\($0.feeMON ?? "—") MON" } ?? "—")],
                    hash: receipt.hash, link: model.network.explorer.appending(path: "tx/\(receipt.hash)"))
                    .padding(.top, 4)
            case .failed(let sentence):
                Text(sentence).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(DeskColor.fall.color)
            default:
                EmptyView()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .deskGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func step(_ title: String, state: USDCSwapModel.StepState) -> some View {
        HStack(spacing: 10) {
            Group {
                switch state {
                case .waiting: Image(systemName: "circle").foregroundStyle(.secondary)
                case .running: ProgressView().controlSize(.small)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(DeskColor.rise.color)
                case .stopped: Image(systemName: "xmark.circle.fill").foregroundStyle(DeskColor.fall.color)
                }
            }
            .frame(width: 20)
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(state == .waiting ? .secondary : .primary)
        }
    }

    @ViewBuilder
    private var action: some View {
        if flow.phase.isFinished {
            Button(action: onDone) {
                Text("Done").frame(maxWidth: .infinity).frame(height: 54).contentShape(Capsule())
            }
            .buttonStyle(.plain).foregroundStyle(.black).background(.white, in: Capsule())
            .font(.system(size: 16, weight: .bold, design: .rounded))
        } else if flow.phase.isActive {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(flow.phase.sentence)
            }
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity).frame(height: 54)
            .background(Color.white.opacity(0.06), in: Capsule())
        } else if balance?.raw == 0 {
            Text("No USDC in this wallet on Monad")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).frame(height: 54)
                .background(Color.white.opacity(0.06), in: Capsule())
        } else if lacksGas {
            Text("Add a little MON for gas first")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).frame(height: 54)
                .background(Color.white.opacity(0.06), in: Capsule())
        } else {
            HoldToConfirm(
                title: tooMuch ? "More than you hold" : (flow.quoted == nil ? "Enter an amount" : "Hold to swap"),
                tint: DeskColor.rise,
                isEnabled: flow.quoted != nil && typed != nil && !flow.isQuoting && !tooMuch
            ) {
                Task { await flow.swap(model: model) }
            }
        }
    }
}

@MainActor @Observable
final class USDCSwapModel {
    struct Quote: Decodable, Sendable {
        struct Side: Decodable, Sendable {
            let amount: String?
            let raw: String?
            let minimum: String?
            let minimumRaw: String?
        }
        struct Transaction: Decodable, Sendable {
            let chainId: UInt64
            let to: String
            let data: String
            let value: String
        }
        let pay: Side
        let receive: Side
        let feeMON: String?
        let transaction: Transaction
    }

    enum Phase: Equatable {
        case idle, signing, approving, swapping
        case done(AppModel.SwapReceipt)
        case failed(String)

        var isActive: Bool { self == .signing || self == .approving || self == .swapping }
        var isFinished: Bool { if case .done = self { true } else if case .failed = self { true } else { false } }
        var sentence: String {
            switch self {
            case .signing: "Confirm with Face ID…"
            case .approving: "Approving on Monad…"
            case .swapping: "Swapping on Monad…"
            default: ""
            }
        }
        func stepState(_ index: Int) -> StepState {
            switch (self, index) {
            case (.signing, 0): .running
            case (.approving, 0): .done
            case (.approving, 1): .running
            case (.swapping, 0), (.swapping, 1): .done
            case (.swapping, 2): .running
            case (.done, _): .done
            case (.failed, _): .stopped
            default: .waiting
            }
        }
    }

    enum StepState { case waiting, running, done, stopped }

    private(set) var quoted: Quote?
    private(set) var quoteError: String?
    private(set) var isQuoting = false
    private(set) var phase: Phase = .idle
    private var quotedAt = Date.distantPast

    private static let endpoint = "https://web-lovat-nine-49.vercel.app/api/swap-quote"

    nonisolated static func readable(_ raw: Int128, decimals: Int) -> String {
        guard decimals > 0 else { return String(raw) }
        var digits = String(raw)
        if digits.count <= decimals { digits = String(repeating: "0", count: decimals - digits.count + 1) + digits }
        let whole = String(digits.prefix(digits.count - decimals))
        var fraction = String(digits.suffix(decimals))
        while fraction.hasSuffix("0") { fraction.removeLast() }
        return fraction.isEmpty ? whole : "\(whole).\(fraction)"
    }

    func quote(amount: String, user: EthereumAddress, debounce: Bool = true) async {
        quoteError = nil
        let text = amount.trimmingCharacters(in: .whitespaces)
        guard let typed = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), typed > 0 else {
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
            URLQueryItem(name: "amount", value: text),
            URLQueryItem(name: "sell", value: "TOKEN"),
            URLQueryItem(name: "buy", value: "AUSD"),
            URLQueryItem(name: "token", value: ChainTable.monadUSDC),
            URLQueryItem(name: "symbol", value: "USDC"),
        ]
        do {
            let (data, response) = try await URLSession.shared.data(from: components.url!)
            guard !Task.isCancelled else { return }
            if (response as? HTTPURLResponse)?.statusCode == 200 {
                quoted = try JSONDecoder().decode(Quote.self, from: data)
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

    func swap(model: AppModel) async {
        guard !phase.isActive, let quoted else { return }
        let sale: TokenSale
        do {
            sale = try TokenSale(
                chainID: quoted.transaction.chainId, to: quoted.transaction.to, data: quoted.transaction.data,
                value: quoted.transaction.value, token: ChainTable.monadUSDC,
                amountRaw: quoted.pay.raw ?? "", minimumOutRaw: quoted.receive.minimumRaw ?? "")
        } catch {
            phase = .failed("This quote did not pass Desk's safety check, so nothing was signed.")
            return
        }
        phase = .signing
        do {
            let receipt = try await model.swapTokenToAUSD(sale) { [weak self] step in
                guard let self else { return }
                switch step {
                case .approving: self.phase = .approving
                case .sending: self.phase = .swapping
                default: break
                }
            }
            phase = .done(receipt)
        } catch PasskeyFailure.cancelledByUser {
            phase = .idle
        } catch let failure as PasskeyFailure {
            phase = .failed(failure.sentence)
        } catch AppModel.SwapFailure.routeReverts {
            phase = .failed("This route reverts right now. Nothing was signed.")
        } catch TransactionSender.Failure.reverted {
            phase = .failed("The swap was rejected on Monad. Only gas was spent.")
        } catch {
            phase = .failed("The swap could not be sent. Nothing left the wallet.")
        }
    }
}
