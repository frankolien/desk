import CrossmintCheckout
import DeskAuth
import DeskMoney
import DeskUI
import SwiftUI

/// Card and Apple Pay deposits through Crossmint: Desk's own amount screen, then Crossmint's
/// sheet for the payment and any identity check, with the passkey wallet as the recipient. The
/// order is opened by Desk's server, which alone holds the key; the app gets a secret scoped to
/// that one order.
struct OnrampSheet: View {
    let model: AppModel
    let onClose: () -> Void

    @State private var flow = OnrampModel()
    @State private var amount = ""
    @AppStorage("desk.onramp.email") private var email = ""
    @FocusState private var editingEmail: Bool

    private var emailLooksRight: Bool {
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("@") && trimmed.contains(".") && !trimmed.hasSuffix(".") && trimmed.count <= 254
    }

    private var typed: Decimal? {
        guard let value = Decimal(string: amount), value > 0 else { return nil }
        return value
    }
    private var withinLimits: Bool {
        guard let typed, let limits = flow.setup?.limits else { return typed != nil }
        return typed >= Decimal(limits.min) && typed <= Decimal(limits.max)
    }
    private var canContinue: Bool { typed != nil && withinLimits && emailLooksRight && flow.setup?.clientKey != nil && !flow.phase.isActive }

