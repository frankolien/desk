import DeskChain
import DeskFlow
import DeskMoney
import DeskUI
import SafariServices
import SwiftUI

/// A truthful final setup screen. A row is complete only when the chain says it is;
/// tapping a button never advances local presentation state by itself.
struct FundScreen: View {
    let model: AppModel
    /// Set when presented from inside the app for a network without an account.
    var onClose: (() -> Void)? = nil
    @State private var didCopy = false
    @State private var faucetPage: FaucetPage?

    @State private var showsNetwork = false
    @State private var showsSwap = false
    @State private var didCopyForDeposit = false

    private var minimum: Money { model.minimumToOpenDesk }

    var body: some View {
        ZStack {
            DeskColor.night.color.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    topBar
                    Text(onClose == nil ? "One last step." : "Trade on \(model.network.shortName.lowercased()).")
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                        .padding(.top, 18)
                    Text("Fund this wallet, then open your trading desk.")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .padding(.top, 4)
                    statusList.padding(.top, 16)
                    actionPanel.padding(.top, 12)

                    if let problem = model.fundingProblem ?? model.openingProblem {
                        Label(problem, systemImage: "exclamationmark.circle.fill")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(DeskColor.fall.color)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4)
                            .padding(.top, 13)
                    }
                    if let sentence = model.fundingStatus ?? model.openingStep.map(Self.stepSentence) {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(sentence)
                        }
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 14)
                    }
                    Text(model.network.holdsRealFunds ? "Monad mainnet · Real funds" : "Monad testnet · No real funds")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color.opacity(0.62))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 22)
                        .padding(.bottom, 28)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
            .refreshable { await model.refreshBalances() }
        }
        .task { await model.refreshBalances() }
        .onChange(of: model.hasTradingAccount) { _, ready in
            if ready { onClose?() }
        }
        .sheet(isPresented: $showsNetwork) {
            NetworkSheet(model: model)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showsSwap) {
            SwapSheet(model: model) { showsSwap = false }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $faucetPage, onDismiss: {
            Task { await model.refreshBalances() }
        }) { page in
            InAppSafari(url: page.url)
                .ignoresSafeArea()
        }
    }

    private var topBar: some View {
        HStack {
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(DeskColor.nightText.color)
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .nativeGlass(interactive: true, in: Circle())
                .accessibilityLabel("Close")
            }
            Text("Setup")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(DeskColor.nightText.color)
            Button { showsNetwork = true } label: {
                HStack(spacing: 4) {
                    Text(model.network.shortName)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                }
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(model.network.holdsRealFunds ? DeskColor.night.color : DeskColor.nightText.color)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(model.network.holdsRealFunds ? DeskColor.action.color : Color.white.opacity(0.14), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Network, \(model.network.name)")
            Spacer()
            Button {
                model.copyAddress()
                didCopy = true
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    Text(didCopy ? "Copied" : model.addressShort).monospaced()
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .padding(.horizontal, 13)
                .frame(height: 40)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .nativeGlass(interactive: true, in: Capsule())
        }
    }

    private var statusList: some View {
        VStack(spacing: 0) {
            SetupStatusRow(title: "Passkey", detail: "Face ID secured", complete: true,
                           actionTitle: nil, action: {})
            Divider().overlay(Color.white.opacity(0.08)).padding(.leading, 42)
            SetupStatusRow(title: "Network fees", detail: monDetail, complete: hasMON,
                           isPending: isFunding && !hasMON,
                           actionTitle: model.network.hasFaucet && model.needsManualFaucet && !hasMON ? "Monad faucet" : nil,
                           action: openMONFaucet)
            Divider().overlay(Color.white.opacity(0.08)).padding(.leading, 42)
            SetupStatusRow(title: model.network.hasFaucet ? "Test collateral" : "Collateral",
                           detail: ausdDetail, complete: hasMinimumAUSD,
                           isPending: isFunding && !hasMinimumAUSD,
                           actionTitle: nil, action: {})
        }
        .padding(.horizontal, 16)
        .nativeGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var actionPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The code sits beside the balance rather than under it, so the whole screen
            // fits without scrolling on the smallest phone Desk runs on.
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Available to deposit")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(ausdBalanceText)
                            .font(.system(size: 25, weight: .bold, design: .rounded))
                            .foregroundStyle(DeskColor.nightText.color)
                            .monospacedDigit()
                        Text("AUSD")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(DeskColor.nightMuted.color)
                    }
                }
                Spacer(minLength: 8)
                if needsFunds, !model.network.hasFaucet, !canSwapForCollateral, let address = model.address {
                    AddressQR(address: address.checksummed, size: 96)
                }
            }
            Button {
                if canSwapForCollateral {
                    showsSwap = true
                } else if needsFunds && !model.network.hasFaucet {
                    // No faucet on mainnet: the next step is someone sending funds here.
                    model.copyAddress()
                    didCopyForDeposit = true
                } else {
                    Task { needsFunds ? await model.fundWallet() : await model.openDesk() }
                }
            } label: {
                HStack {
                    Text(primaryTitle)
                    Spacer()
                    Image(systemName: "arrow.right")
                }
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(canOpen ? DeskColor.night.color : DeskColor.nightMuted.color)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(canOpen ? DeskColor.nightText.color : Color.white.opacity(0.08), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!canOpen)
            if canSwapForCollateral {
                Button {
                    model.copyAddress()
                    didCopyForDeposit = true
                } label: {
                    Text(didCopyForDeposit ? "Address copied" : "Or copy address to receive AUSD")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .nativeGlass(interactive: true, in: Capsule())
            }
            if needsFunds {
                Text(model.network.hasFaucet
                     ? "Free test MON for fees and test AUSD, sent straight to this wallet."
                     : canSwapForCollateral
                        ? "Your MON becomes AUSD here, then opens your desk. At least \(minimum.display(fractionDigits: 0)) AUSD to start."
                        : "Send at least \(minimum.display(fractionDigits: 0)) AUSD, or MON to swap here, to this address on Monad mainnet. Balances update on their own.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color.opacity(0.78))
            }
        }
        .padding(16)
        .nativeGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var hasMON: Bool { model.hasSetupGas }
    private var hasMinimumAUSD: Bool { (model.walletAUSD.value ?? .zero) >= minimum }
    private var needsFunds: Bool { !hasMON || !hasMinimumAUSD }
    /// Mainnet, MON in hand, collateral short: the swap is the next step, not a transfer.
    private var canSwapForCollateral: Bool { !hasMinimumAUSD && model.swappableMON != nil }
    private var isFunding: Bool { model.isWorking && needsFunds }
    private var balancesKnown: Bool { model.walletMON.value != nil && model.walletAUSD.value != nil }
    private var canOpen: Bool { balancesKnown && !model.isWorking }
    private var primaryTitle: String {
        switch (needsFunds, model.isWorking) {
        case (true, true): "Funding your wallet…"
        case (true, false):
            model.network.hasFaucet ? "Fund my wallet"
                : canSwapForCollateral ? "Swap MON for AUSD"
                : (didCopyForDeposit ? "Address copied" : "Copy address to deposit")
        case (false, true): "Checking…"
        case (false, false): "Open my desk"
        }
    }
    private var ausdBalanceText: String { model.walletAUSD.value.map { $0.display() } ?? "—" }
    private var ausdDetail: String {
        guard let value = model.walletAUSD.value else { return "Checking balance…" }
        return "\(value.display()) AUSD"
    }
    private var monDetail: String {
        guard let value = model.walletMON.value else { return "Checking balance…" }
        return hasMON ? "\(value.display()) MON" : "\(value.display()) MON · 0.05 needed"
    }

    private func openMONFaucet() {
        model.copyAddress()
        if let url = URL(string: "https://faucet.monad.xyz/") {
            faucetPage = FaucetPage(url: url)
        }
    }

    static func stepSentence(_ progress: OpeningSequence.Progress) -> String {
        let name = switch progress.step {
        case .approve: "Approving collateral"
        case .createAccount: "Creating your desk"
        case .allowOrderForwarding: "Enabling gasless orders"
        case .enrol: "Registering your trading key"
        }
        return progress.outcome == .alreadySatisfied ? "\(name) — done" : "\(name)…"
    }
}

private struct FaucetPage: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct SetupStatusRow: View {
    let title: String
    let detail: String
    let complete: Bool
    var isPending = false
    let actionTitle: String?
    var actionEnabled = true
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if isPending {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: complete ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(complete ? DeskColor.rise.color : DeskColor.nightMuted.color.opacity(0.55))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
                Text(detail)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
            Spacer(minLength: 8)
            if let actionTitle {
                Button(actionTitle, action: action)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(DeskColor.nightText.color)
                    .disabled(!actionEnabled)
                    .opacity(actionEnabled ? 1 : 0.45)
            }
        }
        .frame(minHeight: 58)
    }
}

private extension View {
    @ViewBuilder
    func nativeGlass<S: Shape>(interactive: Bool = false, in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(interactive), in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }
}
