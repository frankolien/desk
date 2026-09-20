import DeskUI
import Foundation

/// Every figure arrives formatted: the widget cannot reach `DisplayCurrency`, and two screens of one phone must not disagree.
struct PortfolioGlance: Codable, Hashable, Sendable {
    struct Position: Codable, Hashable, Sendable, Identifiable {
        let id: String
        let symbol: String
        let isLong: Bool
        let leverage: Int
        /// Unrealised, in AUSD. The sign picks the colour; the text is what is read.
        let pnl: Double
        let pnlText: String
        let returnOnMarginMicros: Int
    }

    var addressShort: String
    var network: String
    var collateralText: String
    var positions: [Position]
    var updatedAt: Date

    static let widgetKind = "com.opia.desk.portfolio"
    private static let key = "desk.portfolio.glance"

    static func load() -> PortfolioGlance? {
        DeskGroup.defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(PortfolioGlance.self, from: $0) }
    }

    func save() {
        DeskGroup.defaults.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }

    /// Signing out. The next account's Home Screen must not open on this one's book.
    static func forget() {
        DeskGroup.defaults.removeObject(forKey: key)
    }

    static let preview = PortfolioGlance(
        addressShort: "0xb63b…4c97", network: "Monad testnet", collateralText: "$1,282.18",
        positions: [
            Position(id: "42:4", symbol: "BTC", isLong: true, leverage: 15, pnl: 4085.46,
                     pnlText: "+4,085.46", returnOnMarginMicros: 817_000),
            Position(id: "42:5", symbol: "ETH", isLong: true, leverage: 10, pnl: 170.15,
                     pnlText: "+170.15", returnOnMarginMicros: 847_900),
            Position(id: "42:6", symbol: "SOL", isLong: false, leverage: 5, pnl: -23.8,
                     pnlText: "−23.80", returnOnMarginMicros: -61_200),
        ],
        updatedAt: .now)
}

/// The saved markets with the marks Desk last saw for them.
struct WatchlistGlance: Codable, Hashable, Sendable {
    struct Row: Codable, Hashable, Sendable, Identifiable {
        let id: UInt32
        let symbol: String
        let priceText: String
        let changePercent: Double?
    }

    var rows: [Row]
    var updatedAt: Date

    static let widgetKind = "com.opia.desk.watchlist"
    private static let key = "desk.watchlist.glance"

    static func load() -> WatchlistGlance? {
        DeskGroup.defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(WatchlistGlance.self, from: $0) }
    }

    func save() {
        DeskGroup.defaults.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }

    static let preview = WatchlistGlance(
        rows: [
            Row(id: 1, symbol: "BTC", priceText: "$81,085.5", changePercent: -0.18),
            Row(id: 20, symbol: "ETH", priceText: "$2,623.45", changePercent: -0.29),
            Row(id: 31, symbol: "SOL", priceText: "$110.76", changePercent: -2.22),
            Row(id: 10, symbol: "MON", priceText: "$0.0312", changePercent: 5.83),
            Row(id: 40, symbol: "HYPE", priceText: "$27.14", changePercent: 1.07),
        ],
        updatedAt: .now)
}

/// One way of writing a percentage, shared by the screen and the widget so the two
/// never round the same figure differently.
enum Percent {
    /// Micros to a percentage, truncated. A gain is never rounded up into one it is not.
    static func micros(_ micros: Int, signed: Bool = true) -> String {
        let sign = micros < 0 ? Direction.minus : (signed ? "+" : "")
        let magnitude = abs(micros)
        return "\(sign)\(magnitude / 10_000).\(String(format: "%02d", (magnitude % 10_000) / 100))%"
    }

    static func change(_ percent: Double) -> String {
        let sign = percent < 0 ? Direction.minus : "+"
        return "\(sign)\(String(format: "%.2f", abs(percent)))%"
    }
}