    var body: some View {
        ZStack {
            DeskBackground()
            VStack(alignment: .leading, spacing: 0) {
                header
                switch flow.phase {
                case .paying(let open): checkout(open)
                case .done(let order): done(order)
                default: entry
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)
        }
        .interactiveDismissDisabled(flow.phase.isActive)
        .task { await flow.load() }
        #if DEBUG
        .task { if ProcessInfo.processInfo.arguments.contains("-onramp-demo") { amount = "50" } }
        #endif
    }

    private var header: some View {
        HStack {
            Text(flow.phase.isPaying ? "Pay" : "Add with Apple Pay or card")
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
            .accessibilityLabel("Close")
        }
    }

    private var entry: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                AmountText("$" + (amount.isEmpty ? "0" : amount), size: 44,
                           colour: typed != nil && !withinLimits ? DeskColor.fall : DeskColor.nightText)
                Text(flow.setup?.currency.uppercased() ?? "USD")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
            .padding(.top, 20)

            Text(limitsLine)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(typed != nil && !withinLimits ? DeskColor.fall.color : DeskColor.nightMuted.color)
                .padding(.top, 2)

            // Crossmint sends the receipt and any identity check here; a passkey account has no email of its own.
            HStack(spacing: 8) {
                Image(systemName: "envelope")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DeskColor.nightMuted.color)
                TextField("Email for the receipt", text: $email)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .submitLabel(.done)
                    .focused($editingEmail)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(Color.white.opacity(0.06), in: Capsule())
            .overlay(Capsule().stroke(editingEmail ? DeskColor.action.color.opacity(0.6) : Color.white.opacity(0.08), lineWidth: 1))
            .padding(.top, 12)

            HStack(spacing: 8) {
                ForEach([25, 50, 100, 250], id: \.self) { preset in
                    Button { amount = String(preset) } label: {
                        Text("$\(preset)")
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

            VStack(alignment: .leading, spacing: 8) {
                if let setup = flow.setup, setup.test {
                    Label("Test mode: pays with a test card and delivers test \(setup.token.symbol) on \(setup.token.chain). Nothing reaches Monad.", systemImage: "testtube.2")
                        .foregroundStyle(DeskColor.action.color)
                } else if let setup = flow.setup {
                    Label("\(setup.token.symbol) lands in this wallet on Monad. Crossmint takes the payment and shows the exact amount before you pay; Desk never sees your card.", systemImage: "checkmark.shield.fill")
                        .foregroundStyle(DeskColor.nightMuted.color)
                } else if let problem = flow.problem {
                    Label(problem, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(DeskColor.action.color)
                } else {
                    Label("Checking what's available…", systemImage: "hourglass")
                        .foregroundStyle(DeskColor.nightMuted.color)
                }
                if case .failed(let reason) = flow.phase {
                    Label(reason, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(DeskColor.fall.color)
                }
            }
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 12)

            PrimaryButton(title: continueTitle, tint: DeskColor.action, isEnabled: canContinue) {
                guard let wallet = model.address, let typed else { return }
                editingEmail = false
                Task { await flow.open(amount: typed, wallet: wallet, email: email.trimmingCharacters(in: .whitespaces)) }
            }
            .disabled(!canContinue)
        }
    }

    private var limitsLine: String {
        guard let limits = flow.setup?.limits else { return "Pays with Apple Pay or a card" }
        if let typed, !withinLimits { return "Between $\(limits.min) and $\(limits.max.formatted()) per deposit" }
        return "$\(limits.min) to $\(limits.max.formatted()) per deposit · Apple Pay or card"
    }

    private var continueTitle: String {
        if flow.phase == .opening { return "Opening…" }
        guard flow.setup != nil else { return "Not available right now" }
        guard flow.setup?.clientKey != nil else { return "Not set up on this server" }
        guard typed != nil else { return "Enter an amount" }
        guard withinLimits else { return "Out of range" }
        return emailLooksRight ? "Continue" : "Add an email for the receipt"
    }

    private func checkout(_ open: OnrampModel.OpenOrder) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(open.order.quote.receive.map { "≈ \($0.max ?? $0.min ?? "—") \($0.symbol) for $\(open.amount)" } ?? "$\(open.amount)")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(DeskColor.nightMuted.color)
                .padding(.top, 10)
            CrossmintEmbeddedCheckout(
                apiKey: open.clientKey,
                orderId: open.orderId,
                clientSecret: open.clientSecret,
                payment: CheckoutPayment(
                    crypto: CheckoutCryptoPayment(enabled: false),
                    fiat: CheckoutFiatPayment(
                        enabled: true,
                        allowedMethods: CheckoutAllowedMethods(googlePay: false, applePay: true, card: true))),
                appearance: CheckoutAppearance(
                    rules: CheckoutAppearanceRules(
                        destinationInput: CheckoutDestinationInputRule(display: "hidden"))))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text(flow.statusLine)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(DeskColor.nightMuted.color)
        }
    }

    private func done(_ order: OnrampModel.OrderStatus) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            ZStack {
                Circle().fill(DeskColor.action.color.opacity(0.10)).frame(width: 88, height: 88)
                DeskBrandMark(size: 56)
            }
            .frame(width: 112, height: 112)
            .padding(.bottom, 28)
            Text("DEPOSITED")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .tracking(2)
                .foregroundStyle(DeskColor.nightMuted.color)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                AmountText(order.quote.receive?.max ?? order.quote.receive?.min ?? order.quote.total ?? "—", size: 44)
                Text(order.quote.receive?.symbol ?? flow.setup?.token.symbol ?? "")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
            .padding(.top, 6)
            Text(flow.setup?.test == true
                 ? "Test \(flow.setup?.token.symbol ?? "USDC") delivered on \(flow.setup?.token.chain ?? "the test chain"). Nothing shows in Desk from test mode."
                 : "It's in your wallet on Monad. Open desk, or move it to trading, from Add funds.")
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(DeskColor.nightMuted.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            if let tx = order.txId, flow.setup?.test == false {
                Link(destination: model.network.explorer.appending(path: "tx/\(tx)")) {
                    Label("Receipt on Monad's explorer", systemImage: "arrow.up.right")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(DeskColor.action.color)
                }
                .padding(.top, 14)
            }
            Spacer()
            PrimaryButton(title: "Done", tint: DeskColor.action) { onClose() }
        }
        .task { await model.refreshBalances() }
    }
}

@MainActor @Observable
final class OnrampModel {
    struct Token: Decodable, Sendable { let chain: String; let symbol: String }
    struct Limits: Decodable, Sendable { let min: Int; let max: Int }
    struct Setup: Decodable, Sendable {
        let environment: String
        let test: Bool
        let clientKey: String?
        let token: Token
        let limits: Limits
        var currency: String { "usd" }
    }
    struct Receive: Decodable, Sendable { let min: String?; let max: String?; let symbol: String }
    struct Quote: Decodable, Sendable { let status: String?; let total: String?; let currency: String?; let receive: Receive? }
    struct OrderStatus: Decodable, Sendable, Equatable {
        let orderId: String?
        let phase: String?
        let payment: String?
        let delivery: String?
        let txId: String?
        let quote: Quote
        let completed: Bool
        let failed: Bool

