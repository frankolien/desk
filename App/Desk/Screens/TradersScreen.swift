import DeskUI
import Observation
import SwiftUI
import UIKit

struct TraderPosition: Decodable, Hashable, Identifiable, Sendable {
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

    var id: String { "\(marketId)-\(side)" }
    var isLong: Bool { side == "long" }
    var isProfit: Bool { !pnl.hasPrefix("-") }
}

struct TraderSnapshot: Decodable, Hashable, Identifiable, Sendable {
    let accountId: String?
    let address: String
    let pnl: String?
    let balance: String?
    let positions: [TraderPosition]

    var id: String { address.lowercased() }
    var isProfit: Bool { !(pnl ?? "").hasPrefix("-") }
    var shortAddress: String { TraderSnapshot.short(address) }

    /// Free balance plus what every open position is worth to its owner: collateral and PnL.
    var portfolio: Double? {
        guard let balance = balance.flatMap(Double.init) else { return nil }
        return positions.reduce(balance) { $0 + (Double($1.collateral) ?? 0) + (Double($1.pnl) ?? 0) }
    }

    var positionValue: Double { positions.reduce(0) { $0 + (Double($1.value) ?? 0) } }

    static func short(_ address: String) -> String {
        address.count > 12 ? "\(address.prefix(6))…\(address.suffix(4))" : address
    }
}

/// Traders on Perpl mainnet, read live from the exchange contract through Desk's server.
/// Who you follow stays on this phone; the server only ever sees the addresses asked about.
@MainActor
@Observable
final class TraderDirectory {
    private(set) var top: [TraderSnapshot] = []
    private(set) var topProblem: String?
    private(set) var following: [TraderSnapshot] = []
    private(set) var followed: [String]
    /// Names given on this phone. Perpl accounts have no public profile to read one from.
    private(set) var nicknames: [String: String]

    private static let storageKey = "desk.followedTraders"
    private static let nicknameKey = "desk.traderNicknames"
    private static let endpoint = "https://web-lovat-nine-49.vercel.app/api/traders"

    init() {
        followed = UserDefaults.standard.stringArray(forKey: Self.storageKey) ?? []
        nicknames = UserDefaults.standard.dictionary(forKey: Self.nicknameKey) as? [String: String] ?? [:]
    }

    func name(for address: String) -> String {
        nicknames[address.lowercased()] ?? TraderSnapshot.short(address)
    }

    func hasNickname(_ address: String) -> Bool { nicknames[address.lowercased()] != nil }

    func setNickname(_ name: String, for address: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        nicknames[address.lowercased()] = trimmed.isEmpty ? nil : String(trimmed.prefix(24))
        UserDefaults.standard.set(nicknames, forKey: Self.nicknameKey)
        if TradeAlerts.shared.isOn(for: address) { TradeAlerts.shared.namesChanged() }
    }

    func isFollowing(_ address: String) -> Bool {
        followed.contains { $0.caseInsensitiveCompare(address) == .orderedSame }
    }

    func toggle(_ address: String) {
        if isFollowing(address) {
            followed.removeAll { $0.caseInsensitiveCompare(address) == .orderedSame }
            following.removeAll { $0.id == address.lowercased() }
            TradeAlerts.shared.turnOff(for: address)
        } else {
            guard followed.count < 20 else { return }
            followed.append(address)
            if let known = top.first(where: { $0.id == address.lowercased() }) { following.append(known) }
        }
        UserDefaults.standard.set(followed, forKey: Self.storageKey)
        Task { await refreshFollowing() }
    }

    func run() async {
        while !Task.isCancelled {
            async let top: Void = refreshTop()
            async let following: Void = refreshFollowing()
            _ = await (top, following)
            try? await Task.sleep(for: .seconds(20))
        }
    }

    func refreshTop() async {
        guard let traders = await fetch(["view": "top"]) else {
            if top.isEmpty { topProblem = "Perpl mainnet could not be read right now." }
            return
        }
        topProblem = nil
        top = traders
    }

    func refreshFollowing() async {
        guard !followed.isEmpty else { following = []; return }
        guard let traders = await fetch(["view": "following", "addresses": followed.joined(separator: ",")]) else { return }
        following = traders.filter { isFollowing($0.address) }
    }

    func trader(_ address: String) async -> TraderSnapshot? {
        await fetch(["view": "trader", "address": address])?.first
    }

    private func fetch(_ query: [String: String]) async -> [TraderSnapshot]? {
        var components = URLComponents(string: Self.endpoint)!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try? JSONDecoder().decode(TradersResponse.self, from: data) else { return nil }
        return body.traders
    }

