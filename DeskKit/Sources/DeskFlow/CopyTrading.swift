import DeskMoney
import DeskPerpl
import Foundation

/// Live copies send orders. Shadow copies send nothing: they fill at the live mainnet
/// price with the venue's fee, so a trader can be tried before any money follows them.
public enum CopyMode: String, Codable, Sendable, Hashable, CaseIterable { case shadow, live }

/// Follow takes the trader's side. Fade takes the other one, for traders who are
/// reliably wrong.
public enum CopyDirection: String, Codable, Sendable, Hashable, CaseIterable { case follow, fade }

/// Fixed commits the same margin every time. Conviction scales it by how much of their
/// own account the trader put behind the trade.
public enum CopySizing: String, Codable, Sendable, Hashable, CaseIterable { case fixed, conviction }

/// How one followed trader is copied. Every limit is the copier's, not the trader's: their
/// size is sized to their account, so only their market, side and leverage carry over.
public struct CopyRules: Codable, Sendable, Hashable {
    public var mode: CopyMode
    public var direction: CopyDirection
    public var sizing: CopySizing
    /// Collateral committed to each copied trade, in whole AUSD, before conviction scaling.
    public var marginPerTrade: Int
    /// The trader's leverage is followed up to this and never past it.
    public var maxLeverage: Int
    /// Loss on the trade's margin, in percent, at which the copy is closed. Live copies
    /// send it as a Perpl trigger order, so it holds while Desk is closed.
    public var stopLossPercent: Int?
    public var takeProfitPercent: Int?
    /// Close the copy when the trader closes.
    public var closeWithTrader: Bool
    /// How far the market may have moved against the copy's side since the trader's
    /// entry, in basis points. Also the price bound the order is sent with, so a fill can
    /// never land further from their entry than this.
    public var maxChaseBps: Int

    public init(
        mode: CopyMode = .shadow, direction: CopyDirection = .follow, sizing: CopySizing = .fixed,
        marginPerTrade: Int = 10, maxLeverage: Int = 5, stopLossPercent: Int? = 25,
        takeProfitPercent: Int? = nil, closeWithTrader: Bool = true, maxChaseBps: Int = 100
    ) {
        self.mode = mode
        self.direction = direction
        self.sizing = sizing
        self.marginPerTrade = marginPerTrade
        self.maxLeverage = maxLeverage
        self.stopLossPercent = stopLossPercent
        self.takeProfitPercent = takeProfitPercent
        self.closeWithTrader = closeWithTrader
        self.maxChaseBps = maxChaseBps
    }

    /// Rules saved before modes existed were live, followed and fixed.
    public init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        mode = try box.decodeIfPresent(CopyMode.self, forKey: .mode) ?? .live
        direction = try box.decodeIfPresent(CopyDirection.self, forKey: .direction) ?? .follow
        sizing = try box.decodeIfPresent(CopySizing.self, forKey: .sizing) ?? .fixed
        marginPerTrade = try box.decode(Int.self, forKey: .marginPerTrade)
        maxLeverage = try box.decode(Int.self, forKey: .maxLeverage)
        stopLossPercent = try box.decodeIfPresent(Int.self, forKey: .stopLossPercent)
        takeProfitPercent = try box.decodeIfPresent(Int.self, forKey: .takeProfitPercent)
        closeWithTrader = try box.decode(Bool.self, forKey: .closeWithTrader)
        maxChaseBps = try box.decode(Int.self, forKey: .maxChaseBps)
    }
}

/// Limits across every trader being copied.
public struct CopyGuards: Codable, Sendable, Hashable {
    public var maxOpenCopies: Int
    /// Realised copy losses today, in whole AUSD, after which copying pauses itself.
    public var dailyLossLimit: Int
    /// Notional, in whole AUSD, that copies may hold on one side of one market. Two traders
    /// long BTC should not quietly double the copier's BTC risk.
    public var maxMarketExposure: Int

