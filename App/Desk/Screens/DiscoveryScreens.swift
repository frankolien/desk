import DeskMoney
import DeskPerpl
import DeskUI
import SwiftUI

/// Watchlist and Search, over the markets the venue actually lists.
///
/// Both screens previously rendered a hard-coded table: five instruments with typed-in
/// prices, invented percentage changes, and a wallet list carrying figures like
/// "+$3.43M" and "186 trades" belonging to nobody. Two of the five markets do not exist
/// on Perpl at all, and the leverage cap shown for Bitcoin was 40× against a real ceiling
/// of 15×. In an app whose whole argument is that it never shows a number it cannot
/// stand behind, that was the most dishonest surface in it.
///
/// Nothing needed inventing. The context call the price already makes lists every open
/// market with its own mark and its own margin fractions, so these render seven real
/// instruments at real prices — and say plainly which of them can be traded here.
///
/// The wallet list is gone rather than rebuilt. It needed account identities, and Perpl's
/// public feed carries none; the same reason `SignalsScreen` reads the market rather than
/// the crowd.

// MARK: - Watchlist

struct WatchlistScreen: View {
    let market: MarketModel
    /// Saved locally. A watchlist is the user's own note about markets, it never needs to
    /// leave the phone, and the list is short enough that defaults are the right home.
    @AppStorage("desk.watchlist") private var savedIDs = ""

    private var saved: Set<UInt32> {
        Set(savedIDs.split(separator: ",").compactMap { UInt32($0) })
    }

    private var rows: [Market] {
        market.allMarkets.filter { saved.contains($0.id) }
    }

    var body: some View {
        ZStack {
            DeskBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Watchlist")
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                        .padding(.top, 10)

                    Text(rows.isEmpty
                         ? "Markets you save from Search appear here."
                         : "\(rows.count) market\(rows.count == 1 ? "" : "s") saved.")
                        .font(DeskType.caption)
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .padding(.top, 6)

                    if rows.isEmpty {
                        empty.padding(.top, 40)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(rows, id: \.id) { entry in
                                MarketRow(
                                    model: market,
                                    market: entry,
                                    isSaved: true,
                                    onOpen: {},
                                    onToggle: { toggle(entry.id) })
                            }
                        }
                        .padding(.top, 20)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 130)
            }
        }
    }

    /// Nothing saved is not an error, and it is not an empty void either — it names the
    /// one action that fills it.
    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "bookmark")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(DeskColor.nightMuted.color)
            Text("Nothing saved yet")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(DeskColor.nightText.color)
            Text("Open Search and tap the bookmark on any market.")
                .font(DeskType.caption)
                .foregroundStyle(DeskColor.nightMuted.color)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    private func toggle(_ id: UInt32) {
        var next = saved
        if next.contains(id) { next.remove(id) } else { next.insert(id) }
        // Sorted so the stored string is stable: an unordered set would rewrite the
        // defaults value on every toggle even when the membership had not changed.
        savedIDs = next.sorted().map(String.init).joined(separator: ",")
    }
}

// MARK: - Search

struct MarketSearchScreen: View {
    let model: AppModel
    let market: MarketModel
    let session: TradingSession
    @State private var query = ""
    @State private var showsMarket = false
    @AppStorage("desk.watchlist") private var savedIDs = ""

    private var saved: Set<UInt32> {
        Set(savedIDs.split(separator: ",").compactMap { UInt32($0) })
    }

