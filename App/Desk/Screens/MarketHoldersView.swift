import DeskUI
import Observation
import SwiftUI

struct MarketHolder: Decodable, Identifiable, Hashable, Sendable {
    let accountId: String
    let address: String?
    let market: String
    let marketId: Int
    let side: String
    let entry: String
    let mark: String
    let size: String
    let collateral: String
    let value: String
    let pnl: String
    let pnlPercent: Double?
    let leverage: Double?
    let entryBlock: Int?

    var id: String { accountId }
    var isLong: Bool { side == "long" }
    var isProfit: Bool { !pnl.hasPrefix("-") }
    var sideText: String {
        let lever = leverage.map { $0.rounded() == $0 ? "\(Int($0))x" : String(format: "%.1fx", $0) } ?? ""
        return "\(lever) \(isLong ? "Long" : "Short")".trimmingCharacters(in: .whitespaces)
    }
}

@MainActor
@Observable
final class MarketHoldersModel {
    private struct Response: Decodable {
        let holders: [MarketHolder]
        let count: Int
        let complete: Bool
        let longValue: String
        let shortValue: String
    }

    private(set) var holders: [MarketHolder] = []
    private(set) var count = 0
    private(set) var longValue = 0.0
    private(set) var shortValue = 0.0
    private(set) var loaded = false
    private(set) var symbol = ""

    func run(symbol: String) async {
        if self.symbol != symbol {
            self.symbol = symbol
            holders = []
            loaded = false
        }
        while !Task.isCancelled {
            await load(symbol: symbol)
            try? await Task.sleep(for: .seconds(30))
        }
    }

    func load(symbol: String) async {
        var components = URLComponents(string: "https://web-lovat-nine-49.vercel.app/api/traders")!
        components.queryItems = [URLQueryItem(name: "view", value: "holders"), URLQueryItem(name: "market", value: symbol)]
        guard let url = components.url,
              let (data, _) = try? await ResponseCache.shared.data(from: url, maxStale: 600),
              let body = try? JSONDecoder().decode(Response.self, from: data) else { loaded = true; return }
        guard !Task.isCancelled else { return }
        holders = body.holders
        count = body.count
        longValue = Double(body.longValue) ?? 0
        shortValue = Double(body.shortValue) ?? 0
        loaded = true
        Task { await IdentityDirectory.shared.resolve(body.holders.compactMap(\.address)) }
    }
}

struct MarketHoldersList: View {
    let model: MarketHoldersModel
    let directory: TraderDirectory
    let onOpen: (MarketHolder) -> Void
    @State private var friendsOnly = false

    private func isFriend(_ holder: MarketHolder) -> Bool {
        guard let address = holder.address else { return false }
        return directory.isFollowing(address) || TrackedWallets.shared.isTracking(address)
    }

    private var rows: [MarketHolder] { friendsOnly ? model.holders.filter(isFriend) : model.holders }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Toggle("Friends", isOn: $friendsOnly).labelsHidden().tint(DeskColor.action.color)
                Text("Friends")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
                Spacer()
                Text("Leveraged size")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
            .padding(.vertical, 12)