    public init(maxOpenCopies: Int = 3, dailyLossLimit: Int = 50, maxMarketExposure: Int = 250) {
        self.maxOpenCopies = maxOpenCopies
        self.dailyLossLimit = dailyLossLimit
        self.maxMarketExposure = maxMarketExposure
    }

    public init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        maxOpenCopies = try box.decode(Int.self, forKey: .maxOpenCopies)
        dailyLossLimit = try box.decode(Int.self, forKey: .dailyLossLimit)
        maxMarketExposure = try box.decodeIfPresent(Int.self, forKey: .maxMarketExposure) ?? 250
    }
}

/// A followed trader's position as read from mainnet, by market symbol.
public struct ObservedPosition: Sendable, Hashable {
    public let symbol: String
    public let side: Side
    public let size: Double
    public let entry: Double
    public let mark: Double
    public let collateral: Double
    public let leverage: Double?

    public init(symbol: String, side: Side, size: Double, entry: Double, mark: Double = 0,
                collateral: Double = 0, leverage: Double?) {
        self.symbol = symbol.uppercased()
        self.side = side
        self.size = size
        self.entry = entry
        self.mark = mark
        self.collateral = collateral
        self.leverage = leverage
    }
}

public enum TraderMove: Sendable, Hashable {
    case opened(ObservedPosition)
    /// Closed one side and opened the other in the same market between two readings.
    case flipped(ObservedPosition)
    case closed(ObservedPosition)
}

/// A copy already held, as far as the exposure guard needs to know.
public struct CopyExposure: Sendable, Hashable {
    public let symbol: String
    public let side: Side
    public let notional: Double

    public init(symbol: String, side: Side, notional: Double) {
        self.symbol = symbol.uppercased()
        self.side = side
        self.notional = notional
    }
}

public enum CopySkip: Error, Sendable, Hashable {
    case marketNotListed
    case marketClosed
    case openCopiesLimit(Int)
    case dailyLossLimit(Int)
    case insufficientBalance
    case chased(bps: Int)
    case tooSmall
    /// A copy on the other side of this market is open; taking both would pay fees to hold nothing.
    case offsetsOpenCopy
    case exposureLimit(Int)
}

/// Everything decided about one copy before it is sent or simulated.
public struct CopyPlan: Sendable, Hashable {
    public let side: Side
    public let leverage: Int
    /// Whole-cent AUSD margin after conviction scaling and the exposure guard.
    public let margin: Double
    public let draft: OrderDesk.Draft

    public var notional: Double { margin * Double(leverage) }
}

public enum CopyPlanner {
    /// What changed between two readings of a trader's book. Adds and trims are not moves
    /// a copier follows: sizing is the copier's own, so only entries and exits carry over.
    public static func moves(
        before: [String: ObservedPosition], after: [String: ObservedPosition]
    ) -> [TraderMove] {
        var moves: [TraderMove] = []
        for symbol in after.keys.sorted() {
            guard let now = after[symbol] else { continue }
            if let was = before[symbol] {
                if was.side != now.side { moves.append(.flipped(now)) }
            } else {
                moves.append(.opened(now))
            }
        }
        for symbol in before.keys.sorted() where after[symbol] == nil {
            if let was = before[symbol] { moves.append(.closed(was)) }
        }
        return moves
    }

    /// The side a copy takes: theirs, or the opposite when fading.
    public static func side(for position: ObservedPosition, rules: CopyRules) -> Side {
        switch rules.direction {
        case .follow: position.side
        case .fade: position.side == .long ? .short : .long
        }
    }

    /// The leverage a copy is sent at: the trader's, rounded, within both caps.
    public static func leverage(for position: ObservedPosition, rules: CopyRules, market: Market) -> Int {
        let theirs = Int((position.leverage ?? 1).rounded())
        return max(1, min(theirs, rules.maxLeverage, market.config.maxLeverage))
    }

    /// Margin scaled by conviction: a trade holding a tenth of the trader's account is a
    /// normal trade; half their account doubles the copy, a sliver halves it.
    public static func conviction(collateral: Double, portfolio: Double?) -> Double {
        guard let portfolio, portfolio > 0, collateral > 0 else { return 1 }
        return min(2, max(0.5, (collateral / portfolio) / 0.10))
    }

