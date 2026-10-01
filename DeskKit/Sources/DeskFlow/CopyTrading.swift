import DeskMoney
import DeskPerpl
import Foundation

public enum CopyMode: String, Codable, Sendable, Hashable, CaseIterable { case shadow, live }

public enum CopyDirection: String, Codable, Sendable, Hashable, CaseIterable { case follow, fade }

public enum CopySizing: String, Codable, Sendable, Hashable, CaseIterable { case fixed, conviction }

public struct CopyRules: Codable, Sendable, Hashable {
    public var mode: CopyMode
    public var direction: CopyDirection
    public var sizing: CopySizing
    public var marginPerTrade: Int
    public var maxLeverage: Int
    public var stopLossPercent: Int?
    public var takeProfitPercent: Int?
    public var closeWithTrader: Bool
    /// Chase allowance in basis points since the trader's entry; also the price bound the
    /// order is sent with, so a fill never lands further from their entry than this.
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

public struct CopyGuards: Codable, Sendable, Hashable {
    public var maxOpenCopies: Int
    public var dailyLossLimit: Int
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
    case flipped(ObservedPosition)
    case closed(ObservedPosition)
}

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
    case offsetsOpenCopy
    case exposureLimit(Int)
}

public struct CopyPlan: Sendable, Hashable {
    public let side: Side
    public let leverage: Int
    public let margin: Double
    public let draft: OrderDesk.Draft
    public var liquidationPrice: Price? = nil

    public var notional: Double { margin * Double(leverage) }
}

public enum CopyPlanner {
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

    public static func side(for position: ObservedPosition, rules: CopyRules) -> Side {
        switch rules.direction {
        case .follow: position.side
        case .fade: position.side == .long ? .short : .long
        }
    }

    public static func leverage(for position: ObservedPosition, rules: CopyRules, market: Market) -> Int {
        let theirs = Int((position.leverage ?? 1).rounded())
        return max(1, min(theirs, rules.maxLeverage, market.config.maxLeverage))
    }

    public static func conviction(collateral: Double, portfolio: Double?) -> Double {
        guard let portfolio, portfolio > 0, collateral > 0 else { return 1 }
        return min(2, max(0.5, (collateral / portfolio) / 0.10))
    }

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

        // Against the trader's own venue: on testnet `mark` is a different market from the one
        // they entered on, so comparing the two would measure the gap between venues.
        let chase = chaseBps(entry: position.entry, mark: position.mark, side: side)
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
        // What leaves the balance is margin plus the venue's fee on the notional.
        let notionalRaw = Int128(marginRaw) * Int128(lev)
        let feeRaw = Int64(clamping: (notionalRaw * Int128(market.config.takerFeeMicros) + 999_999) / 1_000_000)
        guard let free, free.raw >= marginRaw + feeRaw else { return .failure(.insufficientBalance) }

        // size = margin × leverage ÷ price, at the market's size scale, never rounded up.
        let sizeScale = Int128(10).power(Int(market.config.sizeDecimals) + Int(mark.decimals))
        let raw = Int128(marginRaw) * Int128(lev) * sizeScale / (Int128(mark.raw) * 1_000_000)
        guard raw > 0, let fitted = Int64(exactly: raw), let size = market.size(fitted) else {
            return .failure(.tooSmall)
        }

        guard let quote = try? OrderQuote.quote(
            side: side, size: size, price: mark, leverageHundredths: lev * 100,
            feeMicros: market.config.takerFeeMicros,
            initialMarginFraction: market.config.initialMarginFraction,
            maintenanceMarginFraction: market.config.maintenanceMarginFraction) else {
            return .failure(.tooSmall)
        }
        guard free.raw >= quote.total.raw else { return .failure(.insufficientBalance) }

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
        return .success(CopyPlan(side: side, leverage: lev, margin: margin, draft: draft, liquidationPrice: quote.liquidationPrice))
    }

    /// Basis points moved against `side` since `entry`, negative when in the copy's favour.
    /// Clamps rather than traps: a denormal entry from the server overflows every integer type.
    public static func chaseBps(entry: Double, mark: Double, side: Side) -> Int {
        guard entry > 0, entry.isFinite, mark.isFinite else { return 0 }
        let run = (mark - entry) / entry * 10_000
        return clampedInt((side == .long ? run : -run).rounded())
    }

    public static func clampedInt(_ value: Double) -> Int {
        guard !value.isNaN else { return 0 }
        return Int(exactly: value.rounded()) ?? (value < 0 ? Int.min : Int.max)
    }

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

public enum ShadowExit: String, Sendable, Hashable, Codable {
    case stop, take, liquidation
}

public struct ShadowFill: Sendable, Hashable, Codable {
    public let entry: Double
    public let units: Double
    public let margin: Double
    public let leverage: Int
    public let isLong: Bool
    public let stop: Double?
    public let take: Double?
    public let fees: Double
    /// Without a liquidation price a simulation floors at the margin and then recovers,
    /// a profit the real position could never have made.
    public var liquidation: Double?

    public static let slippageBps = 3.0

    public init(entry: Double, units: Double, margin: Double, leverage: Int, isLong: Bool,
                stop: Double?, take: Double?, fees: Double, liquidation: Double? = nil) {
        self.liquidation = liquidation
        self.entry = entry
        self.units = units
        self.margin = margin
        self.leverage = leverage
        self.isLong = isLong
        self.stop = stop
        self.take = take
        self.fees = fees
    }

    public init(mark: Double, plan: CopyPlan, takerFeeMicros: Int64, maintenanceMarginFraction: Int,
                rules: CopyRules) {
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
        self.liquidation = Margin
            .liquidationDistanceMicros(leverageHundredths: plan.leverage * 100,
                                       maintenanceMarginFraction: maintenanceMarginFraction)
            .map { entry * (1 + (isLong ? -1 : 1) * Double($0) / 1_000_000) }
    }

    /// Both fees are charged: since contract 1.7.5 Perpl takes the taker rate on closes too.
    public func pnl(at mark: Double, takerFeeMicros: Int64) -> Double {
        if let liquidation, isLong ? mark <= liquidation : mark >= liquidation { return -margin }
        let exit = mark * (1 + (isLong ? -1 : 1) * Self.slippageBps / 10_000)
        let gross = (exit - entry) * units * (isLong ? 1 : -1)
        let exitFee = exit * units * Double(takerFeeMicros) / 1_000_000
        return max(gross - fees - exitFee, -margin)
    }

    /// Liquidation is tested first. A stop fills at the mark that broke it, since a gap costs
    /// the difference; a take-profit keeps its own price, the conservative reading of an overshoot.
    public func triggered(at mark: Double) -> (exit: ShadowExit, price: Double)? {
        if let liquidation, isLong ? mark <= liquidation : mark >= liquidation {
            return (.liquidation, liquidation)
        }
        if let stop, isLong ? mark <= stop : mark >= stop {
            return (.stop, isLong ? min(mark, stop) : max(mark, stop))
        }
        if let take, isLong ? mark >= take : mark <= take { return (.take, take) }
        return nil
    }
}

private extension Int128 {
    func power(_ exponent: Int) -> Int128 {
        (0..<Swift.max(0, exponent)).reduce(Int128(1)) { value, _ in value * self }
    }
}
