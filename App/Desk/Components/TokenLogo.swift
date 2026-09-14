import DeskMoney
import SwiftUI

struct TokenLogo: View {
    enum Asset { case bitcoin, ausd }
    let asset: Asset
    var size: CGFloat = 38

    private var url: URL? {
        switch asset {
        case .bitcoin:
            URL(string: "https://assets.coingecko.com/coins/images/1/large/bitcoin.png")
        case .ausd:
            URL(string: "https://coin-images.coingecko.com/coins/images/39284/large/AUSD_1024px.png")
        }
    }

    var body: some View {
        Group {
            if asset == .ausd {
                Image("AUSD").resizable().scaledToFit()
            } else {
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFit()
                    } else {
                        Image(systemName: "bitcoinsign.circle.fill")
                            .resizable().scaledToFit().foregroundStyle(.orange)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct MarketTokenLogo: View {
    let symbol: String
    var size: CGFloat = 38

    private var url: URL? {
        let address = switch symbol.uppercased() {
        case "BTC": "https://assets.coingecko.com/coins/images/1/large/bitcoin.png"
        case "ETH": "https://assets.coingecko.com/coins/images/279/large/ethereum.png"
        case "SOL": "https://assets.coingecko.com/coins/images/4128/large/solana.png"
        case "MON": "https://coin-images.coingecko.com/coins/images/38909/large/monad.png"
        case "ZEC": "https://assets.coingecko.com/coins/images/486/large/circle-zcash-color.png"
        default: ""
        }
        return URL(string: address)
    }

    var body: some View {
        Group {
            if ["MON", "LIT", "PUMP"].contains(symbol.uppercased()) {
                Image(symbol.uppercased()).resizable().scaledToFit()
            } else {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFit()
                    } else {
                        Image(systemName: "circle.hexagongrid.fill")
                            .resizable().scaledToFit().foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityLabel(symbol)
    }
}

struct AddFundsSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var walletAmount: Money { model.walletAUSD.value ?? .zero }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    TokenLogo(asset: .ausd, size: 42)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fund trading balance")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                        Text("AUSD on Monad testnet").foregroundStyle(.secondary)
                    }
                }

                VStack(spacing: 0) {
                    balanceRow("Wallet", value: model.walletAUSD.value?.display() ?? "—")
                    Divider().overlay(Color.white.opacity(0.1)).padding(.leading, 16)
                    balanceRow("Available to trade", value: model.collateral.value?.display() ?? "—")
                }
                .perpGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                Text("Move your wallet AUSD into Perpl collateral before placing an order.")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                Button { Task { await model.depositAUSD(walletAmount) } } label: {
                    HStack {
                        if model.deposit.isBusy { ProgressView().tint(.black) }
                        Text(model.deposit.isBusy ? "Moving AUSD…" : "Move \(walletAmount.display()) AUSD")
                        Spacer()
                        Image(systemName: "arrow.right")
                    }
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity).frame(height: 54)
                    .padding(.horizontal, 18)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.black)
                .background(.white, in: Capsule())
                .disabled(walletAmount == .zero || model.deposit.isBusy)
                .opacity(walletAmount == .zero ? 0.35 : 1)

                if case .failed(let sentence) = model.deposit {
                    Label(sentence, systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.red)
                }
                if case .sent = model.deposit {
                    Label("AUSD is now available to trade.", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.green)
                }

                Button { model.copyAddress() } label: {
                    Label("Receive more AUSD", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Spacer()
            }
            .padding(24)
            .navigationTitle("Add funds")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
        .onDisappear { model.clearDeposit() }
    }

    private func balanceRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text("\(value) AUSD").fontWeight(.bold).monospacedDigit()
        }
        .font(.system(size: 15, design: .rounded))
        .padding(16)
    }
}

private extension View {
    @ViewBuilder
    func perpGlass<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) { glassEffect(.regular, in: shape) }
        else { background(.ultraThinMaterial, in: shape) }
    }
}