    /// The order for copying `position`, or the reason it is not copied.
    public static func plan(
        copying position: ObservedPosition,
        traderPortfolio: Double? = nil,
        rules: CopyRules,
        guards: CopyGuards,
        market: Market,
        mark: Price,
        free: Money?,
        openCopies: [CopyExposure],
        realisedToday: Money
    ) -> Result<CopyPlan, CopySkip> {
        guard market.config.isOpen else { return .failure(.marketClosed) }
        guard openCopies.count < guards.maxOpenCopies else { return .failure(.openCopiesLimit(guards.maxOpenCopies)) }
        if realisedToday.raw < 0, -realisedToday.raw >= Int64(guards.dailyLossLimit) * 1_000_000 {
            return .failure(.dailyLossLimit(guards.dailyLossLimit))
        }

        let side = side(for: position, rules: rules)
        let symbol = position.symbol
        let sameMarket = openCopies.filter { $0.symbol == symbol }
        guard !sameMarket.contains(where: { $0.side != side }) else { return .failure(.offsetsOpenCopy) }

        let markValue = Double(mark.raw) / pow(10, Double(mark.decimals))
        let chase = chaseBps(entry: position.entry, mark: markValue, side: side)
        if chase > rules.maxChaseBps { return .failure(.chased(bps: chase)) }

        let lev = leverage(for: position, rules: rules, market: market)
        var margin = Double(rules.marginPerTrade)
        if rules.sizing == .conviction {
            margin *= conviction(collateral: position.collateral, portfolio: traderPortfolio)
        }
        let room = Double(guards.maxMarketExposure) - sameMarket.reduce(0) { $0 + $1.notional }
        if margin * Double(lev) > room {
            margin = room / Double(lev)
            if margin < 1 { return .failure(.exposureLimit(guards.maxMarketExposure)) }
        }
        margin = (margin * 100).rounded(.down) / 100
        let marginRaw = Int64((margin * 1_000_000).rounded(.down))
        guard marginRaw > 0 else { return .failure(.tooSmall) }
        guard let free, free.raw >= marginRaw else { return .failure(.insufficientBalance) }

        // size = margin × leverage ÷ price, at the market's size scale, never rounded up.
        let sizeScale = Int128(10).power(Int(market.config.sizeDecimals) + Int(mark.decimals))
        let raw = Int128(marginRaw) * Int128(lev) * sizeScale / (Int128(mark.raw) * 1_000_000)
        guard raw > 0, let fitted = Int64(exactly: raw), let size = market.size(fitted) else {
            return .failure(.tooSmall)
        }

        // The venue bounds a market order's slippage against the mark. What is left of the
        // chase allowance becomes that bound, so no fill lands further from their entry.
        let slippage = max(5, min(rules.maxChaseBps - max(0, chase), 50, market.maxMarketSlippageBps))
        let protection = OrderDesk.Draft.Protection(
            stopLoss: rules.stopLossPercent.flatMap { trigger(mark: mark, side: side, percent: -$0, leverage: lev) },
            takeProfit: rules.takeProfitPercent.flatMap { trigger(mark: mark, side: side, percent: $0, leverage: lev) })
        let draft = OrderDesk.Draft(
            side: side,
            size: size,
            leverageHundredths: lev * 100,
            slippageBps: slippage,
            protection: protection.stopLoss == nil && protection.takeProfit == nil ? nil : protection)
        return .success(CopyPlan(side: side, leverage: lev, margin: margin, draft: draft))
    }

    /// How far the market has moved against `side` since `entry`, in basis points.
    /// Negative when it has moved in the copy's favour.
    /// Figures arrive from a server and a chain, so this cannot assume they are sane. A
    /// denormal entry price makes the ratio exceed every integer type, and converting that
    /// with `Int(_:)` traps — a crash on data the app does not control.
    public static func chaseBps(entry: Double, mark: Double, side: Side) -> Int {
        guard entry > 0, entry.isFinite, mark.isFinite else { return 0 }
        let run = (mark - entry) / entry * 10_000
        return clampedInt((side == .long ? run : -run).rounded())
    }

