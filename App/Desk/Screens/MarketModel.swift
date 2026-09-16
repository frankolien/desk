import DeskFlow
import DeskMoney
import DeskNet
import DeskPerpl
import DeskUI
import Foundation
import Observation

/// Live market state for one market.
///
/// Everything it exposes goes through `LastGood`, so a dropped poll shows the last figure
/// with its age rather than a zero. The freshness the screen renders is computed from
/// when we received a value, never from the server's own clock.
@MainActor
@Observable
final class MarketModel {
    struct Quote: Sendable, Hashable {
        let markRaw: Int64
        let previousRaw: Int64
    }
    struct Candle: Decodable, Sendable, Hashable {
        let t: Int64
        let o: UInt64
        let c: UInt64
        let h: UInt64
        let l: UInt64
        let v: String
    }

    private struct CandleSeries: Decodable { let d: [Candle] }
    private(set) var symbol = "BTC"
    private(set) var mark = LastGood<Price>()
    private(set) var market: Market?
    private(set) var isLoadingFirstValue = true
    /// Marks this device has actually seen, oldest first. The venue publishes no candle
    /// endpoint, so this is the only honest series available.
    private(set) var history: [Double] = []
    private(set) var candles: [Candle] = []
    private(set) var candleIntervalSeconds = 3_600
    /// The block the venue last reported, carried on the same context call the price
    /// comes from. Every order's deadline is computed against it, so a stale one produces
    /// an order that expires on arrival.
    private(set) var headBlock: Int64 = 0
    /// Every market the venue lists, from the same context call. Kept so Watchlist and
    /// Search can show real instruments at real prices rather than a table of invented
    /// ones — the venue publishes seven, and none of them needed making up.
    private(set) var allMarkets: [Market] = []
    private(set) var quotes: [UInt32: Quote] = [:]

    /// The one market Desk trades. A deliberate scope decision rather than a limitation
    /// of the code — `OrderBuilder` takes the market as a parameter — and the discovery
    /// screens say so rather than hiding the other six.
    static let tradableMarketID: UInt32 = 16

    private static let historyLimit = 90

    private let rest: PerplREST
    private var marketID: UInt32
    private var poller: Task<Void, Never>?
    private var liveReader: Task<Void, Never>?
    private var liveSocket: URLSessionWebSocket?
    private var lastCandleFetch: Date?

    init(marketID: UInt32 = 16) {
        self.marketID = marketID
        rest = PerplREST(configuration: try! .testnet())
    }

    /// Green while the series is up over its own window, red while it is down. Direction,
    /// not decoration.
    var trend: DeskRGB {
        guard let first = history.first, let last = history.last, last != first else {
            return DeskColor.nightMuted
        }
        return last >= first ? DeskColor.rise : DeskColor.fall
    }

    var changeText: String? {
        guard let first = history.first, let last = history.last, first > 0, history.count >= 2
        else { return nil }
        let percent = (last - first) / first * 100
        let sign = percent < 0 ? Direction.minus : "+"
        return "\(sign)\(String(format: "%.2f", abs(percent)))% while open"
    }

    var freshness: Freshness {
        mark.freshness(socketIsConnected: mark.consecutiveFailures == 0)
    }

    var markText: String {
        guard let price = mark.value, let market else { return "—" }
        return price.display(fractionDigits: market.config.priceDecimals)
    }

    /// The percentage alone. A row has no width for "while open", and a truncated
    /// sentence beside a price reads as a broken figure rather than an elided one.
    var changePercentText: String? {
        guard let first = history.first, let last = history.last, first > 0, history.count >= 2
        else { return nil }
        let percent = (last - first) / first * 100
        let sign = percent < 0 ? Direction.minus : "+"
        return "\(sign)\(String(format: "%.2f", abs(percent)))%"
    }

