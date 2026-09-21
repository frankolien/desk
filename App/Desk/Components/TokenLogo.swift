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

/// The hosts token artwork may be loaded from.
enum TokenArtwork {
    /// Matched on the registrable suffix, so a subdomain of a known CDN is allowed and a
    /// host that merely ends in the same letters is not.
    /// Checked against what the feed actually serves — the trending list's artwork comes
    /// from static.oklink.com, and an allow-list written from the API's name alone would
    /// have quietly removed every logo on the screen.
    private static let hosts = ["coingecko.com", "oklink.com", "okx.com", "coinall.ltd", "nadapp.net", "raw.githubusercontent.com"]

    static func url(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text), url.scheme?.lowercased() == "https",
              let host = url.host()?.lowercased() else { return nil }
        let allowed = hosts.contains { host == $0 || host.hasSuffix(".\($0)") }
        return allowed ? url : nil
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
            // Every market Perpl lists is in the catalog, so a listed market never
            // flashes a placeholder while a CDN answers. The fetch is for the spot
            // tokens, whose artwork arrives with the feed.
            if remoteURL == nil, UIImage(named: symbol.uppercased()) != nil {
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
            GlassPage {
                GlassSection(footer: "Move your wallet AUSD into Perpl collateral before placing an order.") {
                    HStack(spacing: 10) {
                        TokenLogo(asset: .ausd, size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Fund trading balance").fontWeight(.semibold)
                            Text("AUSD on \(model.network.name)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    GlassRow("Wallet", value: "\(model.walletAUSD.value?.display() ?? "—") AUSD")
                    GlassRow("Available to trade", value: "\(model.collateral.value?.display() ?? "—") AUSD")
                }

                VStack(spacing: 10) {
                    Button { Task { await model.depositAUSD(walletAmount) } } label: {
                        HStack(spacing: 8) {
                            if model.deposit.isBusy { ProgressView().tint(.black).controlSize(.small) }
                            Text(model.deposit.isBusy ? "Moving AUSD…" : "Move \(walletAmount.display()) AUSD to trading")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                    }
                    .controlSize(.large)
                    .deskProminentButton()
                    .disabled(walletAmount == .zero || model.deposit.isBusy)

                    if model.network.hasFaucet && (walletAmount == .zero || !model.hasSetupGas) {
                        Button { Task { await model.fundWallet() } } label: {
                            HStack(spacing: 8) {
                                if model.isWorking { ProgressView().controlSize(.small) } else { Image(systemName: "sparkles") }
                                Text(model.isWorking ? "Sending test funds…" : "Get 10,000 test AUSD")
                            }
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 2)
                        }
                        .controlSize(.large)
                        .deskSecondaryButton()
                        .disabled(model.isWorking)
                    }

                    Button { model.copyAddress() } label: {
                        Label("Copy wallet address", systemImage: "doc.on.doc")
                            .font(.footnote.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.regular)
                    .deskSecondaryButton()
                }
                .tint(.white)

                Group {
                    if case .failed(let sentence) = model.deposit {
                        Label(sentence, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
                    }
                    if case .sent = model.deposit {
                        Label("AUSD is now available to trade.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    if let sentence = model.fundingStatus {
                        Label(sentence, systemImage: "hourglass").foregroundStyle(.secondary)
                    }
                    if let sentence = model.fundingProblem {
                        Label(sentence, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
                    }
                }
                .font(.caption.weight(.medium))
                .padding(.horizontal, 14)
            }
            .navigationTitle("Add funds")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.fraction(0.68), .large])
        .task { await model.refreshBalances() }
        .onDisappear { model.clearDeposit() }
    }

}

private extension View {
    @ViewBuilder
    func perpGlass<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) { glassEffect(.regular, in: shape) }
        else { background(.ultraThinMaterial, in: shape) }
    }
}