    private var results: [Market] {
        guard !query.isEmpty else { return market.allMarkets }
        return market.allMarkets.filter {
            $0.symbol.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                DeskBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Search")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 10)

                    Text("Perp Cards")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                        .padding(.top, 32)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(Array(market.allMarkets.prefix(4)), id: \.id) { entry in
                                Button { open(entry) } label: {
                                    SearchMarketCard(model: market, market: entry)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .contentMargins(.horizontal, 0)
                    .padding(.top, 12)

                    HStack {
                        Text("All Perpl Markets")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                        Spacer()
                        Text("\(market.allMarkets.count) live")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(DeskColor.nightMuted.color)
                    }
                    .foregroundStyle(DeskColor.nightText.color)
                    .padding(.top, 30)

                    field.padding(.top, 12)

                    if market.allMarkets.isEmpty {
                        // Still loading the context. Skeletons rather than "no results",
                        // which would be a claim about the venue.
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(0..<4, id: \.self) { SkeletonRow(widthFraction: 0.8 - Double($0) * 0.1) }
                        }
                        .padding(.top, 28)
                    } else if results.isEmpty {
                        Text("No market matches “\(query)”.")
                            .font(DeskType.caption)
                            .foregroundStyle(DeskColor.nightMuted.color)
                            .padding(.top, 28)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(results, id: \.id) { entry in
                                MarketRow(
                                    model: market,
                                    market: entry,
                                    isSaved: saved.contains(entry.id),
                                    onOpen: { open(entry) },
                                    onToggle: { toggle(entry.id) })
                            }
                        }
                        .padding(.top, 20)
                    }

                    Text("Perpl testnet currently exposes these seven perpetual markets. "
                         + "Discovery tokens from other networks are separate from tradeable Perpl contracts.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 24)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 130)
            }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showsMarket) {
                PerpDetailScreen(model: model, market: market, session: session)
                    .toolbar(.hidden, for: .tabBar)
            }
        }
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DeskColor.nightMuted.color)
            TextField("", text: $query, prompt: Text("Search markets")
                .foregroundStyle(DeskColor.nightMuted.color))
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(DeskColor.nightText.color)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DeskColor.nightMuted.color)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(DeskColor.nightChip.color.opacity(0.6), in: Capsule())
        .overlay(Capsule().stroke(DeskColor.nightLine.color, lineWidth: 0.5))
    }

    private func toggle(_ id: UInt32) {
        var next = saved
        if next.contains(id) { next.remove(id) } else { next.insert(id) }
        // Sorted so the stored string is stable: an unordered set would rewrite the
        // defaults value on every toggle even when the membership had not changed.
        savedIDs = next.sorted().map(String.init).joined(separator: ",")
    }

    private func open(_ entry: Market) {
        market.select(entry)
        Task { await session.selectMarket(entry) }
        showsMarket = true
    }
}

// MARK: - One market

/// A market as the venue reports it: its own price, its own leverage ceiling.
///
/// The leverage figure comes from `initialMarginFraction`, which the venue encodes as a
/// divisor in hundredths — 1500 is 15×, not 15%. The hard-coded version of this screen
/// claimed 40× for Bitcoin, which is not a number Perpl would accept.
private struct MarketRow: View {
    let model: MarketModel
    let market: Market
    let isSaved: Bool
    let onOpen: () -> Void
    let onToggle: () -> Void

    private var price: String {
        let value = model.markText(for: market)
        return value == "—" ? value : "$" + value
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onOpen) {
                HStack(spacing: 13) {
                    MarketTokenLogo(symbol: market.symbol, size: 38)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(market.symbol)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)

                    Text("MAX \(market.config.maxLeverage)×")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(Capsule().stroke(DeskColor.nightLine.color, lineWidth: 0.7))
                }

                Text("Tradeable on Perpl")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(DeskColor.rise.color)
            }

                    Spacer(minLength: 8)

                    Text(price)
                        .font(.system(size: 15, weight: .bold).monospacedDigit())
                        .foregroundStyle(DeskColor.nightText.color)
                        .contentTransition(.numericText())
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onToggle) {
                Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isSaved ? DeskColor.action.color : DeskColor.nightMuted.color)
                    .frame(width: 34, height: 34)
            }
            .accessibilityLabel(isSaved ? "Remove \(market.symbol) from watchlist"
                                        : "Save \(market.symbol) to watchlist")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(DeskColor.nightChip.color.opacity(0.5),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(DeskColor.nightLine.color, lineWidth: 0.5))
    }

    /// A colour per symbol so rows are told apart before they are read. Derived from the
    /// symbol rather than kept in a table, so a market the venue adds still gets one.
    static func tint(for symbol: String) -> Color {
        let seed = AddressAvatar.seed(for: symbol)
        return Color(hue: seed.primary / 360, saturation: 0.55, brightness: 0.85)
    }
}

private struct SearchMarketCard: View {
    let model: MarketModel
    let market: Market

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                MarketTokenLogo(symbol: market.symbol, size: 44)
                Spacer()
                if let change = model.changePercent(for: market) {
                    Text(String(format: "%+.2f%%", change))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(change >= 0 ? DeskColor.rise.color : DeskColor.fall.color)
                }
            }
            Spacer()
            Text(market.symbol)
                .font(.system(size: 21, weight: .bold, design: .rounded))
            HStack {
                let price = model.markText(for: market)
                Text(price == "—" ? price : "$" + price)
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .lineLimit(1).minimumScaleFactor(0.72)
                Spacer()
                Text("MAX \(market.config.maxLeverage)×")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .overlay(Capsule().stroke(Color.white.opacity(0.16)))
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(DeskColor.nightText.color)
        .padding(16)
        .frame(width: 188, height: 190)
        .perpSearchGlass(in: RoundedRectangle(cornerRadius: 25, style: .continuous))
    }
}

private extension View {
    @ViewBuilder
    func perpSearchGlass<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) { glassEffect(.regular, in: shape) }
        else { background(.ultraThinMaterial, in: shape) }
    }
}