        static func == (lhs: OrderStatus, rhs: OrderStatus) -> Bool {
            lhs.orderId == rhs.orderId && lhs.phase == rhs.phase && lhs.payment == rhs.payment && lhs.delivery == rhs.delivery && lhs.completed == rhs.completed
        }
    }
    struct OpenOrder: Equatable {
        let orderId: String
        let clientSecret: String
        let clientKey: String
        let amount: String
        var order: OrderStatus
    }
    private struct Created: Decodable { let clientSecret: String; let order: OrderStatus; let clientKey: String? }
    private struct Problem: Decodable { let error: String? }

    enum Phase: Equatable {
        case idle, opening
        case paying(OpenOrder)
        case done(OrderStatus)
        case failed(String)

        var isActive: Bool { if case .paying = self { return true }; return self == .opening }
        var isPaying: Bool { if case .paying = self { return true }; return false }
    }

    private(set) var setup: Setup?
    private(set) var problem: String?
    private(set) var phase: Phase = .idle
    private(set) var statusLine = "Pay in Crossmint's sheet above. Desk is waiting for the delivery."
    private var following: Task<Void, Never>?

    private static let endpoint = "https://web-lovat-nine-49.vercel.app/api/swap-quote?view=onramp"

    func load() async {
        do {
            let (data, response) = try await URLSession.shared.data(from: URL(string: Self.endpoint)!)
            if (response as? HTTPURLResponse)?.statusCode == 200 {
                setup = try JSONDecoder().decode(Setup.self, from: data)
            } else {
                problem = (try? JSONDecoder().decode(Problem.self, from: data))?.error ?? "Card deposits aren't available right now."
            }
        } catch {
            problem = "Desk's server could not be reached."
        }
    }

    func open(amount: Decimal, wallet: EthereumAddress, email: String) async {
        guard !phase.isActive, let clientKey = setup?.clientKey else { return }
        phase = .opening
        var request = URLRequest(url: URL(string: Self.endpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let text = "\(amount)"
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["wallet": wallet.checksummed, "amount": text, "currency": "usd", "email": email])
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 201 || status == 200 else {
                phase = .failed((try? JSONDecoder().decode(Problem.self, from: data))?.error ?? "Crossmint could not open the order.")
                return
            }
            let created = try JSONDecoder().decode(Created.self, from: data)
            guard let orderId = created.order.orderId else { throw URLError(.badServerResponse) }
            let open = OpenOrder(orderId: orderId, clientSecret: created.clientSecret, clientKey: created.clientKey ?? clientKey, amount: text, order: created.order)
            phase = .paying(open)
            follow(open)
        } catch {
            phase = .failed("The order could not be opened. Nothing was charged.")
        }
    }

    /// The server is asked every few seconds until Crossmint reports the delivery, or gives up.
    private func follow(_ open: OpenOrder) {
        following?.cancel()
        following = Task { [weak self] in
            let deadline = Date.now.addingTimeInterval(20 * 60)
            while !Task.isCancelled, Date.now < deadline {
                try? await Task.sleep(for: .seconds(3))
                guard let self, case .paying(var current) = self.phase else { return }
                guard let url = URL(string: Self.endpoint + "&orderId=\(open.orderId)"),
                      let (data, _) = try? await URLSession.shared.data(from: url),
                      let order = try? JSONDecoder().decode(OrderStatus.self, from: data) else { continue }
                if order.completed { self.phase = .done(order); return }
                if order.failed { self.phase = .failed("Crossmint could not complete this deposit. Nothing was delivered; a charge, if any, is refunded by Crossmint."); return }
                current.order = order
                self.phase = .paying(current)
                self.statusLine = Self.sentence(for: order)
            }
            if let self, case .paying = self.phase { self.phase = .failed("Still waiting on Crossmint. Your deposit will show in Add funds when it lands.") }
        }
    }

    private static func sentence(for order: OrderStatus) -> String {
        switch order.payment {
        case "requires-kyc", "manual-kyc", "pending-kyc-review": "Crossmint is checking your identity. This happens once."
        case "awaiting-payment": "Pay in Crossmint's sheet above. Desk is waiting for the delivery."
        case "in-progress", "completed": "Paid. Crossmint is sending the tokens to your wallet."
        default: "Pay in Crossmint's sheet above. Desk is waiting for the delivery."
        }
    }
}
