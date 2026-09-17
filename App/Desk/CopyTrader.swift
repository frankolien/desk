import DeskFlow
import DeskMoney
import DeskPerpl
import Foundation
import Observation

struct CopiedTrader: Codable, Hashable, Identifiable {
    let address: String
    var rules: CopyRules
    let since: Date

    var id: String { address.lowercased() }
}

/// A copy Desk opened and still expects to be open.
struct OpenCopy: Codable, Hashable, Identifiable {
    let id: UUID
    let trader: String
    let marketID: UInt32
    let symbol: String
    let isLong: Bool
    let sizeRaw: Int64
    let leverage: Int
    let margin: Int
    var positionID: Int64?
    let openedAt: Date
}

struct CopyLogEntry: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case opened, closed, protected, skipped, failed, paused }

    let id: UUID
    let date: Date
    let trader: String
    let symbol: String
    let isLong: Bool
    let kind: Kind
    let detail: String
    var leverage: Int?
    var margin: Int?
    /// From the moment the trader's move was read to the fill.
    var fillSeconds: Double?
    /// Realised on close, in AUSD, funding and fees included.
    var pnl: Double?
}

/// Copies followed traders' entries and exits onto this person's own Perpl account.
///
/// Runs only while Desk is open and unlocked, signing with the key that is already in
/// memory. There is no server holding a key that could trade for anyone: that is the
/// trade-off, and stop losses and take profits are placed on Perpl itself so a copy stays
/// protected after Desk closes.
///
/// Each cycle reads the copied traders' books fresh from mainnet, compares them with the
/// last reading and acts on what changed. The first reading after starting is a baseline,
/// so positions a trader already held are never copied late.
@MainActor
@Observable
final class CopyTrader {
    private(set) var traders: [CopiedTrader]
    private(set) var guards: CopyGuards
    private(set) var isPaused: Bool
    private(set) var log: [CopyLogEntry]
    private(set) var open: [OpenCopy]
    private(set) var lastRead: Date?
    private(set) var readProblem: String?
    /// A sentence for the shell's toast when a copy fills or closes.
    var onEvent: ((String) -> Void)?

    let network: DeskNetwork
    private var baselines: [String: [String: ObservedPosition]] = [:]

    private static let interval: Duration = .seconds(4)
    private static let logLimit = 250
    private static let endpoint = "https://web-lovat-nine-49.vercel.app/api/traders"

    init(network: DeskNetwork) {
        self.network = network
        let defaults = UserDefaults.standard
        traders = Self.load([CopiedTrader].self, key: "desk.copy.traders", network: network) ?? []
        guards = Self.load(CopyGuards.self, key: "desk.copy.guards", network: network) ?? CopyGuards()
        log = Self.load([CopyLogEntry].self, key: "desk.copy.log", network: network) ?? []
        open = Self.load([OpenCopy].self, key: "desk.copy.open", network: network) ?? []
        isPaused = defaults.bool(forKey: "desk.copy.paused.\(network.rawValue)")
    }

    // MARK: - Settings

    func rules(for address: String) -> CopyRules? {
        traders.first { $0.id == address.lowercased() }?.rules
    }

    func start(_ address: String, rules: CopyRules) {
        if let index = traders.firstIndex(where: { $0.id == address.lowercased() }) {
            traders[index].rules = rules
        } else {
            traders.append(CopiedTrader(address: address, rules: rules, since: .now))
            baselines[address.lowercased()] = nil
        }
        persist()
    }

    func stop(_ address: String) {
        traders.removeAll { $0.id == address.lowercased() }
        baselines[address.lowercased()] = nil
        persist()
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        persist()
    }

    func updateGuards(_ next: CopyGuards) {
        guards = next
        persist()
    }

    // MARK: - Figures

    var realisedToday: Double {
        log.filter { Calendar.current.isDateInToday($0.date) }.compactMap(\.pnl).reduce(0, +)
    }

    var realisedTotal: Double { log.compactMap(\.pnl).reduce(0, +) }
    var closedCount: Int { log.filter { $0.pnl != nil }.count }
    var copiedCount: Int { log.filter { $0.kind == .opened }.count }

    var winRate: Double? {
        let closed = log.compactMap(\.pnl)
        return closed.isEmpty ? nil : Double(closed.filter { $0 > 0 }.count) / Double(closed.count)
    }

    var averageFillSeconds: Double? {
        let fills = log.compactMap(\.fillSeconds)
        return fills.isEmpty ? nil : fills.reduce(0, +) / Double(fills.count)
    }

    // MARK: - The loop