    var ageText: String? {
        guard let age = mark.age(), freshness != .live else { return nil }
        let seconds = Int(age.components.seconds)
        return seconds < 60 ? "Updated \(seconds)s ago" : "Updated \(seconds / 60)m ago"
    }

    var problemText: String? {
        // Silent for the first couple of failures. A spinner over a number that is still
        // correct is worse than no spinner.
        guard mark.shouldReportProblem() else { return nil }
        return "Reconnecting…"
    }

    func start() {
        guard poller == nil else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                guard let self else { return }
                if liveReader == nil { startLiveStream() }
                let retry = mark.retryDelay()
                try? await Task.sleep(for: retry == .zero ? .seconds(30) : retry)
            }
        }
    }

    func stop() {
        poller?.cancel()
        poller = nil
        liveReader?.cancel()
        liveReader = nil
        liveSocket?.close()
        liveSocket = nil
    }

    func select(_ selected: Market) {
        guard marketID != selected.id else { return }
        marketID = selected.id
        market = selected
        symbol = selected.symbol
        candles = []
        // The series belongs to the market that produced it. Carried across a switch,
        // its first and last entries were two different instruments, and every figure
        // derived from them compared one market's price to another's: selecting SOL
        // after BTC rendered SOL, live at $97, as down 99.87%, and coloured the trend
        // from the same comparison. Cleared here so `record` reseeds from the new
        // market's own previous mark.
        history = []
        lastCandleFetch = nil
        applyQuote(for: selected)
        Task { await refreshCandles() }
    }

    func selectCandleInterval(_ seconds: Int) {
        guard seconds != candleIntervalSeconds else { return }
        candleIntervalSeconds = seconds
        candles = []
        lastCandleFetch = nil
        Task { await refreshCandles() }
    }

    func markText(for item: Market) -> String {
        price(for: item)?.display(fractionDigits: item.config.priceDecimals) ?? "—"
    }

    /// The latest mark for this exact market. Position maths must never use the mark of
    /// whichever market happens to be selected in the UI.
    func price(for item: Market) -> Price? {
        let raw = quotes[item.id]?.markRaw ?? item.state.markRaw
        return item.price(raw)
    }

    func market(id: UInt32) -> Market? {
        market?.id == id ? market : allMarkets.first(where: { $0.id == id })
    }

    func changePercent(for item: Market) -> Double? {
        let quote = quotes[item.id] ?? Quote(
            markRaw: item.state.markRaw, previousRaw: item.state.previousRaw)
        guard quote.previousRaw > 0 else { return nil }
        return (Double(quote.markRaw - quote.previousRaw) / Double(quote.previousRaw)) * 100
    }

    /// Seeds from the one previous mark the context carries, so the line exists on the
    /// first poll rather than after the second.
    private func record(market: Market, price: Price) {
        let scale = pow(10.0, Double(market.config.priceDecimals))
        if history.isEmpty, market.state.previousRaw > 0 {
            history.append(Double(market.state.previousRaw) / scale)
        }
        let value = Double(price.raw) / scale
        guard history.last != value else { return }
        history.append(value)
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
    }

    private func refresh() async {
        do {
            let context = try await rest.context()
            guard let market = context.market(id: marketID),
                  let price = market.price(market.state.markRaw)
            else {
                mark.recordFailure("market \(marketID) is not in the context")
                return
            }
            self.market = market
            symbol = market.symbol
            if let head = context.chain.gas?.headBlock { headBlock = max(headBlock, head) }
            allMarkets = context.markets.filter(\.config.isOpen)
            for item in allMarkets where quotes[item.id] == nil {
                quotes[item.id] = Quote(markRaw: item.state.markRaw, previousRaw: item.state.previousRaw)
            }
            mark.record(price, serverTimestampMilliseconds: market.state.observedAt.timestampMilliseconds)
            record(market: market, price: price)
            if lastCandleFetch.map({ Date().timeIntervalSince($0) > 45 }) ?? true {
                await refreshCandles()
            }
            isLoadingFirstValue = false
        } catch {
            mark.recordFailure(String(describing: error))
            isLoadingFirstValue = false
        }
    }

    /// Perpl's public market-data socket is the authority between context refreshes.
    /// It is event driven: figures change as soon as the venue emits a state frame rather
    /// than waiting for a timer. The heartbeat subscription also makes a quiet market
    /// observable, so a dead connection can be replaced without freezing old prices.
    private func startLiveStream() {
        liveReader = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    guard let self else { return }
                    let socket = try URLSessionWebSocket(
                        url: URL(string: "wss://testnet.perpl.xyz/ws/v1/market-data")!)
                    liveSocket = socket
                    let ids = allMarkets.isEmpty ? [16, 32, 48, 64, 256] : allMarkets.map(\.id)
                    let subscriptions = (["heartbeat@10143"] + ids.map { "market-state@\($0)" })
                        .map { ["stream": $0, "subscribe": true] as [String: Any] }
                    let payload: [String: Any] = ["mt": 5, "subs": subscriptions]
                    let data = try JSONSerialization.data(withJSONObject: payload)
                    try await socket.send(String(decoding: data, as: UTF8.self))

                    while !Task.isCancelled {
                        let text = try await socket.receive()
                        let data = Data(text.utf8)
                        let updates = await Task.detached(priority: .utility) {
                            Self.decodeLiveQuotes(data)
                        }.value
                        ingestLiveQuotes(updates)
                    }
                } catch {
                    self?.liveSocket?.close()
                    self?.liveSocket = nil
                    guard !Task.isCancelled else { return }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    nonisolated private static func decodeLiveQuotes(_ data: Data) -> [UInt32: Int64] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["mt"] as? NSNumber)?.intValue == 9,
              let states = root["d"] as? [String: Any]
        else { return [:] }

        var result: [UInt32: Int64] = [:]
        for (key, value) in states {
            guard let id = UInt32(key), let state = value as? [String: Any],
                  let raw = wireInt(state["mrk"])
            else { continue }
            result[id] = raw
        }
        return result
    }

    private func ingestLiveQuotes(_ updates: [UInt32: Int64]) {
        for (id, raw) in updates {
            let previous = quotes[id]?.previousRaw
                ?? allMarkets.first(where: { $0.id == id })?.state.previousRaw
                ?? raw
            quotes[id] = Quote(markRaw: raw, previousRaw: previous)
            if id == marketID, let selected = allMarkets.first(where: { $0.id == id }) {
                applyQuote(for: selected)
            }
        }
    }

    private func applyQuote(for selected: Market) {
        let raw = quotes[selected.id]?.markRaw ?? selected.state.markRaw
        guard let price = selected.price(raw) else { return }
        mark.record(price)
        record(market: selected, price: price)
        isLoadingFirstValue = false
    }

    nonisolated private static func wireInt(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return Int64(text) }
        return nil
    }

    private func refreshCandles() async {
        let requestedMarket = marketID
        let requestedInterval = candleIntervalSeconds
        let to = Int64(Date().timeIntervalSince1970 * 1_000)
        // Keep roughly the same visual density at every range. Fetching a whole day of
        // one-minute candles and then dropping almost all of them produces misleading
        // shapes and unnecessary traffic.
        let from = to - Int64(requestedInterval * 80 * 1_000)
        do {
            let endpoint = try PerplEndpoint(
                method: .get,
                path: "/v1/market-data/\(requestedMarket)/candles/\(requestedInterval)/\(from)-\(to)")
            let data = try await rest.publicData(endpoint)
            let result = try await Task.detached(priority: .utility) {
                try JSONDecoder().decode(CandleSeries.self, from: data).d
            }.value
            guard requestedMarket == marketID, requestedInterval == candleIntervalSeconds else { return }
            candles = result
            lastCandleFetch = Date()
        } catch {
            // Keep the last complete series. The live mark continues independently.
        }
    }
}
