import DeskMoney
import DeskUI
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
                RemoteImage(url: url) {
                    Image(systemName: "bitcoinsign.circle.fill")
                        .resizable().scaledToFit().foregroundStyle(.orange)
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

/// A stable, clearly non-official mark when a token has no usable artwork.
struct TokenSymbolBadge: View {
    let symbol: String
    let seed: String
    let size: CGFloat

    var body: some View {
        let hue = AddressAvatar.seed(for: seed).primary / 360
        Text(String(symbol.prefix(2)).uppercased())
            .font(.system(size: size * 0.35, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: size, height: size)
            .background(Color(hue: hue, saturation: 0.55, brightness: 0.50), in: Circle())
            .accessibilityLabel("\(symbol) logo unavailable")
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
                RemoteImage(url: url) {
                    TokenSymbolBadge(symbol: symbol, seed: symbol, size: size)
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
            data = await Task.detached(priority: .utility) { UIImage(named: key)?.pngData() }.value
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
    @State private var copied = false
    @State private var showsSwap = false

    private var walletAmount: Money { model.walletAUSD.value ?? .zero }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                TokenLogo(asset: .ausd, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add funds").font(.system(size: 22, weight: .heavy, design: .rounded))
                    Text("AUSD on \(model.network.name)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").font(.title2).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                row("Wallet", value: "\(model.walletAUSD.value?.display() ?? Unavailable.text) AUSD")
                Divider().overlay(Color.white.opacity(0.08))
                row("Available to trade", value: "\(model.collateral.value?.display() ?? Unavailable.text) AUSD")
            }
            .padding(.horizontal, 16)
            .deskGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            VStack(spacing: 10) {
                Button { Task { await model.depositAUSD(walletAmount) } } label: {
                    HStack(spacing: 8) {
                        if model.deposit.isBusy { ProgressView().tint(.black).controlSize(.small) }
                        Text(model.deposit.isBusy ? "Moving AUSD…" : "Move \(walletAmount.display()) AUSD to trading")
                    }
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .background(walletAmount == .zero || model.deposit.isBusy ? Color.white.opacity(0.1) : DeskColor.action.color, in: Capsule())
                .disabled(walletAmount == .zero || model.deposit.isBusy)

                if model.network.hasFaucet && (walletAmount == .zero || !model.hasSetupGas) {
                    Button { Task { await model.fundWallet() } } label: {
                        HStack(spacing: 8) {
                            if model.isWorking { ProgressView().controlSize(.small) } else { Image(systemName: "sparkles") }
                            Text(model.isWorking ? "Sending test funds…" : "Get test AUSD")
                        }
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .deskGlass(interactive: true, in: Capsule())
                    .disabled(model.isWorking)
                }

                if let spare = model.swappableMON {
                    Button { showsSwap = true } label: {
                        Label("Swap \(spare.display(fractionDigits: 0)) MON for AUSD", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .deskGlass(interactive: true, in: Capsule())
                }

                Button {
                    model.copyAddress()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.snappy(duration: 0.2)) { copied = true }
                    Task { try? await Task.sleep(for: .seconds(1.4)); withAnimation { copied = false } }
                } label: {
                    Label(copied ? "Address copied" : "Copy wallet address", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .deskGlass(interactive: true, in: Capsule())
            }
            .foregroundStyle(.white)

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
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .preferredColorScheme(.dark)
        .fittedSheet()
        .presentationDragIndicator(.visible)
        .task { await model.refreshBalances() }
        .onDisappear { model.clearDeposit() }
        .sheet(isPresented: $showsSwap) {
            SwapSheet(model: model) { showsSwap = false }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private func row(_ label: String, value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 15, weight: .medium, design: .rounded))
            Spacer()
            Text(value).font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(.secondary)
        }
        .frame(height: 48)
    }
}

private extension View {
    @ViewBuilder
    func perpGlass<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) { glassEffect(.regular, in: shape) }
        else { background(.ultraThinMaterial, in: shape) }
    }
}