    func run(model: AppModel, market: MarketModel, session: TradingSession) async {
        while !Task.isCancelled {
            if traders.isEmpty {
                baselines = [:]
                readProblem = nil
            } else {
                await cycle(model: model, market: market, session: session)
            }
            try? await Task.sleep(for: Self.interval)
        }
    }

    private func cycle(model: AppModel, market: MarketModel, session: TradingSession) async {
        guard let books = await readBooks() else {
            readProblem = "Perpl mainnet couldn't be read. Retrying."
            return
        }
        let readAt = Date.now
        readProblem = nil
        lastRead = readAt

        reconcile(model: model)

        for trader in traders {
            guard let after = books[trader.id] else { continue }
            guard let before = baselines[trader.id] else {
                baselines[trader.id] = after
                continue
            }
            baselines[trader.id] = after
            for move in CopyPlanner.moves(before: before, after: after) {
                // Stopped or edited while an earlier move was being sent.
                guard let rules = rules(for: trader.address) else { break }
                switch move {
                case .opened(let position):
                    await openCopy(position, trader: trader.address, rules: rules, readAt: readAt,
                                   model: model, market: market, session: session)
                case .flipped(let position):
                    await closeCopy(trader: trader.address, symbol: position.symbol, because: "flipped",
                                    model: model, market: market, session: session)
                    await openCopy(position, trader: trader.address, rules: rules, readAt: readAt,
                                   model: model, market: market, session: session)
                case .closed(let position):
                    guard rules.closeWithTrader else { continue }
                    await closeCopy(trader: trader.address, symbol: position.symbol, because: "closed",
                                    model: model, market: market, session: session)
                }
            }
        }
    }

    private func readBooks() async -> [String: [String: ObservedPosition]]? {
        var components = URLComponents(string: Self.endpoint)!
        components.queryItems = [
            URLQueryItem(name: "view", value: "following"),
            URLQueryItem(name: "addresses", value: traders.map(\.address).joined(separator: ",")),
            URLQueryItem(name: "fresh", value: "1"),
        ]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try? JSONDecoder().decode(Books.self, from: data) else { return nil }
        var books: [String: [String: ObservedPosition]] = [:]
        for trader in body.traders {
            var book: [String: ObservedPosition] = [:]
            for position in trader.positions {
                let observed = ObservedPosition(
                    symbol: position.market, side: position.isLong ? .long : .short,
                    size: Double(position.size) ?? 0, entry: Double(position.entry) ?? 0,
                    leverage: position.leverage)
                book[observed.symbol] = observed
            }
            books[trader.address.lowercased()] = book
        }
        return books
    }

    private struct Books: Decodable { let traders: [TraderSnapshot] }

    /// Copies that Perpl closed on its own — a stop loss, a take profit, a liquidation, or
    /// the person closing it by hand — are settled from the venue's record of the close.
    private func reconcile(model: AppModel) {
        guard model.trading.positions.value != nil else { return }
        for copy in open {
            guard let positionID = copy.positionID,
                  !model.openPositions.contains(where: { $0.positionID == positionID }) else { continue }
            let closed = model.closedPositions.first { $0.positionID == positionID }
            open.removeAll { $0.id == copy.id }
            record(CopyLogEntry(
                id: UUID(), date: .now, trader: copy.trader, symbol: copy.symbol, isLong: copy.isLong,
                kind: .protected, detail: "Closed on Perpl by your stop loss, take profit or by hand.",
                leverage: copy.leverage, margin: copy.margin,
                pnl: closed?.realisedPnLRaw.map { Double($0) / 1_000_000 }))
        }
    }