            if !model.loaded {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(0..<4, id: \.self) { SkeletonRow(widthFraction: 0.9 - Double($0) * 0.12) }
                }
                .padding(.top, 10)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, holder in
                        Button { onOpen(holder) } label: {
                            HolderRow(holder: holder, name: holder.address.map(directory.name(for:)) ?? "Account \(holder.accountId)",
                                      isLast: index == rows.count - 1)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private struct HolderRow: View {
    let holder: MarketHolder
    let name: String
    let isLast: Bool

    private var sideTint: Color { (holder.isLong ? DeskColor.rise : DeskColor.fall).color }

    var body: some View {
        HStack(spacing: 12) {
            if let address = holder.address {
                TraderAvatar(address: address, size: 44)
            } else {
                Circle().fill(Color.white.opacity(0.1)).frame(width: 44, height: 44)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(name)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(holder.sideText)
                        .fixedSize()
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(sideTint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(sideTint.opacity(0.16), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                Text("Avg. entry: $\(TraderFormat.price(holder.entry))")
                    .font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                Text(TraderFormat.dollars(holder.value, signed: false))
                    .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(DeskColor.nightText.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(TraderFormat.dollars(holder.pnl))
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle((holder.isProfit ? DeskColor.rise : DeskColor.fall).color)
            }
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            if !isLast { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5).padding(.leading, 56) }
        }
        .contentShape(Rectangle())
    }
}

/// One holder's position on this market, the way they would see it themselves.
struct HolderPositionSheet: View {
    let holder: MarketHolder
    let market: MarketModel
    let directory: TraderDirectory
    @State private var history: TraderHistory?
    @State private var showsProfile = false

    private var name: String { holder.address.map(directory.name(for:)) ?? "Account \(holder.accountId)" }
    private var sideTint: Color { (holder.isLong ? DeskColor.rise : DeskColor.fall).color }
    private var pnlTint: Color { (holder.isProfit ? DeskColor.rise : DeskColor.fall).color }
    private var scale: Double { pow(10.0, Double(market.market?.config.priceDecimals ?? 2)) }

    private var liquidation: Double? {
        guard let entry = Double(holder.entry), let size = Double(holder.size), size > 0,
              let collateral = Double(holder.collateral), let config = market.market?.config else { return nil }
        let maintenance = entry * config.maintenanceMarginPercent / 100
        let cushion = collateral / size
        let price = holder.isLong ? entry - cushion + maintenance : entry + cushion - maintenance
        return price > 0 ? price : nil
    }

    private var guides: [PriceGuide] {
        var out: [PriceGuide] = []
        if let entry = Double(holder.entry) {
            out.append(PriceGuide(label: "Avg. entry", value: entry, text: PriceAxis.label(entry), tint: .white.opacity(0.8)))
        }
        if let liquidation {
            out.append(PriceGuide(label: "Liq.", value: liquidation, text: PriceAxis.label(liquidation), tint: DeskColor.fall.color))
        }
        return out
    }

    private var closedHere: [TraderHistory.Trade] {
        (history?.trades ?? []).filter { $0.market.caseInsensitiveCompare(holder.market) == .orderedSame }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        who
                        marketRow.padding(.top, 22)
                        chart.padding(.top, 18)
                        CandleIntervalRail(market: market).padding(.top, 16)
                        card.padding(.top, 22)
                        if !closedHere.isEmpty { closed.padding(.top, 26) }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 40)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showsProfile) {
                if let copier = CopyTrader.current, let address = holder.address {
                    TraderProfileScreen(
                        initial: TraderSnapshot(accountId: holder.accountId, address: address, pnl: nil, balance: nil, positions: []),
                        directory: directory, copier: copier, onCopy: { _ in })
                }
            }
            .task {
                guard let address = holder.address else { return }
                await IdentityDirectory.shared.resolve([address])
                var components = URLComponents(string: "https://web-lovat-nine-49.vercel.app/api/traders")!
                components.queryItems = [URLQueryItem(name: "view", value: "history"), URLQueryItem(name: "address", value: address)]
                guard let url = components.url,
                      let (data, _) = try? await ResponseCache.shared.data(from: url, maxStale: 3_600) else { return }
                history = try? JSONDecoder().decode(TraderHistory.self, from: data)
            }
        }
    }

    private var who: some View {
        HStack(spacing: 12) {
            Button { if holder.address != nil, CopyTrader.current != nil { showsProfile = true } } label: {
                HStack(spacing: 10) {
                    if let address = holder.address { TraderAvatar(address: address, size: 40) }
                    Text(name)
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                        .lineLimit(1)
                    if holder.address != nil {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(DeskColor.nightMuted.color)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            if let address = holder.address {
                let following = directory.isFollowing(address)
                Button {
                    directory.toggle(address)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Text(following ? "Following" : "Follow")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(following ? DeskColor.nightText.color : .white)
                        .padding(.horizontal, 18)
                        .frame(height: 40)
                        .background(following ? Color.white.opacity(0.1) : DeskColor.action.color,
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var marketRow: some View {
        HStack(spacing: 12) {
            MarketTokenLogo(symbol: holder.market, size: 46)
            VStack(alignment: .leading, spacing: 6) {
                Text(holder.market)
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
                HStack(spacing: 5) {
                    Text("Open")
                    Circle().frame(width: 5, height: 5)
                }
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(DeskColor.action.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(DeskColor.action.color.opacity(0.16), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(market.markText == "—" ? "—" : "$" + market.markText)
                    .font(.system(size: 21, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(DeskColor.nightText.color)
                Text(market.changePercentText ?? "—")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(market.trend.color)
            }
        }
    }

    @ViewBuilder private var chart: some View {
        if !market.candles.isEmpty {
            CandlestickChart(candles: market.candles.map { $0.chartCandle(scale: scale) }, guides: guides)
                .frame(height: 230)
        } else {
            VStack(spacing: 16) { SkeletonRow(widthFraction: 0.88); SkeletonRow(widthFraction: 0.64) }.frame(height: 230)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(holder.sideText)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(sideTint)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(sideTint.opacity(0.16), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(TraderFormat.dollars(holder.collateral, signed: false))
                        .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(DeskColor.nightText.color)
                    HStack(spacing: 4) {
                        Text("Lev. size").foregroundStyle(DeskColor.nightMuted.color)
                        Text(TraderFormat.compact(Double(holder.value))).foregroundStyle(DeskColor.nightText.color)
                        Text("(\(holder.size) \(holder.market))").foregroundStyle(DeskColor.nightMuted.color)
                    }
                    .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(TraderFormat.dollars(holder.pnl))
                        .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(pnlTint)
                    if let percent = holder.pnlPercent {
                        HStack(spacing: 3) {
                            Image(systemName: percent >= 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill").font(.system(size: 9))
                            Text(String(format: "%.2f%%", abs(percent)))
                        }
                        .font(.system(size: 14, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(pnlTint)
                    }
                }
            }
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 0.5).padding(.vertical, 2)
            HStack {
                HStack(spacing: 8) {
                    Text("Avg. entry").foregroundStyle(DeskColor.nightMuted.color)
                    Text("$" + TraderFormat.price(holder.entry)).foregroundStyle(DeskColor.nightText.color)
                }
                Spacer()
                HStack(spacing: 8) {
                    Text("Liq. price").foregroundStyle(DeskColor.nightMuted.color)
                    Text(liquidation.map { "$" + TraderFormat.price(String($0)) } ?? "—").foregroundStyle(DeskColor.nightText.color)
                }
            }
            .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
        }
        .padding(18)
        .background(DeskColor.nightChip.color.opacity(0.6), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(DeskColor.nightLine.color, lineWidth: 0.5))
    }

    private var closed: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Closed on \(holder.market)")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(DeskColor.nightText.color)
                .padding(.bottom, 6)
            ForEach(Array(closedHere.prefix(8).enumerated()), id: \.element.id) { index, trade in
                HStack(spacing: 10) {
                    Text("\(trade.isLong ? "Long" : "Short") \(TraderFormat.leverage(trade.leverage))")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle((trade.isLong ? DeskColor.rise : DeskColor.fall).color)
                    if let entry = trade.entry, let exit = trade.exit {
                        Text("\(PriceAxis.label(entry)) → \(PriceAxis.label(exit))")
                            .font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
                            .foregroundStyle(DeskColor.nightMuted.color)
                    }
                    Spacer()
                    Text(TraderFormat.compact(trade.pnl, signed: true))
                        .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle((trade.pnl >= 0 ? DeskColor.rise : DeskColor.fall).color)
                    if let date = trade.date {
                        Text(date.formatted(.relative(presentation: .numeric)))
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(DeskColor.nightMuted.color)
                    }
                }
                .padding(.vertical, 11)
                .overlay(alignment: .bottom) {
                    if index < min(closedHere.count, 8) - 1 { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5) }
                }
            }
        }
    }
}