    private struct TradersResponse: Decodable { let traders: [TraderSnapshot] }
}

@MainActor
enum TraderFormat {
    private static func decimal(fractionDigits: ClosedRange<Int>) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = fractionDigits.lowerBound
        formatter.maximumFractionDigits = fractionDigits.upperBound
        return formatter
    }

    private static let prices = [decimal(fractionDigits: 0...2), decimal(fractionDigits: 0...4), decimal(fractionDigits: 0...6)]

    static func dollars(_ text: String?, signed: Bool = true) -> String {
        guard let text, let value = Double(text) else { return Unavailable.text }
        return DisplayCurrency.shared.format(value, signed: signed)
    }

    static func price(_ text: String) -> String {
        guard let value = Double(text) else { return text }
        let formatter = value >= 100 ? prices[0] : (value >= 1 ? prices[1] : prices[2])
        return formatter.string(from: NSNumber(value: value)) ?? text
    }

    /// $14.9K, $326K, $1.2M: the compact form for headline figures.
    static func compact(_ value: Double?, signed: Bool = false) -> String {
        guard let value else { return Unavailable.text }
        return DisplayCurrency.shared.format(value, signed: signed, compact: true)
    }

    static func assetName(_ symbol: String) -> String {
        switch symbol.uppercased() {
        case "BTC": "Bitcoin"
        case "ETH": "Ethereum"
        case "SOL": "Solana"
        case "MON": "Monad"
        case "HYPE": "Hyperliquid"
        case "ZEC": "Zcash"
        case "LIT": "Lighter"
        case "PUMP": "Pump.fun"
        default: symbol
        }
    }

    static func leverage(_ value: Double?) -> String {
        guard let value else { return "" }
        return value.rounded() == value ? "\(Int(value))×" : String(format: "%.1f×", value)
    }
}

/// A blocky mark drawn from the address, the convention wallets already use, so a trader is
/// recognisable without a picture or a name anyone invented.
struct TraderAvatar: View {
    let address: String
    var size: CGFloat = 42

    private var seed: [UInt8] {
        let hex = address.lowercased().dropFirst(2)
        return hex.compactMap { UInt8(String($0), radix: 16) }
    }

    /// One bit per cell from the address's own nibbles, so the pattern is as varied as the
    /// address and never repeats a row.
    private func filled(row: Int, column: Int) -> Bool {
        guard !seed.isEmpty else { return false }
        let bit = row * 4 + column
        let nibble = seed[(6 + bit / 4 * 3 + column) % seed.count]
        return (nibble >> UInt8(bit % 4)) & 1 == 1
    }

    private var tint: Color {
        let hue = Double(seed.prefix(6).reduce(0) { ($0 * 16 + Int($1)) % 360 }) / 360
        return Color(hue: hue, saturation: 0.42, brightness: 0.82)
    }

    var body: some View {
        Canvas { context, canvas in
            let cells = 7
            let cell = canvas.width / CGFloat(cells + 3)
            let inset = cell * 1.5
            for row in 0..<cells {
                for column in 0..<4 where filled(row: row, column: column) {
                    for mirrored in Set([column, cells - 1 - column]) {
                        let rect = CGRect(x: inset + cell * CGFloat(mirrored), y: inset + cell * CGFloat(row),
                                          width: cell + 0.5, height: cell + 0.5)
                        context.fill(Path(rect), with: .color(tint))
                    }
                }
            }
        }
        .background(tint.opacity(0.16))
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.08), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

struct TradersFeed: View {
    let directory: TraderDirectory
    let copier: CopyTrader
    let onOpenCopying: () -> Void
    let onSelect: (TraderSnapshot) -> Void

