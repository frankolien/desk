import DeskUI
import Observation
import SwiftUI

/// A day of hourly closes for the tokens on the ticker, from Desk's server.
@MainActor
@Observable
final class TickerSparklines {
    private struct Response: Decodable {
        struct Row: Decodable { let chainIndex: String; let contract: String; let closes: [Double] }
        let series: [Row]
    }

    private(set) var closes: [String: [Double]] = [:]
    private var loadedFor = ""

    private static let endpoint = "https://web-lovat-nine-49.vercel.app/api/token-details"

    static func key(_ token: TrendingSpotToken) -> String { "\(token.chainIndex):\(token.contract)" }

    func load(_ tokens: [TrendingSpotToken]) async {
        let ids = tokens.prefix(10).map(Self.key)
        guard !ids.isEmpty else { return }
        var components = URLComponents(string: Self.endpoint)!
        components.queryItems = [
            URLQueryItem(name: "view", value: "sparklines"),
            URLQueryItem(name: "tokens", value: ids.joined(separator: ",")),
        ]
        guard let url = components.url,
              let (data, _) = try? await ResponseCache.shared.data(from: url),
              let body = try? JSONDecoder().decode(Response.self, from: data) else { return }
        for row in body.series where !row.closes.isEmpty {
            closes["\(row.chainIndex):\(row.contract)"] = row.closes
        }
        loadedFor = ids.joined(separator: ",")
    }
}

/// Trending coins drifting past, each with its day drawn small beside it.
///
/// The strip is two copies of the row end to end, moved left by the clock; when the
/// first copy has fully passed, the offset wraps and the second is standing where the
/// first began. With Reduce Motion on it is an ordinary strip a thumb moves.
struct TrendingTicker: View {
    let tokens: [TrendingSpotToken]
    let sparklines: TickerSparklines
    let onOpen: (TrendingSpotToken) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rowWidth: CGFloat = 0

    private static let pointsPerSecond: CGFloat = 28

    var body: some View {
        Group {
            if reduceMotion {
                ScrollView(.horizontal, showsIndicators: false) {
                    row.padding(.horizontal, 16)
                }
            } else {
                // The reader takes the width it is given and hands the strip only that,
                // so the strip's own length never becomes the page's.
                GeometryReader { proxy in
                    TimelineView(.animation) { context in
                        let travelled = CGFloat(context.date.timeIntervalSinceReferenceDate) * Self.pointsPerSecond
                        let offset = rowWidth > 0 ? -travelled.truncatingRemainder(dividingBy: rowWidth) : 0
                        HStack(spacing: 0) {
                            row
                                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { rowWidth = $0 }
                            row
                        }
                        .offset(x: offset)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
                    .clipped()
                }
            }
        }
        .frame(height: 64)
    }

    private var row: some View {
        HStack(spacing: 28) {
            ForEach(tokens) { token in
                Button { onOpen(token) } label: { TickerItem(token: token, closes: sparklines.closes[TickerSparklines.key(token)]) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.trailing, 28)
        .fixedSize()
    }
}

private struct TickerItem: View {
    let token: TrendingSpotToken
    let closes: [Double]?

    private var up: Bool { (token.change ?? 0) >= 0 }

    var body: some View {
        HStack(spacing: 10) {
            MarketTokenLogo(symbol: token.symbol, size: 34, remoteURL: token.artworkURL)
            VStack(alignment: .leading, spacing: 2) {
                Text(token.symbol)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
                    .lineLimit(1)
                Text(token.price.map(spotPrice) ?? "$—")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(DeskColor.nightText.color.opacity(0.9))
                    .lineLimit(1)
                if let change = token.change {
                    Text(String(format: "%+.2f%%", change))
                        .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(up ? DeskColor.rise.color : DeskColor.fall.color)
                }
            }
            if let closes, closes.count >= 2 {
                Sparkline(values: closes, tint: up ? DeskColor.rise : DeskColor.fall)
                    .frame(width: 64, height: 30)
            }
        }
        .contentShape(Rectangle())
    }
}
