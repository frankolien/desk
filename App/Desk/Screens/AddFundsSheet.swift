import DeskMoney
import DeskUI
import SwiftUI

/// Every way money gets into Desk, as a list of choices. The same sheet before a desk
/// exists and after: before, the last row opens the desk once the wallet holds Perpl's
/// minimum; after, it moves wallet AUSD to trading.
struct AddFundsSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var showsSwap = false
    @State private var showsReceive = false

    private var wallet: Money { model.walletAUSD.value ?? .zero }
    private var mainnet: Bool { model.network.holdsRealFunds }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                TokenLogo(asset: .ausd, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add funds").font(.system(size: 22, weight: .heavy, design: .rounded))
                    Text(balanceLine)
                        .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").font(.title2).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                if let spare = model.swappableMON {
                    option(symbol: "arrow.triangle.2.circlepath", title: "Swap MON for AUSD",
                           detail: "\(spare.display(fractionDigits: 2)) MON available") { showsSwap = true }
                }
                option(symbol: "qrcode", title: "Receive AUSD",
                       detail: mainnet ? "From any wallet or exchange on Monad" : "Send test AUSD to this wallet") {
                    withAnimation(.snappy(duration: 0.25)) { showsReceive.toggle() }
                }
                if showsReceive, let address = model.address { receive(address.checksummed) }
                if model.network.hasFaucet {
                    option(symbol: "sparkles", title: model.isWorking ? "Sending test funds…" : "Get test AUSD",
                           detail: "Free MON for fees and test AUSD, from the faucet", busy: model.isWorking) {
                        Task { await model.fundWallet() }
                    }
                    .disabled(model.isWorking)
                }
            }

            primary

            Group {
                if let problem = model.openingProblem ?? model.fundingProblem {
                    Label(problem, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
                }
                if case .failed(let sentence) = model.deposit {
                    Label(sentence, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
                }
                if case .sent = model.deposit {
                    Label("AUSD is now available to trade.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                if let sentence = model.fundingStatus ?? model.openingStep.map(FundScreen.stepSentence) {
                    Label(sentence, systemImage: "hourglass").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .fittedSheet()
        .presentationDragIndicator(.visible)
        .task { await model.refreshBalances() }
        .onDisappear { model.clearDeposit() }
        .onChange(of: model.hasTradingAccount) { _, ready in
            // The desk just opened from here; a beat so the last step sentence is read.
            guard ready else { return }
            Task { try? await Task.sleep(for: .milliseconds(700)); dismiss() }
        }
        .sheet(isPresented: $showsSwap) {
            SwapSheet(model: model) { showsSwap = false }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private var balanceLine: String {
        var parts = ["\(wallet.display()) AUSD in wallet"]
        if let mon = model.walletMON.value { parts.append("\(mon.display(fractionDigits: 2)) MON") }
        if model.hasTradingAccount, let trading = model.collateral.value { parts.append("\(trading.display()) trading") }
        return parts.joined(separator: " · ")
    }

    /// Opens the desk, or moves AUSD into it, or says what is still missing.
    @ViewBuilder private var primary: some View {
        if model.hasTradingAccount {
            action(model.deposit.isBusy ? "Moving AUSD…" : "Move \(wallet.display()) AUSD to trading",
                   enabled: wallet != .zero && !model.deposit.isBusy, busy: model.deposit.isBusy) {
                Task { await model.depositAUSD(wallet) }
            }
        } else if let short = model.ausdShortfall {
            VStack(spacing: 6) {
                action("Open desk", enabled: false, busy: false) {}
                Text("Perpl opens a desk from \(model.minimumToOpenDesk.display(fractionDigits: 0)) AUSD. \(short.display()) more to go.")
                    .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } else if !model.hasSetupGas {
            VStack(spacing: 6) {
                action("Open desk", enabled: false, busy: false) {}
                Text("Opening a desk needs a little MON for network fees. Send at least 0.05 MON here.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        } else {
            action(model.isWorking ? "Opening your desk…" : "Open desk with \(wallet.display()) AUSD",
                   enabled: !model.isWorking, busy: model.isWorking) {
                Task { await model.openDesk() }
            }
        }
    }

    private func action(_ title: String, enabled: Bool, busy: Bool, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 8) {
                if busy { ProgressView().tint(.black).controlSize(.small) }
                Text(title)
            }
            .font(.system(size: 16, weight: .bold, design: .rounded))
            .foregroundStyle(enabled ? .black : .white.opacity(0.45))
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(enabled ? DeskColor.action.color : Color.white.opacity(0.1), in: Capsule())
        .disabled(!enabled)
    }

    private func option(symbol: String, title: String, detail: String, busy: Bool = false, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text(detail)
                        .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                Spacer(minLength: 8)
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 66)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .deskGlass(interactive: true, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func receive(_ address: String) -> some View {
        VStack(spacing: 12) {
            AddressQR(address: address, size: 150)
            Button {
                model.copyAddress()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.snappy(duration: 0.2)) { copied = true }
                Task { try? await Task.sleep(for: .seconds(1.4)); withAnimation { copied = false } }
            } label: {
                Label(copied ? "Address copied" : address, systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .deskGlass(interactive: true, in: Capsule())
            Text(mainnet ? "AUSD or MON on Monad mainnet only." : "Monad testnet only.")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}