    /// The nearest `Int`, or the nearest bound. Never traps, never returns a wrong sign.
    public static func clampedInt(_ value: Double) -> Int {
        guard !value.isNaN else { return 0 }
        return Int(exactly: value.rounded()) ?? (value < 0 ? Int.min : Int.max)
    }

    /// The price at which the position has gained (positive) or lost (negative) `percent`
    /// of its margin. At 5× a 25% loss of margin is a 5% move against the side.
    public static func trigger(mark: Price, side: Side, percent: Int, leverage: Int) -> Price? {
        guard leverage > 0, percent != 0 else { return nil }
        let denominator = Int128(100 * leverage)
        let direction = side == .long ? Int128(percent) : -Int128(percent)
        let numerator = Int128(mark.raw) * (denominator + direction)
        guard numerator > 0 else { return nil }
        // A long's stop and a short's take-profit sit below the mark: rounded down, they
        // never trigger earlier than asked. The other two round up for the same reason.
        let below = direction < 0
        let quotient = numerator / denominator
        let raw = below || numerator % denominator == 0 ? quotient : quotient + 1
        return Int64(exactly: raw).flatMap { Price(raw: $0, decimals: mark.decimals) }
    }
}

/// A copy simulated rather than sent: the fill, the fees and the exits a live copy would
/// have had, priced from the mainnet mark.
public struct ShadowFill: Sendable, Hashable, Codable {
    public let entry: Double
    public let units: Double
    public let margin: Double
    public let leverage: Int
    public let isLong: Bool
    public let stop: Double?
    public let take: Double?
    public let fees: Double

    /// Slippage assumed on a simulated market fill, in basis points against the copy.
    public static let slippageBps = 3.0

    public init(entry: Double, units: Double, margin: Double, leverage: Int, isLong: Bool,
                stop: Double?, take: Double?, fees: Double) {
        self.entry = entry
        self.units = units
        self.margin = margin
        self.leverage = leverage
        self.isLong = isLong
        self.stop = stop
        self.take = take
        self.fees = fees
    }

    public init(mark: Double, plan: CopyPlan, takerFeeMicros: Int64, rules: CopyRules) {
        let isLong = plan.side == .long
        let entry = mark * (1 + (isLong ? 1 : -1) * Self.slippageBps / 10_000)
        let notional = plan.margin * Double(plan.leverage)
        self.entry = entry
        self.units = notional / entry
        self.margin = plan.margin
        self.leverage = plan.leverage
        self.isLong = isLong
        let move = { (percent: Int) in Double(percent) / 100 / Double(plan.leverage) }
        self.stop = rules.stopLossPercent.map { entry * (1 + (isLong ? -1 : 1) * move($0)) }
        self.take = rules.takeProfitPercent.map { entry * (1 + (isLong ? 1 : -1) * move($0)) }
        self.fees = notional * Double(takerFeeMicros) / 1_000_000
    }

    /// Profit at `mark` if closed there, after both sides' fees.
    public func pnl(at mark: Double, takerFeeMicros: Int64) -> Double {
        let exit = mark * (1 + (isLong ? -1 : 1) * Self.slippageBps / 10_000)
        let gross = (exit - entry) * units * (isLong ? 1 : -1)
        let exitFee = exit * units * Double(takerFeeMicros) / 1_000_000
        return max(gross - fees - exitFee, -margin)
    }

    /// The trigger a live copy's venue order would have fired at this mark, if any.
    public func trigger(at mark: Double) -> Double? {
        if let stop, isLong ? mark <= stop : mark >= stop { return stop }
        if let take, isLong ? mark >= take : mark <= take { return take }
        return nil
    }
}

private extension Int128 {
    func power(_ exponent: Int) -> Int128 {
        (0..<Swift.max(0, exponent)).reduce(Int128(1)) { value, _ in value * self }
    }
}
