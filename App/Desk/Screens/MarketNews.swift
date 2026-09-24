import DeskUI
import Observation
import SwiftUI

struct NewsItem: Decodable, Identifiable, Hashable, Sendable {
    let title: String
    let url: String
    let source: String
    let publishedAt: Int64
    let image: String?
    let symbols: [String]

    var id: String { url }
    var date: Date { Date(timeIntervalSince1970: Double(publishedAt) / 1000) }
    var link: URL? { URL(string: url) }
    var imageURL: URL? { image.flatMap(URL.init(string:)) }
}

/// Headlines from Desk's server, refreshed every five minutes while a screen shows them.
@MainActor
@Observable
final class NewsModel {
    private struct Response: Decodable { let items: [NewsItem] }

    private(set) var items: [NewsItem] = []
    private(set) var loaded = false

    private static let endpoint = "https://web-lovat-nine-49.vercel.app/api/market-snapshot"

    func run(symbols: [String] = []) async {
        while !Task.isCancelled {
            await load(symbols: symbols)
            try? await Task.sleep(for: .seconds(300))
        }
    }

    func load(symbols: [String] = []) async {
        var components = URLComponents(string: Self.endpoint)!
        components.queryItems = [URLQueryItem(name: "view", value: "news")]
        if !symbols.isEmpty { components.queryItems?.append(URLQueryItem(name: "symbols", value: symbols.joined(separator: ","))) }
        guard let url = components.url else { return }
        if items.isEmpty, let cached = await ResponseCache.shared.cached(url),
           let body = try? JSONDecoder().decode(Response.self, from: cached) {
            items = body.items
        }
        if let (data, _) = try? await ResponseCache.shared.data(from: url),
           let body = try? JSONDecoder().decode(Response.self, from: data) {
            items = body.items
        }
        loaded = true
    }
}

/// A headline, who wrote it and when, the markets it touches, and its picture.
struct NewsRow: View {
    let item: NewsItem
    let market: MarketModel
    let isLast: Bool

    private var chips: [(symbol: String, change: Double?)] {
        item.symbols.prefix(2).map { symbol in
            (symbol, market.allMarkets.first { $0.symbol == symbol }.flatMap(market.changePercent(for:)))
        }
    }

    /// "12m ago", "3h ago", "2d ago": one unit, the way a feed reads.
    static func age(of date: Date, now: Date = .now) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "just now"
        case ..<3_600: return "\(seconds / 60)m ago"
        case ..<86_400: return "\(seconds / 3_600)h ago"
        default: return "\(seconds / 86_400)d ago"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(item.source) · \(Self.age(of: item.date))")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .lineLimit(1)
                    if !chips.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(chips, id: \.symbol) { chip in
                                HStack(spacing: 5) {
                                    Text(chip.symbol)
                                        .foregroundStyle(DeskColor.nightText.color)
                                    if let change = chip.change {
                                        Text(String(format: "%+.2f%%", change))
                                            .foregroundStyle(change >= 0 ? DeskColor.rise.color : DeskColor.fall.color)
                                    }
                                }
                                .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                                .padding(.horizontal, 8)
                                .frame(height: 22)
                                .background(Color.white.opacity(0.08), in: Capsule())
                            }
                        }
                        .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
                if let image = item.imageURL {
                    RemoteImage(url: image, fill: true) {
                        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.06))
                    }
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .padding(.vertical, 12)
            if !isLast { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5) }
        }
        .contentShape(Rectangle())
    }
}
