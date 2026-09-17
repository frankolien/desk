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

    private static let storageKey = "desk.followedTraders"
    private static let endpoint = "https://web-lovat-nine-49.vercel.app/api/traders"

    init() {
        followed = UserDefaults.standard.stringArray(forKey: Self.storageKey) ?? []
    }

    func isFollowing(_ address: String) -> Bool {
        followed.contains { $0.caseInsensitiveCompare(address) == .orderedSame }
    }

    func toggle(_ address: String) {
        if isFollowing(address) {
            followed.removeAll { $0.caseInsensitiveCompare(address) == .orderedSame }
            following.removeAll { $0.id == address.lowercased() }
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

enum TraderFormat {
    static func dollars(_ text: String?, signed: Bool = true) -> String {
        guard let text, let value = Double(text) else { return Unavailable.text }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = abs(value) >= 1_000 ? 0 : 2
        formatter.minimumFractionDigits = abs(value) >= 1_000 ? 0 : 2
        let magnitude = formatter.string(from: NSNumber(value: abs(value))) ?? text
        let sign = value < 0 ? Direction.minus : (signed ? "+" : "")
        return "\(sign)$\(magnitude)"
    }

    static func price(_ text: String) -> String {
        guard let value = Double(text) else { return text }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = value >= 100 ? 2 : (value >= 1 ? 4 : 6)
        return formatter.string(from: NSNumber(value: value)) ?? text
    }

    static func leverage(_ value: Double?) -> String {
        guard let value else { return "" }
        return value.rounded() == value ? "\(Int(value))×" : String(format: "%.1f×", value)
    }
}

/// A mark made from the address itself, so a trader is recognisable without a name
/// anyone invented.
struct TraderAvatar: View {
    let address: String
    var size: CGFloat = 38

    private var hues: (Double, Double) {
        let bytes = Array(address.lowercased().utf8)
        let first = bytes.dropFirst(2).prefix(6).reduce(0) { ($0 * 31 + Int($1)) % 360 }
        let second = bytes.suffix(6).reduce(0) { ($0 * 17 + Int($1)) % 360 }
        return (Double(first) / 360, Double(second) / 360)
    }

    var body: some View {
        Circle()
            .fill(AngularGradient(
                colors: [Color(hue: hues.0, saturation: 0.55, brightness: 0.85),
                         Color(hue: hues.1, saturation: 0.6, brightness: 0.6),
                         Color(hue: hues.0, saturation: 0.55, brightness: 0.85)],
                center: .center))
            .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct TradersFeed: View {
    let directory: TraderDirectory
    let onSelect: (TraderSnapshot) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("Following")
            if directory.followed.isEmpty {
                Text("Follow a trader to keep their live positions here.")
                    .font(DeskType.caption)
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .padding(.top, 8)
            } else {
                VStack(spacing: 8) {
                    ForEach(directory.followed, id: \.self) { address in
                        if let snapshot = directory.following.first(where: { $0.id == address.lowercased() }) {
                            TraderRow(trader: snapshot, rank: nil, directory: directory) { onSelect(snapshot) }
                        } else {
                            TraderRow(trader: TraderSnapshot(accountId: nil, address: address, pnl: nil, balance: nil, positions: []),
                                      rank: nil, directory: directory, isLoading: true) {}
                        }
                    }
                }
                .padding(.top, 10)
            }

            sectionTitle("Top traders · open PnL").padding(.top, 26)
            if directory.top.isEmpty {
                if let problem = directory.topProblem {
                    Label(problem, systemImage: "exclamationmark.circle.fill")
                        .font(DeskType.caption)
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .padding(.top, 10)
                } else {
                    VStack(spacing: 8) {
                        ForEach(0..<6, id: \.self) { index in
                            TraderRow(trader: TraderSnapshot(accountId: nil, address: "0x000000000000000000000000000000000000000\(index)",
                                                             pnl: "0", balance: nil, positions: []),
                                      rank: index + 1, directory: directory, isLoading: true) {}
                        }
                    }
                    .padding(.top, 10)
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(directory.top.enumerated()), id: \.element.id) { index, trader in
                        TraderRow(trader: trader, rank: index + 1, directory: directory) { onSelect(trader) }
                    }
                }
                .padding(.top, 10)
            }

            Text("Read live from Perpl mainnet. PnL is on open positions and includes funding. Copying opens your own testnet ticket.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(DeskColor.nightMuted.color.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 22)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .heavy, design: .rounded))
            .tracking(1)
            .foregroundStyle(DeskColor.nightMuted.color)
    }
}

private struct TraderRow: View {
    let trader: TraderSnapshot
    let rank: Int?
    let directory: TraderDirectory
    var isLoading = false
    let onTap: () -> Void

    private var markets: String {
        let names = trader.positions.map(\.market)
        guard !names.isEmpty else { return isLoading ? "Loading positions" : "No open positions" }
        let shown = names.prefix(3).joined(separator: " · ")
        return names.count > 3 ? "\(shown) +\(names.count - 3)" : shown
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onTap) {
                HStack(spacing: 12) {
                    if let rank {
                        Text("\(rank)")
                            .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(DeskColor.nightMuted.color)
                            .frame(width: 18)
                    }
                    TraderAvatar(address: trader.address, size: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(trader.shortAddress)
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .foregroundStyle(DeskColor.nightText.color)
                        Text(markets)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(DeskColor.nightMuted.color)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(TraderFormat.dollars(trader.pnl))
                        .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle((trader.isProfit ? DeskColor.rise : DeskColor.fall).color)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isLoading)

            if rank != nil {
                FollowButton(address: trader.address, directory: directory, compact: true)
                    .disabled(isLoading)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 64)
        .background(DeskColor.nightChip.color.opacity(0.6), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(DeskColor.nightLine.color, lineWidth: 0.5))
        .redacted(reason: isLoading ? .placeholder : [])
    }
}

private struct FollowButton: View {
    let address: String
    let directory: TraderDirectory
    var compact = false

    private var following: Bool { directory.isFollowing(address) }

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.snappy(duration: 0.2)) { directory.toggle(address) }
        } label: {
            Group {
                if compact {
                    Image(systemName: following ? "checkmark" : "plus")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 34, height: 34)
                } else {
                    Text(following ? "Following" : "Follow")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .padding(.horizontal, 18)
                        .frame(height: 38)
                }
            }
            .foregroundStyle(following ? DeskColor.nightText.color : DeskColor.night.color)
            .background(following ? Color.white.opacity(0.12) : DeskColor.nightText.color, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(following ? "Unfollow \(TraderSnapshot.short(address))" : "Follow \(TraderSnapshot.short(address))")
    }
}

struct TraderProfileScreen: View {
    let initial: TraderSnapshot
    let directory: TraderDirectory
    let onCopy: (TraderPosition) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: TraderSnapshot?
    @State private var copied = false

    private var trader: TraderSnapshot { snapshot ?? initial }

    var body: some View {
        ZStack {
            DeskBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(DeskColor.nightText.color)
                                .frame(width: 40, height: 40)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        FollowButton(address: trader.address, directory: directory)
                    }
                    .padding(.top, 6)

                    HStack(spacing: 14) {
                        TraderAvatar(address: trader.address, size: 56)
                        VStack(alignment: .leading, spacing: 4) {
                            Button {
                                UIPasteboard.general.string = trader.address
                                copied = true
                            } label: {
                                HStack(spacing: 6) {
                                    Text(trader.shortAddress)
                                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(DeskColor.nightMuted.color)
                                }
                                .foregroundStyle(DeskColor.nightText.color)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Text("Perpl mainnet trader")
                                .font(DeskType.caption)
                                .foregroundStyle(DeskColor.nightMuted.color)
                        }
                    }
                    .padding(.top, 14)

                    HStack(spacing: 10) {
                        stat("Open PnL", TraderFormat.dollars(trader.pnl),
                             tint: trader.isProfit ? DeskColor.rise : DeskColor.fall)
                        stat("Positions", "\(trader.positions.count)")
                        stat("Free balance", TraderFormat.dollars(trader.balance, signed: false))
                    }
                    .padding(.top, 22)

                    Text("OPEN POSITIONS")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .tracking(1)
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .padding(.top, 26)

                    if trader.positions.isEmpty {
                        Text(snapshot == nil ? "Loading positions…" : "Nothing open right now.")
                            .font(DeskType.caption)
                            .foregroundStyle(DeskColor.nightMuted.color)
                            .padding(.top, 10)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(trader.positions) { position in
                                TraderPositionCard(position: position) { onCopy(position) }
                            }
                        }
                        .padding(.top, 10)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 120)
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
    }

    private func stat(_ title: String, _ value: String, tint: DeskRGB = DeskColor.nightText) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(DeskColor.nightMuted.color)
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(tint.color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DeskColor.nightChip.color.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct TraderPositionCard: View {
    let position: TraderPosition
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                MarketTokenLogo(symbol: position.market, size: 30)
                Text("\(position.isLong ? "Long" : "Short") \(position.market)")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
                if position.leverage != nil {
                    Text(TraderFormat.leverage(position.leverage))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle((position.isLong ? DeskColor.rise : DeskColor.fall).color)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background((position.isLong ? DeskColor.rise : DeskColor.fall).color.opacity(0.14), in: Capsule())
                }
                Spacer()
                Button(action: onCopy) {
                    Label("Copy", systemImage: "square.on.square")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(DeskColor.night.color)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(DeskColor.nightText.color, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            HStack(alignment: .top) {
                figure("PnL", TraderFormat.dollars(position.pnl),
                       detail: position.pnlPercent.map { String(format: "%@%.1f%%", $0 < 0 ? "" : "+", $0) },
                       tint: position.isProfit ? DeskColor.rise : DeskColor.fall)
                Spacer()
                figure("Value", TraderFormat.dollars(position.value, signed: false))
                Spacer()
                figure("Entry", TraderFormat.price(position.entry), detail: "Mark \(TraderFormat.price(position.mark))")
            }
        }
        .padding(14)
        .background(DeskColor.nightChip.color.opacity(0.6), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(DeskColor.nightLine.color, lineWidth: 0.5))
    }

    private func figure(_ title: String, _ value: String, detail: String? = nil, tint: DeskRGB = DeskColor.nightText) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(DeskColor.nightMuted.color)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(tint.color)
            if let detail {
                Text(detail)
                    .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
        }
    }
}