    private func openCopy(
        _ position: ObservedPosition, trader: String, rules: CopyRules, readAt: Date,
        model: AppModel, market: MarketModel, session: TradingSession
    ) async {
        let isLong = position.side == .long
        func note(_ kind: CopyLogEntry.Kind, _ detail: String) {
            record(CopyLogEntry(id: UUID(), date: .now, trader: trader, symbol: position.symbol,
                                isLong: isLong, kind: kind, detail: detail))
        }
        guard !isPaused else { return note(.skipped, "Auto-copy was paused.") }
        guard model.isKeyUnlocked else { return note(.skipped, "Desk was locked, so nothing was sent.") }
        guard let target = market.allMarkets.first(where: { $0.symbol.caseInsensitiveCompare(position.symbol) == .orderedSame }) else {
            return note(.skipped, "\(position.symbol) isn't listed on Perpl \(network.shortName.lowercased()).")
        }
        guard !open.contains(where: { $0.trader.lowercased() == trader.lowercased() && $0.marketID == target.id }) else {
            return note(.skipped, "A copy of this trader's \(position.symbol) trade is already open.")
        }
        guard let mark = market.price(for: target) else { return note(.skipped, "No live \(position.symbol) price to size from.") }

        let draft: OrderDesk.Draft
        switch CopyPlanner.draft(
            copying: position, rules: rules, guards: guards, market: target, mark: mark,
            free: model.collateral.value, openCopies: open.count,
            realisedToday: Money(raw: Int64((realisedToday * 1_000_000).rounded())) ?? .zero
        ) {
        case .failure(let skip):
            if case .dailyLossLimit = skip {
                isPaused = true
                persist()
                return record(CopyLogEntry(id: UUID(), date: .now, trader: trader, symbol: position.symbol,
                                           isLong: isLong, kind: .paused, detail: sentence(for: skip, rules: rules)))
            }
            return note(.skipped, sentence(for: skip, rules: rules))
        case .success(let value):
            draft = value
        }

        let leverage = draft.leverageHundredths / 100
        do {
            let frameID = try await session.placeCopy(draft, in: target)
            switch await settlement(of: frameID, session: session) {
            case .settled:
                let positionID = await newPosition(marketID: target.id, isLong: isLong, model: model)
                open.append(OpenCopy(
                    id: UUID(), trader: trader, marketID: target.id, symbol: target.symbol, isLong: isLong,
                    sizeRaw: draft.size.raw, leverage: leverage, margin: rules.marginPerTrade,
                    positionID: positionID, openedAt: .now))
                var entry = CopyLogEntry(
                    id: UUID(), date: .now, trader: trader, symbol: target.symbol, isLong: isLong, kind: .opened,
                    detail: protectionText(rules), leverage: leverage, margin: rules.marginPerTrade)
                entry.fillSeconds = Date.now.timeIntervalSince(readAt)
                record(entry)
                onEvent?("Copied \(Self.name(for: trader)): \(isLong ? "Long" : "Short") \(target.symbol) \(leverage)×")
            case .rejected(let code, let subReason, let error):
                note(.failed, error ?? TradingSession.reason(code: code, subReason: subReason))
            default:
                note(.failed, "The order expired before it filled. Nothing was opened.")
            }
        } catch {
            note(.failed, TradingSession.sentence(for: error))
        }
    }

    private func closeCopy(
        trader: String, symbol: String, because verb: String,
        model: AppModel, market: MarketModel, session: TradingSession
    ) async {
        guard let copy = open.first(where: { $0.trader.lowercased() == trader.lowercased() && $0.symbol == symbol }) else { return }
        func note(_ kind: CopyLogEntry.Kind, _ detail: String, pnl: Double? = nil) {
            record(CopyLogEntry(id: UUID(), date: .now, trader: trader, symbol: symbol, isLong: copy.isLong,
                                kind: kind, detail: detail, leverage: copy.leverage, margin: copy.margin, pnl: pnl))
        }
        let side: Side = copy.isLong ? .long : .short
        guard let position = model.openPositions.first(where: { candidate in
            copy.positionID.map { candidate.positionID == $0 } ?? (candidate.marketID == copy.marketID && candidate.side == side)
        }) else {
            open.removeAll { $0.id == copy.id }
            return
        }
        guard model.isKeyUnlocked else {
            return note(.failed, "They \(verb), but Desk was locked. Your copy is still open; close it from Perps.")
        }
        guard let target = market.market(id: copy.marketID),
              let size = target.size(min(copy.sizeRaw, position.sizeRaw)) else {
            return note(.failed, "The \(symbol) market couldn't be read, so your copy is still open.")
        }
        do {
            let frameID = try await session.closeCopy(position, size: size, in: target)
            switch await settlement(of: frameID, session: session) {
            case .settled:
                open.removeAll { $0.id == copy.id }
                let pnl = await realised(positionID: position.positionID, model: model)
                note(.closed, verb == "flipped" ? "They flipped, so the copy was closed first." : "Closed with the trader.", pnl: pnl)
                onEvent?("Closed copy of \(Self.name(for: trader)) \(symbol)")
            case .rejected(let code, let subReason, let error):
                note(.failed, (error ?? TradingSession.reason(code: code, subReason: subReason)) + " Your copy is still open.")
            default:
                note(.failed, "The close expired before it filled. Your copy is still open.")
            }
        } catch {
            note(.failed, TradingSession.sentence(for: error) + " Your copy is still open.")
        }
    }

