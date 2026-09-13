import DeskUI
import SwiftUI

struct WatchlistScreen: View {
    @State private var selection = WatchlistFilter.watchlist

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Picker("List", selection: $selection) {
                        ForEach(WatchlistFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 30)

                    Text(selection.rawValue)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .padding(.bottom, 8)
                    Text(selection == .watchlist ? "Markets you saved." : "Wallets whose trades appear in Signals.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 26)

                    if selection == .watchlist {
                        ForEach(DiscoveryMarket.watchlist) { MarketDiscoveryRow(market: $0, showsBookmark: true) }
                    } else {
                        ForEach(TrackedWallet.samples) { TrackedWalletRow(wallet: $0) }
                    }
                }
                .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 112)
            }
            .background(Color.black).toolbar(.hidden, for: .navigationBar)
        }
    }
}

private enum WatchlistFilter: String, CaseIterable, Identifiable {
    case watchlist = "Watchlist", wallets = "Wallets"
    var id: Self { self }
}

struct MarketSearchScreen: View {
    @State private var query = ""
    private var results: [DiscoveryMarket] {
        query.isEmpty ? DiscoveryMarket.all : DiscoveryMarket.all.filter { "\($0.symbol) \($0.name)".localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text("Search")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .padding(.bottom, 18)

                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search markets, tokens or wallets", text: $query)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        if !query.isEmpty {
                            Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        }
                    }
                    .font(.system(size: 15, weight: .medium))
                    .padding(.horizontal, 14).frame(height: 46)
                    .discoveryGlass(interactive: true, in: Capsule())
                    .padding(.bottom, 28)

                    Text(query.isEmpty ? "TRENDING" : "RESULTS")
                        .font(.system(size: 11, weight: .bold, design: .rounded)).tracking(0.8).foregroundStyle(.secondary)
                        .padding(.bottom, 10)

                    if results.isEmpty {
                        ContentUnavailableView.search(text: query).frame(maxWidth: .infinity, minHeight: 300)
                    } else {
                        ForEach(results) { MarketDiscoveryRow(market: $0, showsBookmark: false) }
                    }
                }
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 112)
            }
            .background(Color.black).toolbar(.hidden, for: .navigationBar)
        }
    }
}

private struct DiscoveryMarket: Identifiable {
    let id: String
    let symbol: String
    let name: String
    let price: String
    let change: String
    let maxLeverage: String
    let glyph: String
    let tint: Color
    var isUp: Bool { change.hasPrefix("+") }

    static let all = [
        DiscoveryMarket(id: "btc", symbol: "BTC", name: "Bitcoin", price: "$77,354.50", change: "+0.19%", maxLeverage: "MAX 40×", glyph: "₿", tint: Color(red: 0.97, green: 0.58, blue: 0.10)),
        DiscoveryMarket(id: "eth", symbol: "ETH", name: "Ethereum", price: "$2,508.35", change: "−0.74%", maxLeverage: "MAX 25×", glyph: "◆", tint: .white),
        DiscoveryMarket(id: "hype", symbol: "HYPE", name: "Hyperliquid", price: "$78.30", change: "+0.38%", maxLeverage: "MAX 10×", glyph: "H", tint: Color(red: 0.36, green: 0.77, blue: 0.68)),
        DiscoveryMarket(id: "sol", symbol: "SOL", name: "Solana", price: "$101.20", change: "−0.78%", maxLeverage: "MAX 20×", glyph: "S", tint: Color(red: 0.40, green: 0.82, blue: 0.72)),
        DiscoveryMarket(id: "xrp", symbol: "XRP", name: "XRP", price: "$1.36", change: "−0.79%", maxLeverage: "MAX 20×", glyph: "X", tint: .white)
    ]
    static let watchlist = Array(all.prefix(4))
}

private struct MarketDiscoveryRow: View {
    let market: DiscoveryMarket
    let showsBookmark: Bool
    var body: some View {
        Button { } label: {
            HStack(spacing: 12) {
                Group {
                    if market.id == "btc" { AssetMark.bitcoin(size: 42) }
                    else { AssetMark(glyph: market.glyph, tint: market.tint, size: 42) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(market.symbol).font(.system(size: 17, weight: .bold, design: .rounded))
                    HStack(spacing: 5) {
                        Text(market.name)
                        Text(market.maxLeverage).padding(.horizontal, 6).padding(.vertical, 2)
                            .overlay(Capsule().stroke(Color.white.opacity(0.14)))
                    }.font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(market.price).font(.system(size: 16, weight: .bold, design: .rounded)).monospacedDigit()
                    Text(market.change).font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(market.isUp ? DeskColor.rise.color : DeskColor.fall.color)
                }
                if showsBookmark { Image(systemName: "bookmark.fill").font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            .padding(.vertical, 13).contentShape(Rectangle())
        }
        .buttonStyle(.plain).overlay(alignment: .bottom) { Divider() }
    }
}

private struct TrackedWallet: Identifiable {
    let id: Int, name: String, address: String, pnl: String, trades: String
    static let samples = [
        TrackedWallet(id: 1, name: "Fqoj", address: "Fqoj…Maiv", pnl: "+$8,421.10", trades: "42 trades"),
        TrackedWallet(id: 2, name: "Mitch", address: "4Be9…3ha7t", pnl: "+$3.43M", trades: "186 trades"),
        TrackedWallet(id: 3, name: "Perp Desk", address: "7ttJ…v9iQs", pnl: "+$22,018", trades: "91 trades")
    ]
}

private struct TrackedWalletRow: View {
    let wallet: TrackedWallet
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill").font(.system(size: 38)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(wallet.name).font(.system(size: 16, weight: .bold))
                Text("\(wallet.address) · \(wallet.trades)").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(wallet.pnl).font(.system(size: 14, weight: .bold)).foregroundStyle(DeskColor.rise.color).monospacedDigit()
        }
        .padding(.vertical, 14).overlay(alignment: .bottom) { Divider() }
    }
}

private extension View {
    @ViewBuilder func discoveryGlass<S: Shape>(interactive: Bool = false, in shape: S) -> some View {
        if #available(iOS 26.0, *) { glassEffect(.regular.interactive(interactive), in: shape) }
        else { background(.ultraThinMaterial, in: shape) }
    }
}
