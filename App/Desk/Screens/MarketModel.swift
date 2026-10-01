import DeskFlow
import DeskMoney
import DeskNet
import DeskPerpl
import DeskUI
import Foundation
import Observation

@MainActor
@Observable
final class MarketModel {
    struct Quote: Sendable, Hashable {
        let markRaw: Int64
        let previousRaw: Int64
        var receivedAt = ContinuousClock.now
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
    private(set) var history: [Double] = []
    private(set) var candles: [Candle] = []
    private(set) var candleIntervalSeconds = 3_600
    private(set) var candleDepth = MarketModel.defaultCandleDepth
    private(set) var isLoadingOlderCandles = false
    private(set) var reachedOldestCandle = false
    static let defaultCandleDepth = 80
    private static let candleCap = 3_000
    /// The venue's last block. Order deadlines are computed against it, so a stale one sends
    /// orders that expire on arrival. Deliberately unobserved: it changes every block.
    @ObservationIgnored private(set) var headBlock: Int64 = 0
    @ObservationIgnored var onHeadBlock: ((Int64) -> Void)?
    private(set) var allMarkets: [Market] = []
    private(set) var quotes: [UInt32: Quote] = [:]
    private(set) var book = OrderBook()
    private var wantsBook = false
    private var bookMarket: UInt32?
    private var bookSID: Int?
    private var liveExtras: Set<String> = []
    private var candleSID: Int?

    /// The one market Desk trades, by scope decision; `OrderBuilder` itself takes any market.
    static let tradableMarketID: UInt32 = 16

    private static let historyLimit = 90

    private let rest: PerplREST
    private var marketID: UInt32
    private var restampedAt: [UInt32: ContinuousClock.Instant] = [:]
    private var statesFlowing = false
    private var poller: Task<Void, Never>?
    private var liveReader: Task<Void, Never>?
    private var liveSocket: URLSessionWebSocket?
    private var lastCandleFetch: Date?

    let network: DeskNetwork

    init(network: DeskNetwork) {
        self.network = network
        marketID = network.defaultMarketID
        rest = PerplREST(configuration: try! network.perpl())
    }

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
        mark.freshness(socketIsConnected: mark.consecutiveFailures == 0 || statesFlowing)
    }

    var markText: String {
        guard let price = mark.value, let market else { return "—" }
        return price.display(fractionDigits: market.config.priceDecimals)
    }

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
        guard !statesFlowing, mark.shouldReportProblem() else { return nil }
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

    func refreshNow() async {
        await refresh()
        await refreshCandles()
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
        reachedOldestCandle = false
        history = []
        lastCandleFetch = nil
        applyQuote(for: selected, at: statesFlowing ? .now : quotes[selected.id]?.receivedAt ?? .now)
        book.reset()
        Task { await refreshCandles() }
        Task { await syncLiveSubscriptions() }
    }

    /// Leaving does not unsubscribe: Perpl allows ten subscription requests a minute per
    /// connection, so the next market swaps streams in a single request.
    func watchBook(_ on: Bool) {
        wantsBook = on
        if on { Task { await syncLiveSubscriptions() } }
    }

    private func wantedExtras() -> Set<String> {
        let bookStream = "order-book@\(marketID)"
        var wanted: Set<String> = ["candles@\(marketID)*\(candleIntervalSeconds)"]
        if wantsBook || liveExtras.contains(bookStream) { wanted.insert(bookStream) }
        return wanted
    }

    private func syncLiveSubscriptions() async {
        guard let socket = liveSocket else { return }
        let wanted = wantedExtras()
        let leaving = liveExtras.subtracting(wanted)
        let joining = wanted.subtracting(liveExtras)
        guard !leaving.isEmpty || !joining.isEmpty else { return }
        if joining.contains(where: { $0.hasPrefix("order-book@") }) || leaving.contains(where: { $0.hasPrefix("order-book@") }) {
            bookSID = nil
            book.reset()
        }
        if joining.contains(where: { $0.hasPrefix("candles@") }) { candleSID = nil }
        bookMarket = wanted.contains("order-book@\(marketID)") ? marketID : nil
        liveExtras = wanted
        let subscriptions = leaving.sorted().map { ["stream": $0, "subscribe": false] as [String: Any] }
            + joining.sorted().map { ["stream": $0, "subscribe": true] as [String: Any] }
        guard let data = try? JSONSerialization.data(withJSONObject: ["mt": 5, "subs": subscriptions] as [String: Any]) else { return }
        try? await socket.send(String(decoding: data, as: UTF8.self))
    }

    func selectCandleInterval(_ seconds: Int) {
        guard seconds != candleIntervalSeconds else { return }
        candleIntervalSeconds = seconds
        candles = []
        reachedOldestCandle = false
        lastCandleFetch = nil
        Task { await refreshCandles() }
        Task { await syncLiveSubscriptions() }
    }

    func setCandleDepth(_ depth: Int) {
        let clamped = min(max(depth, Self.defaultCandleDepth), Self.candleCap)
        guard clamped != candleDepth else { return }
        let grew = clamped > candleDepth
        candleDepth = clamped
        if grew { lastCandleFetch = nil; Task { await refreshCandles() } }
    }