    private var followedSnapshots: [TraderSnapshot] {
        directory.followed.map { address in
            directory.following.first { $0.id == address.lowercased() }
                ?? TraderSnapshot(accountId: nil, address: address, pnl: nil, balance: nil, positions: [])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !copier.traders.isEmpty || !copier.log.isEmpty {
                CopyStatusCard(copier: copier, onOpen: onOpenCopying)
                    .padding(.bottom, 24)
            }
            if !directory.followed.isEmpty {
                header("Following", trailing: "\(directory.followed.count)")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(followedSnapshots) { trader in
                            FollowedCard(trader: trader, name: directory.name(for: trader.address),
                                         isAlerting: TradeAlerts.shared.isOn(for: trader.address)) { onSelect(trader) }
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.horizontal, -20)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }

            header("Top traders", trailing: "Open PnL")

            if directory.top.isEmpty, let problem = directory.topProblem {
                Label(problem, systemImage: "exclamationmark.circle.fill")
                    .font(DeskType.caption)
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .padding(.top, 14)
            } else {
                LazyVStack(spacing: 0) {
                    if directory.top.isEmpty {
                        ForEach(0..<8, id: \.self) { index in
                            LeaderRow(trader: TraderSnapshot(accountId: nil, address: "0x00000000000000000000000000000000000000\(index)0",
                                                             pnl: "1000", balance: nil, positions: []),
                                      rank: index + 1, name: "0x0000…0000", isLast: index == 7)
                                .redacted(reason: .placeholder)
                        }
                    } else {
                        ForEach(Array(directory.top.enumerated()), id: \.element.id) { index, trader in
                            Button { onSelect(trader) } label: {
                                LeaderRow(trader: trader, rank: index + 1, name: directory.name(for: trader.address),
                                          isFollowed: directory.isFollowing(trader.address),
                                          isLast: index == directory.top.count - 1)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.top, 6)
            }

            Text("Live from Perpl mainnet. PnL is on open positions, funding included. Copying a trade opens your own ticket.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(DeskColor.nightMuted.color.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 18)
        }
    }

    private func header(_ title: String, trailing: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(DeskColor.nightText.color)
            Spacer()
            Text(trailing)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(DeskColor.nightMuted.color)
        }
    }
}

private struct FollowedCard: View {
    let trader: TraderSnapshot
    let name: String
    let isAlerting: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    TraderAvatar(address: trader.address, size: 36)
                    Spacer(minLength: 0)
                    if isAlerting {
                        Image(systemName: "bell.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.5))
                            .accessibilityLabel("Alerts on")
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                        .lineLimit(1)
                    Text(trader.pnl == nil ? "Loading" : TraderFormat.compact(trader.pnl.flatMap(Double.init), signed: true))
                        .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(trader.pnl == nil ? DeskColor.nightMuted.color
                                         : (trader.isProfit ? DeskColor.rise : DeskColor.fall).color)
                }
            }
            .padding(14)
            .frame(width: 138, alignment: .leading)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct LeaderRow: View {
    let trader: TraderSnapshot
    let rank: Int
    let name: String
    var isFollowed = false
    let isLast: Bool

    private var detail: String {
        let count = trader.positions.count
        let noun = count == 1 ? "position" : "positions"
        return "\(count) \(noun) · \(TraderFormat.compact(trader.positionValue))"
    }

    var body: some View {
        HStack(spacing: 14) {
            Text("\(rank)")
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(rank <= 3 ? DeskColor.nightText.color : DeskColor.nightMuted.color)
                .frame(width: 20, alignment: .leading)
            TraderAvatar(address: trader.address, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                        .lineLimit(1)
                    if isFollowed {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(DeskColor.nightMuted.color)
                    }
                }
                Text(detail)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
            Spacer(minLength: 8)
            Text(TraderFormat.compact(trader.pnl.flatMap(Double.init), signed: true))
                .font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle((trader.isProfit ? DeskColor.rise : DeskColor.fall).color)
        }
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5).padding(.leading, 78)
            }
        }
        .contentShape(Rectangle())
    }
}

struct TraderProfileScreen: View {
    let initial: TraderSnapshot
    let directory: TraderDirectory
    let copier: CopyTrader
    let onCopy: (TraderPosition) -> Void

    private enum Tab: String, CaseIterable { case positions = "Positions", closed = "Closed", activity = "Activity" }

    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: TraderSnapshot?
    @State private var tab: Tab = .positions
    @State private var isNaming = false
    @State private var draftName = ""
    @State private var pendingCopy: TraderPosition?
    @State private var showsAlertsPrimer = false
    @State private var showsAutoCopy = false
    @State private var showsNotificationsOff = false

    private var alerts: TradeAlerts { .shared }
    private var alerting: Bool { alerts.isOn(for: trader.address) }

    private var trader: TraderSnapshot { snapshot ?? initial }
    private var following: Bool { directory.isFollowing(trader.address) }
    private var explorerURL: URL { URL(string: "https://monadvision.com/address/\(trader.address)")! }