    /// The order's final phase, or nil after twenty seconds without one.
    private func settlement(of frameID: Int64, session: TradingSession) async -> OrderPhase? {
        for _ in 0..<80 {
            if let phase = await session.phase(of: frameID), phase.isTerminal { return phase }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    /// The venue's id for the position a fill just opened, once the stream reports it.
    private func newPosition(marketID: UInt32, isLong: Bool, model: AppModel) async -> Int64? {
        let tracked = Set(open.compactMap(\.positionID))
        for _ in 0..<20 {
            if let found = model.openPositions
                .filter({ $0.marketID == marketID && ($0.side == .long) == isLong && !tracked.contains($0.positionID) })
                .max(by: { $0.positionID < $1.positionID }) {
                return found.positionID
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    private func realised(positionID: Int64, model: AppModel) async -> Double? {
        for _ in 0..<20 {
            if let raw = model.closedPositions.first(where: { $0.positionID == positionID })?.realisedPnLRaw {
                return Double(raw) / 1_000_000
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    private func record(_ entry: CopyLogEntry) {
        log.insert(entry, at: 0)
        if log.count > Self.logLimit { log.removeLast(log.count - Self.logLimit) }
        persist()
    }

    private func protectionText(_ rules: CopyRules) -> String {
        var parts = ["\(rules.marginPerTrade) AUSD margin"]
        if let stop = rules.stopLossPercent { parts.append("stop at −\(stop)%") }
        if let take = rules.takeProfitPercent { parts.append("take profit at +\(take)%") }
        return parts.joined(separator: " · ")
    }

    private func sentence(for skip: CopySkip, rules: CopyRules) -> String {
        switch skip {
        case .marketNotListed: "This market isn't listed on Perpl \(network.shortName.lowercased())."
        case .marketClosed: "The market is closed for trading."
        case .openCopiesLimit(let limit): "\(limit) copies are already open, your limit."
        case .dailyLossLimit(let limit): "Today's copy losses reached your \(limit) AUSD limit, so auto-copy paused."
        case .insufficientBalance: "Not enough free AUSD for a \(rules.marginPerTrade) AUSD copy."
        case .chased(let bps): String(format: "Price had already moved %.2f%% past their entry.", Double(bps) / 100)
        case .tooSmall: "\(rules.marginPerTrade) AUSD is too small to size on this market."
        }
    }

    static func name(for address: String) -> String {
        let names = UserDefaults.standard.dictionary(forKey: "desk.traderNicknames") as? [String: String] ?? [:]
        return names[address.lowercased()] ?? TraderSnapshot.short(address)
    }

    // MARK: - Storage

    private func persist() {
        Self.save(traders, key: "desk.copy.traders", network: network)
        Self.save(guards, key: "desk.copy.guards", network: network)
        Self.save(log, key: "desk.copy.log", network: network)
        Self.save(open, key: "desk.copy.open", network: network)
        UserDefaults.standard.set(isPaused, forKey: "desk.copy.paused.\(network.rawValue)")
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String, network: DeskNetwork) -> T? {
        UserDefaults.standard.data(forKey: "\(key).\(network.rawValue)").flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private static func save<T: Encodable>(_ value: T, key: String, network: DeskNetwork) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: "\(key).\(network.rawValue)")
    }

    #if DEBUG
    /// Sample rows for reviewing the screens in a simulator, which cannot sign a real order.
    func seedForReview() {
        guard log.isEmpty else { return }
        let whale = "0x95D2602d30DA1179fd13274839e60345857ca648"
        traders = [CopiedTrader(address: whale, rules: CopyRules(), since: .now.addingTimeInterval(-86_400))]
        func entry(_ minutes: Double, _ symbol: String, _ long: Bool, _ kind: CopyLogEntry.Kind, _ detail: String,
                   fill: Double? = nil, pnl: Double? = nil) -> CopyLogEntry {
            CopyLogEntry(id: UUID(), date: .now.addingTimeInterval(-minutes * 60), trader: whale, symbol: symbol,
                         isLong: long, kind: kind, detail: detail, leverage: 5, margin: 10, fillSeconds: fill, pnl: pnl)
        }
        log = [
            entry(3, "ETH", true, .opened, "10 AUSD margin · stop at −25%", fill: 4.8),
            entry(42, "BTC", false, .closed, "Closed with the trader.", pnl: 3.12),
            entry(95, "SOL", true, .skipped, "Price had already moved 1.40% past their entry."),
            entry(130, "BTC", false, .opened, "10 AUSD margin · stop at −25%", fill: 5.6),
            entry(300, "MON", true, .protected, "Closed on Perpl by your stop loss, take profit or by hand.", pnl: -2.5),
        ]
        open = [OpenCopy(id: UUID(), trader: whale, marketID: 32, symbol: "ETH", isLong: true, sizeRaw: 20,
                         leverage: 5, margin: 10, positionID: nil, openedAt: .now.addingTimeInterval(-180))]
    }
    #endif
}
