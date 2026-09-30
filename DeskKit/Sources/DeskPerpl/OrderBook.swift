import Foundation

/// A market's L2 book, from `order-book@<market_id>`: an `mt: 15` snapshot replaces it
/// and `mt: 16` updates patch it, where a level with `o: 0` is a removal. Prices and
/// sizes stay raw, at the market's scales.
public struct OrderBook: Sendable, Equatable {
    public struct Level: Sendable, Equatable, Identifiable {
        public let priceRaw: Int64
        public let sizeRaw: Int64
        public let orders: Int
        public var id: Int64 { priceRaw }

        public init(priceRaw: Int64, sizeRaw: Int64, orders: Int) {
            self.priceRaw = priceRaw
            self.sizeRaw = sizeRaw
            self.orders = orders
        }
    }

    public enum Side: Sendable { case bid, ask }

    private var bidLevels: [Int64: Level] = [:]
    private var askLevels: [Int64: Level] = [:]
    /// Whether a snapshot has arrived; updates before one are ignored.
    public private(set) var isReady = false

    public init() {}

    /// Best first: bids highest to lowest, asks lowest to highest.
    public func levels(_ side: Side, depth: Int) -> [Level] {
        switch side {
        case .bid: Array(bidLevels.values.sorted { $0.priceRaw > $1.priceRaw }.prefix(depth))
        case .ask: Array(askLevels.values.sorted { $0.priceRaw < $1.priceRaw }.prefix(depth))
        }
    }

    public var bestBid: Int64? { bidLevels.keys.max() }
    public var bestAsk: Int64? { askLevels.keys.min() }

    /// Ask minus bid, raw; nil while either side is empty.
    public var spreadRaw: Int64? {
        guard let bid = bestBid, let ask = bestAsk else { return nil }
        return ask - bid
    }

    public mutating func reset() {
        bidLevels.removeAll()
        askLevels.removeAll()
        isReady = false
    }

    /// Applies one decoded frame. Returns false for anything that is not a book frame.
    @discardableResult
    public mutating func apply(_ frame: Frame) -> Bool {
        switch frame.kind {
        case .snapshot:
            bidLevels = Dictionary(frame.bids.filter { $0.orders > 0 && $0.sizeRaw > 0 }.map { ($0.priceRaw, $0) }, uniquingKeysWith: { $1 })
            askLevels = Dictionary(frame.asks.filter { $0.orders > 0 && $0.sizeRaw > 0 }.map { ($0.priceRaw, $0) }, uniquingKeysWith: { $1 })
            isReady = true
        case .update:
            guard isReady else { return false }
            for level in frame.bids { Self.patch(&bidLevels, level) }
            for level in frame.asks { Self.patch(&askLevels, level) }
        }
        return true
    }

    private static func patch(_ levels: inout [Int64: Level], _ level: Level) {
        if level.orders == 0 || level.sizeRaw == 0 {
            levels.removeValue(forKey: level.priceRaw)
        } else {
            levels[level.priceRaw] = level
        }
    }

    /// One `mt: 15` or `mt: 16` frame.
    public struct Frame: Sendable, Equatable {
        public enum Kind: Sendable { case snapshot, update }
        public let kind: Kind
        public let subscriptionID: Int?
        public let bids: [Level]
        public let asks: [Level]

        /// Nil for anything that is not a book frame. Numbers may arrive as strings.
        public init?(json: [String: Any]) {
            guard let mt = (json["mt"] as? NSNumber)?.intValue, mt == 15 || mt == 16 else { return nil }
            kind = mt == 15 ? .snapshot : .update
            subscriptionID = (json["sid"] as? NSNumber)?.intValue
            bids = Self.levels(json["bid"])
            asks = Self.levels(json["ask"])
        }

        public init(kind: Kind, subscriptionID: Int?, bids: [Level], asks: [Level]) {
            self.kind = kind
            self.subscriptionID = subscriptionID
            self.bids = bids
            self.asks = asks
        }

        private static func levels(_ value: Any?) -> [Level] {
            (value as? [[String: Any]] ?? []).compactMap { entry in
                guard let price = number(entry["p"]), let size = number(entry["s"]) else { return nil }
                return Level(priceRaw: price, sizeRaw: size, orders: Int(number(entry["o"]) ?? 1))
            }
        }

        private static func number(_ value: Any?) -> Int64? {
            if let number = value as? NSNumber { return number.int64Value }
            if let text = value as? String { return Int64(text) }
            return nil
        }
    }
}
