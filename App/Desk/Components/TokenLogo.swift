import DeskMoney
import SwiftUI
import UIKit

private struct TokenPaletteSample: Sendable {
    let red: Double
    let green: Double
    let blue: Double
}

private actor TokenPaletteCache {
    static let shared = TokenPaletteCache()
    private var values: [String: TokenPaletteSample] = [:]

    func value(for key: String) -> TokenPaletteSample? { values[key] }
    func insert(_ value: TokenPaletteSample, for key: String) { values[key] = value }
}

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
    var remoteURL: URL? = nil

    static func artworkURL(for symbol: String) -> URL? {
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

    private var url: URL? { remoteURL ?? Self.artworkURL(for: symbol) }

    var body: some View {
        Group {
            if remoteURL == nil && ["MON", "LIT", "PUMP"].contains(symbol.uppercased()) {
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

/// A restrained card wash derived from the token artwork itself. This mirrors the
/// one-pixel palette extraction used by Gathr's `CoverPalette`, while keeping text
/// contrast anchored to the system background.
struct TokenAdaptiveCardBackground: View {
    let symbol: String
    var cornerRadius: CGFloat = 20
    var artworkURL: URL? = nil
    @State private var tint = Color.white.opacity(0.16)

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [tint.opacity(0.30), tint.opacity(0.09), Color(.secondarySystemBackground).opacity(0.72)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(tint.opacity(0.34), lineWidth: 0.75)
            }
            .task(id: artworkURL?.absoluteString ?? symbol) { await loadTint() }
    }

    @MainActor
    private func loadTint() async {
        let key = symbol.uppercased()
        let cacheKey = artworkURL?.absoluteString ?? "asset:\(key)"
        if let cached = await TokenPaletteCache.shared.value(for: cacheKey) {
            tint = Self.color(cached)
            return
        }
        let data: Data?
        if let artworkURL,
           let (downloaded, _) = try? await URLSession.shared.data(from: artworkURL) {
            data = downloaded
        } else if ["MON", "LIT", "PUMP"].contains(key) {
            data = UIImage(named: key)?.pngData()
        } else if let url = MarketTokenLogo.artworkURL(for: key),
                  let (downloaded, _) = try? await URLSession.shared.data(from: url) {
            data = downloaded
        } else {
            data = nil
        }
        guard let data else { return }
        let sampled = await Task.detached(priority: .utility) {
            Self.averageColor(in: data)
        }.value
        guard !Task.isCancelled, let sampled else { return }
        await TokenPaletteCache.shared.insert(sampled, for: cacheKey)
        tint = Self.color(sampled)
    }

    nonisolated private static func averageColor(in data: Data) -> TokenPaletteSample? {
        guard let image = UIImage(data: data) else { return nil }
        guard let cgImage = image.cgImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let original = UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                               blue: CGFloat(pixel[2]) / 255, alpha: 1)
        let vivid = vivid(original)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard vivid.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        return TokenPaletteSample(red: Double(red), green: Double(green), blue: Double(blue))
    }

    nonisolated private static func vivid(_ color: UIColor) -> UIColor {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
            return color
        }
        return UIColor(hue: hue, saturation: min(max(saturation * 1.45, 0.34), 0.90),
                       brightness: min(max(brightness, 0.40), 0.76), alpha: 1)
    }

    private static func color(_ sample: TokenPaletteSample) -> Color {
        Color(red: sample.red, green: sample.green, blue: sample.blue)
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

                if walletAmount == .zero {
                    Button { Task { await model.claimTestAUSD() } } label: {
                        HStack {
                            if model.isWorking { ProgressView().tint(.black) }
                            Text(model.isWorking ? "Claiming test AUSD…" : "Claim 10,000 test AUSD")
                            Spacer()
                            Image(systemName: "sparkles")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .padding(.horizontal, 18)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.black)
                    .background(.white, in: Capsule())
                    .disabled(model.isWorking || !model.hasSetupGas)
                    .opacity(model.hasSetupGas ? 1 : 0.42)

                    if !model.hasSetupGas {
                        Label("Add at least 0.05 MON for faucet gas first.", systemImage: "fuelpump.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.yellow)
                    }
                }

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
                if let sentence = model.fundingProblem {
                    Label(sentence, systemImage: "exclamationmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.red)
                }

                Button { model.copyAddress() } label: {
                    Label("Copy wallet address", systemImage: "doc.on.doc")
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
        .presentationDetents([.fraction(0.68), .large])
        .task { await model.refreshBalances() }
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