    func loadOlderCandles() async {
        guard !isLoadingOlderCandles, !reachedOldestCandle, let first = candles.first,
              candles.count < Self.candleCap else { return }
        isLoadingOlderCandles = true
        defer { isLoadingOlderCandles = false }
        let requestedMarket = marketID
        let requestedInterval = candleIntervalSeconds
        let to = first.t - 1
        let from = to - Int64(requestedInterval * candleDepth * 1_000)
        do {
            let endpoint = try PerplEndpoint(
                method: .get,
                path: "/v1/market-data/\(requestedMarket)/candles/\(requestedInterval)/\(from)-\(to)")
            let data = try await rest.publicData(endpoint)
            let result = try await Task.detached(priority: .utility) {
                try JSONDecoder().decode(CandleSeries.self, from: data).d
            }.value
            guard requestedMarket == marketID, requestedInterval == candleIntervalSeconds,
                  candles.first?.t == first.t else { return }
            let older = result.filter { $0.t < first.t }
            if older.isEmpty { reachedOldestCandle = true } else { candles = older + candles }
        } catch {
        }
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
            if let head = context.chain.gas?.headBlock { noteHead(head) }
            allMarkets = context.markets.filter(\.config.isOpen)
            UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: allMarkets.map { (String($0.id), $0.symbol) }), forKey: "desk.marketSymbols")
            for item in allMarkets {
                if statesFlowing, let streamed = quotes[item.id] {
                    quotes[item.id] = Quote(markRaw: streamed.markRaw, previousRaw: item.state.previousRaw, receivedAt: streamed.receivedAt)
                } else {
                    quotes[item.id] = Quote(markRaw: item.state.markRaw, previousRaw: item.state.previousRaw)
                }
            }
            if statesFlowing, mark.hasValue {
                mark.noteSuccess()
            } else {
                mark.record(price, serverTimestampMilliseconds: market.state.observedAt.timestampMilliseconds)
                record(market: market, price: price)
            }
            if lastCandleFetch.map({ Date().timeIntervalSince($0) > 45 }) ?? true {
                await refreshCandles()
            }
            isLoadingFirstValue = false
        } catch {
            mark.recordFailure(String(describing: error))
            isLoadingFirstValue = false
        }
    }

    private func startLiveStream() {
        liveReader = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    guard let self else { return }
                    let socket = try URLSessionWebSocket(url: network.marketDataURL)
                    liveSocket = socket
                    statesFlowing = false
                    book.reset()
                    bookSID = nil
                    candleSID = nil
                    liveExtras = []
                    liveExtras = wantedExtras()
                    bookMarket = liveExtras.contains("order-book@\(marketID)") ? marketID : nil
                    // One state stream per chain carries every market; Perpl answers a
                    // per-market `market-state@<id>` with "unknown stream".
                    let streams = ["heartbeat@\(network.chainID)", "market-state@\(network.chainID)"]
                        + liveExtras.sorted()
                    let subscriptions = streams.map { ["stream": $0, "subscribe": true] as [String: Any] }
                    let payload: [String: Any] = ["mt": 5, "subs": subscriptions]
                    let data = try JSONSerialization.data(withJSONObject: payload)
                    try await socket.send(String(decoding: data, as: UTF8.self))

                    while !Task.isCancelled {
                        let text = try await socket.receive()
                        let data = Data(text.utf8)
                        let frame = await Task.detached(priority: .utility) {
                            Self.decodeLive(data)
                        }.value
                        switch frame {
                        case .quotes(let updates):
                            statesFlowing = true
                            ingestLiveQuotes(updates)
                        case .subscribed(let sids): noteSubscriptions(sids)
                        case .book(let update): ingestBook(update)
                        case .candles(let sid, let update): ingestCandles(sid: sid, update)
                        case .head(let block):
                            noteHead(block)
                            restampQuietMark()
                        case .other: break
                        }
                    }
                } catch {
                    self?.statesFlowing = false
                    self?.liveSocket?.close()
                    self?.liveSocket = nil
                    guard !Task.isCancelled else { return }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    private enum LiveFrame: Sendable {
        case quotes([UInt32: Int64])
        case subscribed([String: Int])
        case book(OrderBook.Frame)
        case candles(sid: Int?, [Candle])
        case head(Int64)
        case other
    }

    private struct CandleFrame: Decodable {
        let sid: Int?
        let d: [Candle]
    }

    nonisolated private static func decodeLive(_ data: Data) -> LiveFrame {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mt = (root["mt"] as? NSNumber)?.intValue else { return .other }
        switch mt {
        case 9: return .quotes(decodeLiveQuotes(data))
        case 6:
            var sids: [String: Int] = [:]
            for entry in root["subs"] as? [[String: Any]] ?? [] {
                guard let stream = entry["stream"] as? String, let sid = (entry["sid"] as? NSNumber)?.intValue,
                      ((entry["status"] as? [String: Any])?["code"] as? NSNumber)?.intValue ?? 0 == 0 else { continue }
                sids[stream] = sid
            }
            return .subscribed(sids)
        case 15, 16: return OrderBook.Frame(json: root).map(LiveFrame.book) ?? .other
        case 12:
            guard let frame = try? JSONDecoder().decode(CandleFrame.self, from: data) else { return .other }
            return .candles(sid: frame.sid, frame.d)
        case 100: return wireInt(root["h"]).map(LiveFrame.head) ?? .other
        default: return .other
        }
    }

    private func restampQuietMark() {
        guard statesFlowing, quotes[marketID] != nil, unchangedIsDue(marketID),
              let selected = allMarkets.first(where: { $0.id == marketID }) else { return }
        applyQuote(for: selected, at: .now)
    }

    private func noteHead(_ block: Int64) {
        guard block > headBlock else { return }
        headBlock = block
        onHeadBlock?(block)
    }

    private func noteSubscriptions(_ sids: [String: Int]) {
        if let bookMarket, let sid = sids["order-book@\(bookMarket)"] { bookSID = sid }
        if let sid = sids["candles@\(marketID)*\(candleIntervalSeconds)"] { candleSID = sid }
    }

    private func ingestCandles(sid: Int?, _ update: [Candle]) {
        guard let candleSID, sid == candleSID, !candles.isEmpty else { return }
        for candle in update.sorted(by: { $0.t < $1.t }) {
            if let last = candles.last, candle.t > last.t {
                candles.append(candle)
            } else if let index = candles.lastIndex(where: { $0.t == candle.t }) {
                candles[index] = candle
            }
        }
        if candles.count > Self.candleCap { candles.removeFirst(candles.count - Self.candleCap) }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-log-candles"), let last = candles.last {
            print("live candle \(symbol) \(candleIntervalSeconds)s t=\(last.t) c=\(last.c) count=\(candles.count)")
        }
        #endif
    }

    private func ingestBook(_ frame: OrderBook.Frame) {
        guard bookMarket == marketID else { return }
        if let bookSID {
            guard frame.subscriptionID == nil || frame.subscriptionID == bookSID else { return }
        } else if frame.kind == .snapshot, let sid = frame.subscriptionID {
            bookSID = sid
        }
        book.apply(frame)
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
            // A repeated price is not written (it would redraw every mark reader several times a
            // second); only its freshness stamp is, at most twice a second.
            if quotes[id]?.markRaw == raw, !unchangedIsDue(id) { continue }
            let previous = quotes[id]?.previousRaw
                ?? allMarkets.first(where: { $0.id == id })?.state.previousRaw
                ?? raw
            quotes[id] = Quote(markRaw: raw, previousRaw: previous)
            if id == marketID, let selected = allMarkets.first(where: { $0.id == id }) {
                applyQuote(for: selected, at: .now)
            }
        }
    }

    private func unchangedIsDue(_ id: UInt32) -> Bool {
        let now = ContinuousClock.now
        if let last = restampedAt[id], now - last < .milliseconds(500) { return false }
        restampedAt[id] = now
        return true
    }

    private func applyQuote(for selected: Market, at instant: ContinuousClock.Instant) {
        let raw = quotes[selected.id]?.markRaw ?? selected.state.markRaw
        guard let price = selected.price(raw) else { return }
        mark.restamp(price, at: instant)
        record(market: selected, price: price)
        isLoadingFirstValue = false
    }

    nonisolated private static func wireInt(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return Int64(text) }
        return nil
    }

    func fundingHistory(days: Int = 7) async -> [MarketFunding]? {
        let requestedMarket = marketID
        let to = Int64(Date().timeIntervalSince1970 * 1_000)
        let from = to - Int64(days) * 86_400_000
        guard let endpoint = try? PerplEndpoint(
                method: .get, path: "/v1/market-data/\(requestedMarket)/funding/\(from)-\(to)"),
              let data = try? await rest.publicData(endpoint),
              let series = try? JSONDecoder().decode(FundingSeries.self, from: data),
              requestedMarket == marketID else { return nil }
        return series.events
    }

    private func refreshCandles() async {
        let requestedMarket = marketID
        let requestedInterval = candleIntervalSeconds
        let to = Int64(Date().timeIntervalSince1970 * 1_000)
        let from = to - Int64(requestedInterval * candleDepth * 1_000)
        do {
            let endpoint = try PerplEndpoint(
                method: .get,
                path: "/v1/market-data/\(requestedMarket)/candles/\(requestedInterval)/\(from)-\(to)")
            let data = try await rest.publicData(endpoint)
            let result = try await Task.detached(priority: .utility) {
                try JSONDecoder().decode(CandleSeries.self, from: data).d
            }.value
            guard requestedMarket == marketID, requestedInterval == candleIntervalSeconds else { return }
            if let newest = result.first?.t {
                candles = candles.filter { $0.t < newest } + result
            } else {
                candles = result
            }
            lastCandleFetch = Date()
        } catch {
        }
    }
}
