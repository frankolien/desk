import DeskFlow
import DeskMoney
import DeskPerpl
import Foundation
import WidgetKit
import Observation

struct CopiedTrader: Codable, Hashable, Identifiable {
    enum Source: String, Codable { case manual, basket }

    let address: String
    var rules: CopyRules
    let since: Date
    var source: Source?

    var id: String { address.lowercased() }
    var isFromBasket: Bool { source == .basket }
}

/// Copy the leaderboard's best as a portfolio: the top traders, re-picked on a schedule, all
/// under one set of rules.
struct CopyBasket: Codable, Hashable {
    var size: Int
    var rules: CopyRules
    var rotateHours: Int
    var lastRotation: Date?
}

/// A copy Desk opened, live or simulated, and still expects to be open.
struct OpenCopy: Codable, Hashable, Identifiable {
    let id: UUID
    let trader: String
    let marketID: UInt32
    let symbol: String
    let isLong: Bool
    let sizeRaw: Int64
    let leverage: Int
    let margin: Double
    var positionID: Int64?
    let openedAt: Date
    var isShadow: Bool?
    var shadow: ShadowFill?
    var lastMark: Double?
    var theirEntry: Double?

    var shadowed: Bool { isShadow == true }
    var notional: Double { margin * Double(leverage) }

    /// Unrealised profit of a shadow copy at the last mark it was priced at.
    func shadowPnL(takerFeeMicros: Int64) -> Double? {
        guard let shadow, let lastMark else { return nil }
        return shadow.pnl(at: lastMark, takerFeeMicros: takerFeeMicros)
    }
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
    var margin: Double?
    /// From the moment the trader's move was seen to the fill.
    var fillSeconds: Double?
    /// Realised on close, in AUSD, funding and fees included.
    var pnl: Double?
    var isShadow: Bool?
    /// How far the fill landed from the trader's entry, against the copy. Negative is better.
    var slippageBps: Int?

    var shadowed: Bool { isShadow == true }
}

/// Copies followed traders' entries and exits onto this person's own Perpl account, or
/// simulates them in shadow.
///
/// Runs only while Desk is open and unlocked, signing with the key that is already in
/// memory. No server holds a key that could trade for anyone: that is the trade-off, and
/// live stops and take profits are placed on Perpl itself so a copy stays protected after
/// Desk closes.
///
/// A websocket on Monad streams Perpl's position events, and one naming a copied trader's
/// account wakes the loop at once, so a copy follows the block the trader moved in rather
/// than the next poll. The poll stays underneath as the fallback. Every cycle reads the
/// traders' books fresh and acts on what changed; the first reading is a baseline, so a
/// position a trader already held is never copied late.
@MainActor
@Observable
final class CopyTrader {
    private(set) var traders: [CopiedTrader]
    private(set) var guards: CopyGuards
    private(set) var isPaused: Bool
    private(set) var log: [CopyLogEntry]
    private(set) var open: [OpenCopy]
    private(set) var basket: CopyBasket?
    private(set) var lastRead: Date?
    private(set) var readProblem: String?
    /// Whether moves are arriving from the chain as they happen.
    private(set) var isStreaming = false
    /// A sentence for the shell's toast when a copy fills or closes.
    var onEvent: ((String) -> Void)?

    let network: DeskNetwork
    private var baselines: [String: [String: ObservedPosition]] = [:]
    /// Traders whose book read as empty once. A second reading has to agree before the
    /// copies are closed.
    private var unconfirmedFlat: Set<String> = []
    private var portfolios: [String: Double] = [:]
    private var accounts: [UInt64: String] = [:]
    private var wokenAt: Date?
    private let stream = PositionStream()
    private let glance = AutoCopyPublisher()
    private var mainnet = MainnetMarkets()

    private static let pollWhileStreaming: TimeInterval = 15
    private static let pollWithoutStream: TimeInterval = 4
    private static let logLimit = 400
    private static let endpoint = "https://web-lovat-nine-49.vercel.app/api/traders"
    private static let exchange = "0x34B6552d57a35a1D042CcAe1951BD1C370112a6F"
    private static let defaultTakerFeeMicros: Int64 = 345