    var body: some View {
        ZStack {
            DeskBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    topBar.padding(.horizontal, 20)
                    identity.padding(.horizontal, 20).padding(.top, 20)
                    AutoCopyButton(rules: copier.rules(for: trader.address)) { showsAutoCopy = true }
                        .padding(.horizontal, 20)
                        .padding(.top, 18)
                    tabs.padding(.top, 24)
                    content
                }
                .padding(.bottom, 60)
            }
            .refreshable { snapshot = await directory.trader(trader.address) ?? snapshot }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task {
            while !Task.isCancelled {
                if let fresh = await directory.trader(initial.address) { snapshot = fresh }
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .alert("Name this trader", isPresented: $isNaming) {
            TextField(trader.shortAddress, text: $draftName)
            Button("Save") { directory.setNickname(draftName, for: trader.address) }
            if directory.hasNickname(trader.address) {
                Button("Remove name", role: .destructive) { directory.setNickname("", for: trader.address) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only you see this name.")
        }
        .confirmationDialog(
            pendingCopy.map { "Copy \($0.isLong ? "long" : "short") \($0.market) at \(TraderFormat.leverage($0.leverage))" } ?? "",
            isPresented: Binding(get: { pendingCopy != nil }, set: { if !$0 { pendingCopy = nil } }),
            titleVisibility: .visible
        ) {
            Button("Open ticket") { if let position = pendingCopy { onCopy(position) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Same market, side and leverage on your own account. You choose the amount.")
        }
        .task { await alerts.refreshPermission() }
        .sheet(isPresented: $showsAutoCopy) {
            AutoCopySheet(address: trader.address, name: directory.name(for: trader.address), copier: copier)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showsAlertsPrimer) {
            AlertsPrimerSheet(
                trader: trader, name: directory.name(for: trader.address),
                onEnable: {
                    alerts.hasSeenPrimer = true
                    showsAlertsPrimer = false
                    Task { await turnOnAlerts() }
                },
                onLater: {
                    alerts.hasSeenPrimer = true
                    showsAlertsPrimer = false
                })
                .presentationDetents([.height(500)])
                .presentationDragIndicator(.visible)
        }
        .alert("Notifications are off for Desk", isPresented: $showsNotificationsOff) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Turn them on in Settings to hear when \(directory.name(for: trader.address)) trades.")
        }
        .alert("Alerts aren't saved", isPresented: Binding(
            get: { alerts.problem != nil },
            set: { if !$0 { alerts.problem = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alerts.problem ?? "")
        }
    }

    private func toggleAlerts() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if alerting {
            withAnimation(.snappy(duration: 0.2)) { alerts.turnOff(for: trader.address) }
        } else if alerts.permission == .denied {
            showsNotificationsOff = true
        } else if !alerts.hasSeenPrimer {
            showsAlertsPrimer = true
        } else {
            Task { await turnOnAlerts() }
        }
    }

    private func turnOnAlerts() async {
        if !(await alerts.turnOn(for: trader.address)) { showsNotificationsOff = true }
    }

    private var topBar: some View {
        HStack {
            circleButton("chevron.left") { dismiss() }
            Spacer()
            ShareLink(item: explorerURL, message: Text("\(directory.name(for: trader.address)) on Perpl")) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .deskGlass(interactive: true, in: Circle())
        }
        .padding(.top, 6)
    }

    private func circleButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .deskGlass(interactive: true, in: Circle())
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                TraderAvatar(address: trader.address, size: 64)
                Spacer(minLength: 12)
                stat(TraderFormat.compact(trader.portfolio), label: "Portfolio")
                Rectangle().fill(Color.white.opacity(0.1)).frame(width: 0.5, height: 40)
                stat(TraderFormat.compact(trader.pnl.flatMap(Double.init), signed: true), label: "Open PnL",
                     tint: trader.pnl == nil ? .white : (trader.isProfit ? DeskColor.rise : DeskColor.fall).color)
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    nameBlock.fixedSize()
                    Spacer(minLength: 0)
                    actions.padding(.top, 20)
                }
                VStack(alignment: .leading, spacing: 16) {
                    nameBlock
                    actions
                }
            }
            .padding(.top, 12)
        }
    }

    private var nameBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(directory.name(for: trader.address))
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
            Button {
                UIPasteboard.general.string = trader.address
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Text(directory.hasNickname(trader.address) ? trader.shortAddress
                     : "Perpl account \(trader.accountId.map { "#\($0)" } ?? "")")
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HStack(spacing: 7) {
                Circle()
                    .fill(trader.positions.isEmpty ? Color.white.opacity(0.35) : DeskColor.rise.color)
                    .frame(width: 7, height: 7)
                Text(trader.positions.isEmpty ? "No open positions" : "In the market")
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.55))
            }
            .padding(.top, 2)
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            outlineButton(following ? "Following" : "Follow", symbol: nil) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                let starting = !following
                withAnimation(.snappy(duration: 0.2)) { directory.toggle(trader.address) }
                if starting && !alerts.hasSeenPrimer && alerts.permission != .denied { showsAlertsPrimer = true }
            }
            if following {
                Button(action: toggleAlerts) {
                    Image(systemName: alerting ? "bell.fill" : "bell")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 36, height: 30)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .deskGlass(interactive: true, in: Capsule())
                .accessibilityLabel(alerting ? "Turn off trade alerts" : "Turn on trade alerts")
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
            outlineButton("Set Name", symbol: "pencil") {
                draftName = directory.nicknames[trader.address.lowercased()] ?? ""
                isNaming = true
            }
        }
    }