    init(network: DeskNetwork) {
        self.network = network
        traders = Self.load([CopiedTrader].self, key: "desk.copy.traders", network: network) ?? []
        guards = Self.load(CopyGuards.self, key: "desk.copy.guards", network: network) ?? CopyGuards()
        log = Self.load([CopyLogEntry].self, key: "desk.copy.log", network: network) ?? []
        open = Self.load([OpenCopy].self, key: "desk.copy.open", network: network) ?? []
        basket = Self.load(CopyBasket.self, key: "desk.copy.basket", network: network)
        isPaused = AutoCopySwitch.isPaused
        stream.onMove = { [weak self] account in
            guard let self, self.accounts[account] != nil else { return }
            self.wokenAt = self.wokenAt ?? .now
        }
        stream.onState = { [weak self] live in self?.isStreaming = live }
    }

    // MARK: - Settings

    func rules(for address: String) -> CopyRules? {
        traders.first { $0.id == address.lowercased() }?.rules
    }

    func start(_ address: String, rules: CopyRules) {
        if let index = traders.firstIndex(where: { $0.id == address.lowercased() }) {
            traders[index].rules = rules
            traders[index].source = .manual
        } else {
            traders.append(CopiedTrader(address: address, rules: rules, since: .now, source: .manual))
            baselines[address.lowercased()] = nil
        }
        persist()
    }

    func stop(_ address: String) {
        traders.removeAll { $0.id == address.lowercased() }
        baselines[address.lowercased()] = nil
        persist()
    }

    func setMode(_ mode: CopyMode, for address: String) {
        guard let index = traders.firstIndex(where: { $0.id == address.lowercased() }) else { return }
        traders[index].rules.mode = mode
        persist()
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        AutoCopySwitch.isPaused = paused
        persist()
        ControlCenter.shared.reloadControls(ofKind: AutoCopyControl.controlKind)
    }

    func updateGuards(_ next: CopyGuards) {
        guards = next
        persist()
    }

    func startBasket(size: Int, rules: CopyRules, rotateHours: Int) {
        basket = CopyBasket(size: size, rules: rules, rotateHours: rotateHours, lastRotation: nil)
        persist()
    }

    func stopBasket() {
        basket = nil
        traders.removeAll(where: \.isFromBasket)
        persist()
    }

    /// Closes a shadow copy by hand at its last mark.
    func closeShadow(_ copy: OpenCopy) {
        guard copy.shadowed, let mark = copy.lastMark else { return }
        settleShadow(copy, at: mark, detail: "Closed by you.")
    }

    // MARK: - Figures

    struct Figures {
        let realised: Double
        let today: Double
        let winRate: Double?
        let closed: Int
        let copies: Int
        let averageFillSeconds: Double?
        let averageSlippageBps: Double?
    }

    func figures(shadow: Bool) -> Figures {
        let entries = log.filter { $0.shadowed == shadow }
        let closed = entries.compactMap(\.pnl)
        let fills = entries.compactMap(\.fillSeconds)
        let slips = entries.compactMap(\.slippageBps)
        return Figures(
            realised: closed.reduce(0, +),
            today: entries.filter { Calendar.current.isDateInToday($0.date) }.compactMap(\.pnl).reduce(0, +),
            winRate: closed.isEmpty ? nil : Double(closed.filter { $0 > 0 }.count) / Double(closed.count),
            closed: closed.count,
            copies: entries.filter { $0.kind == .opened }.count,
            averageFillSeconds: fills.isEmpty ? nil : fills.reduce(0, +) / Double(fills.count),
            averageSlippageBps: slips.isEmpty ? nil : Double(slips.reduce(0, +)) / Double(slips.count))
    }

    var realisedToday: Double { figures(shadow: false).today + figures(shadow: true).today }

    func takerFee(for symbol: String) -> Int64 {
        mainnet.market(symbol)?.config.takerFeeMicros ?? Self.defaultTakerFeeMicros
    }

    /// What copying one trader has made so far, in each mode.
    func record(for address: String) -> (live: Double, shadow: Double, trades: Int) {
        let entries = log.filter { $0.trader.lowercased() == address.lowercased() }
        return (entries.filter { !$0.shadowed }.compactMap(\.pnl).reduce(0, +),
                entries.filter(\.shadowed).compactMap(\.pnl).reduce(0, +),
                entries.compactMap(\.pnl).count)
    }

    // MARK: - The loop

    func run(model: AppModel, market: MarketModel, session: TradingSession) async {
        defer { stream.stop() }
        var lastCycle = Date.distantPast
        var streaming = false
        while !Task.isCancelled {
            // Siri, Control Center, the widget or the Live Activity may have flipped it.
            if AutoCopySwitch.isPaused != isPaused {
                isPaused = AutoCopySwitch.isPaused
                record(CopyLogEntry(
                    id: UUID(), date: .now, trader: "", symbol: "", isLong: true, kind: .paused,
                    detail: isPaused ? "Auto-copy paused from outside Desk." : "Auto-copy resumed from outside Desk."))
            }
            let active = !traders.isEmpty || basket != nil || !open.isEmpty
            // The stream carries every position event on the exchange, so it runs only while
            // there is someone to copy.
            if active != streaming {
                streaming = active
                if active {
                    stream.start(url: URL(string: "wss://rpc.monad.xyz")!, exchange: Self.exchange)
                } else {
                    stream.stop()
                }
            }
            let interval = isStreaming ? Self.pollWhileStreaming : Self.pollWithoutStream
            if active && (wokenAt != nil || Date.now.timeIntervalSince(lastCycle) >= interval) {
                let seenAt = wokenAt ?? .now
                wokenAt = nil
                lastCycle = .now
                await cycle(seenAt: seenAt, model: model, market: market, session: session)
            } else if !active {
                baselines = [:]
                readProblem = nil
            }
            glance.follow(self)
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func cycle(seenAt: Date, model: AppModel, market: MarketModel, session: TradingSession) async {
        await rotateBasketIfDue()
        guard !traders.isEmpty || !open.isEmpty else { return }
        guard let books = await readBooks() else {
            readProblem = "Perpl mainnet couldn't be read. Retrying."
            return
        }
        readProblem = nil
        lastRead = .now
        stream.watch(Set(accounts.keys))

        var marks: [String: Double] = [:]
        for book in books.values {
            for position in book.values where position.mark > 0 { marks[position.symbol] = position.mark }
        }
        if mainnet.isStale && open.contains(where: { $0.shadowed && marks[$0.symbol] == nil }) {
            await refreshMainnet()
        }
        for (symbol, mark) in mainnet.marks where marks[symbol] == nil { marks[symbol] = mark }

        reconcileLive(model: model)
        priceShadows(marks)

        for trader in traders {
            guard let after = books[trader.id] else { continue }
            guard let before = baselines[trader.id] else {
                baselines[trader.id] = after
                continue
            }
            // A book that went from held to empty in one reading is the shape a failed read
            // takes when it arrives as a success. A real full close still looks like this on
            // the next reading, so it costs one cycle and nothing else; a blip costs nothing.
            if after.isEmpty, !before.isEmpty, unconfirmedFlat.insert(trader.id).inserted {
                continue
            }
            if !after.isEmpty { unconfirmedFlat.remove(trader.id) }
            baselines[trader.id] = after
            for move in CopyPlanner.moves(before: before, after: after) {
                // Stopped or edited while an earlier move was being sent.
                guard let rules = rules(for: trader.address) else { break }
                switch move {
                case .opened(let position):
                    await openCopy(position, trader: trader.address, rules: rules, seenAt: seenAt,
                                   model: model, market: market, session: session)
                case .flipped(let position):
                    await closeCopy(trader: trader.address, symbol: position.symbol, because: "flipped",
                                    mark: position.mark, model: model, market: market, session: session)
                    await openCopy(position, trader: trader.address, rules: rules, seenAt: seenAt,
                                   model: model, market: market, session: session)
                case .closed(let position):
                    guard rules.closeWithTrader else { continue }
                    await closeCopy(trader: trader.address, symbol: position.symbol, because: "closed",
                                    mark: marks[position.symbol] ?? position.mark,
                                    model: model, market: market, session: session)
                }
            }
        }
    }

    private func readBooks() async -> [String: [String: ObservedPosition]]? {
        let addresses = Array(Set(traders.map(\.id) + open.map { $0.trader.lowercased() })).sorted().prefix(20)
        guard !addresses.isEmpty else { return [:] }
        var components = URLComponents(string: Self.endpoint)!
        components.queryItems = [
            URLQueryItem(name: "view", value: "following"),
            URLQueryItem(name: "addresses", value: addresses.joined(separator: ",")),
            URLQueryItem(name: "fresh", value: "1"),
        ]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try? JSONDecoder().decode(Books.self, from: data) else { return nil }
        var books: [String: [String: ObservedPosition]] = [:]
        for trader in body.traders {
            // The server says so when the chain would not answer. Leaving the trader out of
            // `books` skips their diff entirely, which is what an unknown book deserves.
            if trader.unreadable == true { continue }
            var book: [String: ObservedPosition] = [:]
            for position in trader.positions {
                let observed = ObservedPosition(
                    symbol: position.market, side: position.isLong ? .long : .short,
                    size: Double(position.size) ?? 0, entry: Double(position.entry) ?? 0,
                    mark: Double(position.mark) ?? 0, collateral: Double(position.collateral) ?? 0,
                    leverage: position.leverage)
                book[observed.symbol] = observed
            }
            books[trader.id] = book
            portfolios[trader.id] = trader.portfolio
            if let account = trader.accountId.flatMap(UInt64.init) { accounts[account] = trader.id }
        }
        return books
    }

    private struct Books: Decodable { let traders: [TraderSnapshot] }

    private func refreshMainnet() async {
        if let fetched = await MainnetMarkets.fetch() { mainnet.update(fetched) }
    }

    // MARK: - Baskets

    private func rotateBasketIfDue() async {
        guard let basket else { return }
        if let last = basket.lastRotation, Date.now.timeIntervalSince(last) < Double(basket.rotateHours) * 3600 { return }
        let manual = Set(traders.filter { !$0.isFromBasket }.map(\.id))
        // Best by indexed score first, so the basket holds consistent traders rather than
        // whoever is up most right now; open PnL only when no history exists yet.
        var candidates = await basketCandidates(view: "scores")
        if candidates.count < basket.size { candidates += await basketCandidates(view: "top") }
        var seen = Set<String>()
        let picked = candidates
            .filter { !manual.contains($0.lowercased()) && seen.insert($0.lowercased()).inserted }
            .prefix(basket.size)
            .map { $0 }
        guard !picked.isEmpty else { return }
        let pickedIDs = Set(picked.map { $0.lowercased() })
        let leaving = traders.filter { $0.isFromBasket && !pickedIDs.contains($0.id) }.count
        let joining = picked.filter { address in !traders.contains { $0.id == address.lowercased() } }
        traders.removeAll { $0.isFromBasket && !pickedIDs.contains($0.id) }
        for address in joining {
            traders.append(CopiedTrader(address: address, rules: basket.rules, since: .now, source: .basket))
        }
        self.basket?.lastRotation = .now
        if leaving > 0 || !joining.isEmpty {
            record(CopyLogEntry(
                id: UUID(), date: .now, trader: joining.first ?? "", symbol: "", isLong: true, kind: .paused,
                detail: "Basket re-picked from the leaderboard: \(joining.count) in, \(leaving) out.",
                isShadow: basket.rules.mode == .shadow))
        }
        persist()
    }

    private func basketCandidates(view: String) async -> [String] {
        var components = URLComponents(string: Self.endpoint)!
        components.queryItems = [URLQueryItem(name: "view", value: view)]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try? JSONDecoder().decode(Candidates.self, from: data) else { return [] }
        return body.traders.filter { $0.score.map { $0 >= 50 } ?? !($0.positions ?? []).isEmpty }.map(\.address)
    }

    private struct Candidates: Decodable {
        struct Row: Decodable { let address: String; let score: Int?; let positions: [TraderPosition]? }
        let traders: [Row]
    }

    // MARK: - Shadow copies

    private func priceShadows(_ marks: [String: Double]) {
        for copy in open where copy.shadowed {
            guard let mark = marks[copy.symbol], let index = open.firstIndex(where: { $0.id == copy.id }) else { continue }
            open[index].lastMark = mark
            if let fill = copy.shadow, let price = fill.trigger(at: mark) {
                settleShadow(open[index], at: price,
                             detail: price == fill.stop ? "Stop loss hit." : "Take profit hit.", protected: true)
            }
        }
    }

    private func settleShadow(_ copy: OpenCopy, at price: Double, detail: String, protected: Bool = false) {
        guard let fill = copy.shadow else { return }
        open.removeAll { $0.id == copy.id }
        record(CopyLogEntry(
            id: UUID(), date: .now, trader: copy.trader, symbol: copy.symbol, isLong: copy.isLong,
            kind: protected ? .protected : .closed, detail: detail, leverage: copy.leverage, margin: copy.margin,
            pnl: fill.pnl(at: price, takerFeeMicros: takerFee(for: copy.symbol)), isShadow: true))
    }

    // MARK: - Opening

    private func openCopy(
        _ theirs: ObservedPosition, trader: String, rules: CopyRules, seenAt: Date,
        model: AppModel, market: MarketModel, session: TradingSession
    ) async {
        let shadow = rules.mode == .shadow
        let side = CopyPlanner.side(for: theirs, rules: rules)
        func note(_ kind: CopyLogEntry.Kind, _ detail: String) {
            record(CopyLogEntry(id: UUID(), date: .now, trader: trader, symbol: theirs.symbol,
                                isLong: side == .long, kind: kind, detail: detail, isShadow: shadow))
        }
        guard !isPaused else { return note(.skipped, "Auto-copy was paused.") }
        if !shadow, !model.isKeyUnlocked { return note(.skipped, "Desk was locked, so nothing was sent.") }

        // Shadow copies are priced on mainnet, where the trader actually trades.
        if shadow, mainnet.market(theirs.symbol) == nil { await refreshMainnet() }
        let target = shadow
            ? mainnet.market(theirs.symbol)
            : market.allMarkets.first { $0.symbol.caseInsensitiveCompare(theirs.symbol) == .orderedSame }
        guard let target else {
            return note(.skipped, "\(theirs.symbol) isn't listed on Perpl \(shadow ? "mainnet" : network.shortName.lowercased()).")
        }
        let symbol = target.symbol.uppercased()
        guard !open.contains(where: { $0.trader.lowercased() == trader.lowercased() && $0.symbol == symbol && $0.shadowed == shadow }) else {
            return note(.skipped, "A copy of this trader's \(symbol) trade is already open.")
        }
        let mark = shadow
            ? Price(text: String(format: "%.8f", theirs.mark), decimals: target.config.priceDecimals, rounding: .towardZero)
            : market.price(for: target)
        guard let mark, mark.raw > 0 else { return note(.skipped, "No live \(symbol) price to size from.") }

        let peers = open.filter { $0.shadowed == shadow }
        let exposure = peers.map { CopyExposure(symbol: $0.symbol, side: $0.isLong ? .long : .short, notional: $0.notional) }
        let today = figures(shadow: shadow).today
        let free = shadow ? Money(raw: 1_000_000_000_000) : model.collateral.value

        let plan: CopyPlan
        switch CopyPlanner.plan(
            copying: theirs, traderPortfolio: portfolios[trader.lowercased()], rules: rules, guards: guards,
            market: target, mark: mark, free: free, openCopies: exposure,
            realisedToday: Money(raw: Int64((today * 1_000_000).rounded())) ?? .zero
        ) {
        case .failure(let skip):
            if case .dailyLossLimit = skip {
                // Through `setPaused`, so the App Group flag the run loop, the widget, Siri
                // and Control Center all read is set too. Assigning the field alone was
                // undone by the next tick, which then logged a resume nobody asked for.
                setPaused(true)
                return note(.paused, sentence(for: skip, rules: rules))
            }
            return note(.skipped, sentence(for: skip, rules: rules))
        case .success(let value):
            plan = value
        }

        let label = "\(side == .long ? "Long" : "Short") \(symbol) \(plan.leverage)×"
        var entry = CopyLogEntry(
            id: UUID(), date: .now, trader: trader, symbol: symbol, isLong: side == .long, kind: .opened,
            detail: detail(for: plan, rules: rules), leverage: plan.leverage, margin: plan.margin, isShadow: shadow)

        if shadow {
            let markValue = Double(mark.raw) / pow(10, Double(mark.decimals))
            let fill = ShadowFill(mark: markValue, plan: plan, takerFeeMicros: target.config.takerFeeMicros, rules: rules)
            open.append(OpenCopy(
                id: UUID(), trader: trader, marketID: target.id, symbol: symbol, isLong: side == .long,
                sizeRaw: plan.draft.size.raw, leverage: plan.leverage, margin: plan.margin, positionID: nil,
                openedAt: .now, isShadow: true, shadow: fill, lastMark: markValue, theirEntry: theirs.entry))
            entry.fillSeconds = Date.now.timeIntervalSince(seenAt)
            entry.slippageBps = CopyPlanner.chaseBps(entry: theirs.entry, mark: fill.entry, side: side)
            record(entry)
            onEvent?("Shadow copied \(Self.name(for: trader)): \(label)")
            return
        }

        do {
            let frameID = try await session.placeCopy(plan.draft, in: target)
            switch await settlement(of: frameID, session: session) {
            case .settled:
                let filled = await newPosition(marketID: target.id, isLong: side == .long, model: model)
                open.append(OpenCopy(
                    id: UUID(), trader: trader, marketID: target.id, symbol: symbol, isLong: side == .long,
                    sizeRaw: plan.draft.size.raw, leverage: plan.leverage, margin: plan.margin,
                    positionID: filled?.positionID, openedAt: .now, theirEntry: theirs.entry))
                entry.fillSeconds = Date.now.timeIntervalSince(seenAt)
                if let filled, let price = target.price(filled.entryRaw) {
                    let fillValue = Double(price.raw) / pow(10, Double(price.decimals))
                    entry.slippageBps = CopyPlanner.chaseBps(entry: theirs.entry, mark: fillValue, side: side)
                }
                record(entry)
                onEvent?("Copied \(Self.name(for: trader)): \(label)")
            case .rejected(let code, let subReason, let error):
                note(.failed, error ?? TradingSession.reason(code: code, subReason: subReason))
            default:
                note(.failed, "The order expired before it filled. Nothing was opened.")
            }
        } catch {
            note(.failed, TradingSession.sentence(for: error))
        }
    }

    // MARK: - Closing

    private func closeCopy(
        trader: String, symbol: String, because verb: String, mark: Double,
        model: AppModel, market: MarketModel, session: TradingSession
    ) async {
        let reason = verb == "flipped" ? "They flipped, so the copy was closed first." : "Closed with the trader."
        for copy in open where copy.shadowed && copy.trader.lowercased() == trader.lowercased() && copy.symbol == symbol {
            settleShadow(copy, at: mark > 0 ? mark : (copy.lastMark ?? copy.shadow?.entry ?? 0), detail: reason)
        }

        guard let copy = open.first(where: { !$0.shadowed && $0.trader.lowercased() == trader.lowercased() && $0.symbol == symbol }) else { return }
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
                note(.closed, reason, pnl: pnl)
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

    /// Live copies Perpl closed on its own — a stop loss, a take profit, a liquidation, or
    /// the person closing it by hand — are settled from the venue's record of the close.
    private func reconcileLive(model: AppModel) {
        guard model.trading.positions.value != nil else { return }
        for copy in open where !copy.shadowed {
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

    /// The order's final phase, or nil after twenty seconds without one.
    private func settlement(of frameID: Int64, session: TradingSession) async -> OrderPhase? {
        for _ in 0..<80 {
            if let phase = await session.phase(of: frameID), phase.isTerminal { return phase }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    /// The position a fill just opened, once the stream reports it.
    private func newPosition(marketID: UInt32, isLong: Bool, model: AppModel) async -> PerplPosition? {
        let tracked = Set(open.compactMap(\.positionID))
        for _ in 0..<20 {
            if let found = model.openPositions
                .filter({ $0.marketID == marketID && ($0.side == .long) == isLong && !tracked.contains($0.positionID) })
                .max(by: { $0.positionID < $1.positionID }) {
                return found
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

    private func detail(for plan: CopyPlan, rules: CopyRules) -> String {
        var parts = [String(format: "%.2f AUSD margin", plan.margin)]
        if rules.direction == .fade { parts.append("fading them") }
        if rules.sizing == .conviction, plan.margin != Double(rules.marginPerTrade) {
            parts.append(String(format: "%.1f× conviction", plan.margin / Double(rules.marginPerTrade)))
        }
        if let stop = rules.stopLossPercent { parts.append("stop −\(stop)%") }
        if let take = rules.takeProfitPercent { parts.append("take +\(take)%") }
        return parts.joined(separator: " · ")
    }

    private func sentence(for skip: CopySkip, rules: CopyRules) -> String {
        switch skip {
        case .marketNotListed: "This market isn't listed on Perpl \(network.shortName.lowercased())."
        case .marketClosed: "The market is closed for trading."
        case .openCopiesLimit(let limit): "\(limit) copies are already open, your limit."
        case .dailyLossLimit(let limit): "Today's copy losses reached your \(limit) AUSD limit, so auto-copy paused."
        case .insufficientBalance: "Not enough free AUSD for a \(rules.marginPerTrade) AUSD copy."
        case .chased(let bps): String(format: "Price had already moved %.2f%% against the copy since their entry.", Double(bps) / 100)
        case .tooSmall: "\(rules.marginPerTrade) AUSD is too small to size on this market."
        case .offsetsOpenCopy: "It would offset a copy you already hold on the other side of this market."
        case .exposureLimit(let limit): "This market already holds your \(limit) AUSD exposure limit."
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
        Self.save(basket, key: "desk.copy.basket", network: network)
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String, network: DeskNetwork) -> T? {
        UserDefaults.standard.data(forKey: "\(key).\(network.rawValue)").flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private static func save<T: Encodable>(_ value: T, key: String, network: DeskNetwork) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: "\(key).\(network.rawValue)")
    }

    #if DEBUG
    /// Sample rows for reviewing the screens in a simulator, which cannot sign a real order.
    /// Never persisted.
    func seedForReview() {
        guard log.isEmpty else { return }
        let whale = "0x95D2602d30DA1179fd13274839e60345857ca648"
        traders = [CopiedTrader(address: whale, rules: CopyRules(mode: .shadow, sizing: .conviction),
                                since: .now.addingTimeInterval(-86_400), source: .manual)]
        func entry(_ minutes: Double, _ symbol: String, _ long: Bool, _ kind: CopyLogEntry.Kind, _ detail: String,
                   fill: Double? = nil, pnl: Double? = nil, slip: Int? = nil) -> CopyLogEntry {
            CopyLogEntry(id: UUID(), date: .now.addingTimeInterval(-minutes * 60), trader: whale, symbol: symbol,
                         isLong: long, kind: kind, detail: detail, leverage: 5, margin: 10, fillSeconds: fill, pnl: pnl,
                         isShadow: true, slippageBps: slip)
        }
        log = [
            entry(3, "ETH", true, .opened, "10.00 AUSD margin · stop −25%", fill: 0.9, slip: 4),
            entry(42, "BTC", false, .closed, "Closed with the trader.", pnl: 3.12),
            entry(95, "SOL", true, .skipped, "Price had already moved 1.40% against the copy since their entry."),
            entry(130, "BTC", false, .opened, "14.20 AUSD margin · 1.4× conviction · stop −25%", fill: 1.2, slip: -2),
            entry(300, "MON", true, .protected, "Stop loss hit.", pnl: -2.5),
        ]
        let fill = ShadowFill(entry: 2_440.7, units: 0.0205, margin: 10, leverage: 5, isLong: true,
                              stop: 2_318.7, take: nil, fees: 0.017)
        open = [OpenCopy(id: UUID(), trader: whale, marketID: 20, symbol: "ETH", isLong: true, sizeRaw: 20,
                         leverage: 5, margin: 10, positionID: nil, openedAt: .now.addingTimeInterval(-180),
                         isShadow: true, shadow: fill, lastMark: 2_458, theirEntry: 2_440)]
    }
    #endif
}

/// Perpl mainnet's markets and marks, for pricing shadow copies against the real venue
/// whichever network Desk trades on.
struct MainnetMarkets {
    private(set) var markets: [String: Market] = [:]
    private var fetchedAt: Date?

    var isStale: Bool { fetchedAt.map { Date.now.timeIntervalSince($0) > 30 } ?? true }

    var marks: [String: Double] {
        markets.reduce(into: [:]) { result, entry in
            result[entry.key] = Double(entry.value.state.markRaw) / pow(10, Double(entry.value.config.priceDecimals))
        }
    }

    func market(_ symbol: String) -> Market? { markets[symbol.uppercased()] }

    static func fetch() async -> [String: Market]? {
        guard let configuration = try? DeskNetwork.mainnet.perpl(),
              let context = try? await PerplREST(configuration: configuration).context() else { return nil }
        return Dictionary(context.markets.filter(\.config.isOpen).map { ($0.symbol.uppercased(), $0) },
                          uniquingKeysWith: { first, _ in first })
    }

    mutating func update(_ fetched: [String: Market]) {
        markets = fetched
        fetchedAt = .now
    }
}

/// Perpl's position events from a Monad websocket, reduced to "this account moved".
///
/// Reconnects with backoff when the socket drops. Nothing here decides anything: a move
/// only wakes the copy loop, which reads the trader's book before acting.
@MainActor
final class PositionStream {
    var onMove: ((UInt64) -> Void)?
    var onState: ((Bool) -> Void)?

    private var watched: Set<UInt64> = []
    private var runner: Task<Void, Never>?

    func watch(_ accounts: Set<UInt64>) { watched = accounts }

    func start(url: URL, exchange: String) {
        runner?.cancel()
        runner = Task { [weak self] in
            var delay: Duration = .seconds(1)
            while !Task.isCancelled {
                let task = URLSession.shared.webSocketTask(with: url)
                task.resume()
                do {
                    try await task.send(.string(PositionEvents.subscription(exchange: exchange)))
                    delay = .seconds(1)
                    while !Task.isCancelled {
                        let message = try await task.receive()
                        guard case .string(let text) = message else { continue }
                        if text.contains("\"id\":1"), text.contains("result") { self?.onState?(true); continue }
                        guard let self, let account = PositionEvents.account(inFrame: text),
                              self.watched.contains(account) else { continue }
                        self.onMove?(account)
                    }
                } catch {
                    self?.onState?(false)
                }
                task.cancel(with: .goingAway, reason: nil)
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, .seconds(30))
            }
        }
    }

    func stop() {
        runner?.cancel()
        runner = nil
        onState?(false)
    }
}