    private func stat(_ value: String, label: String, tint: Color = .white) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity)
    }

    private func outlineButton(_ title: String, symbol: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .frame(height: 30)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .deskGlass(interactive: true, in: Capsule())
    }

    private var tabs: some View {
        Picker("Show", selection: $tab.animation(.snappy(duration: 0.22))) {
            ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .positions:
            if trader.positions.isEmpty {
                emptyState(snapshot == nil ? "Loading positions…" : "Nothing open right now.",
                           detail: snapshot == nil ? nil : "Positions appear here the moment this trader opens one.")
            } else {
                // Plain rows, the first version. Kept to compare against the cards below.
                // LazyVStack(spacing: 0) {
                //     ForEach(Array(trader.positions.enumerated()), id: \.element.id) { index, position in
                //         Button { pendingCopy = position } label: {
                //             ProfilePositionRow(position: position, isLast: index == trader.positions.count - 1)
                //         }
                //         .buttonStyle(.plain)
                //     }
                // }
                // .padding(.top, 6)
                LazyVStack(spacing: 10) {
                    ForEach(trader.positions) { position in
                        ProfilePositionCard(position: position) { pendingCopy = position }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
            }
        case .closed:
            emptyState("Closed trades aren't shown yet",
                       detail: "Desk reads open positions straight from Perpl. Trade history needs an indexer, which is coming.")
        case .activity:
            emptyState("Activity isn't shown yet",
                       detail: "Opens, adds and closes will appear here once trade history is indexed.")
        }
    }

    private func emptyState(_ title: String, detail: String?) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            if let detail {
                Text(detail)
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 48)
    }
}

private struct ProfilePositionRow: View {
    let position: TraderPosition
    let isLast: Bool

    var body: some View {
        HStack(spacing: 16) {
            MarketTokenLogo(symbol: position.market, size: 50)
            VStack(alignment: .leading, spacing: 4) {
                Text(TraderFormat.assetName(position.market))
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(position.isLong ? "Long" : "Short") \(TraderFormat.leverage(position.leverage)) · \(position.size) \(position.market)")
                    .font(.system(size: 15, weight: .regular, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(TraderFormat.dollars(position.value, signed: false))
                    .font(.system(size: 18, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                Text(TraderFormat.dollars(position.pnl))
                    .font(.system(size: 14, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle((position.isProfit ? DeskColor.rise : DeskColor.fall).color)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5).padding(.leading, 86).padding(.trailing, 20)
            }
        }
        .contentShape(Rectangle())
    }
}

/// A position with everything a copier weighs: side and leverage, PnL, what it is worth,
/// the size and collateral behind it, and where it was entered against where it is now.
private struct ProfilePositionCard: View {
    let position: TraderPosition
    let onCopy: () -> Void

    private var sideTint: DeskRGB { position.isLong ? DeskColor.rise : DeskColor.fall }
    private var pnlTint: DeskRGB { position.isProfit ? DeskColor.rise : DeskColor.fall }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                MarketTokenLogo(symbol: position.market, size: 28)
                Text("\(position.market)-PERP")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("\(position.isLong ? "Long" : "Short") \(TraderFormat.leverage(position.leverage))")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(sideTint.color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(sideTint.color.opacity(0.14), in: Capsule())
                Spacer(minLength: 6)
                Button(action: onCopy) {
                    Label("Copy", systemImage: "square.on.square")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .deskGlass(interactive: true, in: Capsule())
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(TraderFormat.dollars(position.pnl))
                    .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(pnlTint.color)
                    .contentTransition(.numericText())
                if let percent = position.pnlPercent {
                    Text(String(format: "%@%.1f%%", percent < 0 ? Direction.minus : "+", abs(percent)))
                        .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(pnlTint.color.opacity(0.85))
                }
            }

            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    figure("Value", TraderFormat.dollars(position.value, signed: false))
                    figure("Size", "\(position.size) \(position.market)")
                    figure("Collateral", TraderFormat.dollars(position.collateral, signed: false))
                }
                GridRow {
                    figure("Entry", TraderFormat.price(position.entry))
                    figure("Mark", TraderFormat.price(position.mark))
                    figure("Leverage", TraderFormat.leverage(position.leverage))
                }
            }
        }
        .padding(14)
        .deskGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func figure(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.45))
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
