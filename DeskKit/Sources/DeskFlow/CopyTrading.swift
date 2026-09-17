import DeskMoney
import DeskPerpl
import Foundation

/// How one followed trader is copied. Every limit is the copier's, not the trader's: their
/// size is sized to their account, so only their market, side and leverage carry over.
public struct CopyRules: Codable, Sendable, Hashable {
    /// Collateral committed to each copied trade, in whole AUSD.
    public var marginPerTrade: Int
    /// The trader's leverage is followed up to this and never past it.
    public var maxLeverage: Int
    /// Loss on the trade's margin, in percent, at which Perpl closes it. Sent as a trigger
    /// order the venue holds, so it protects the position even while Desk is closed.
    public var stopLossPercent: Int?
    public var takeProfitPercent: Int?
    /// Close the copy when the trader closes.
    public var closeWithTrader: Bool
    /// How far the market may have run past the trader's entry before a copy is skipped,
    /// in basis points. Chasing a move that already happened is how copiers buy tops.
    public var maxChaseBps: Int

    public init(
        marginPerTrade: Int = 10, maxLeverage: Int = 5, stopLossPercent: Int? = 25,
        takeProfitPercent: Int? = nil, closeWithTrader: Bool = true, maxChaseBps: Int = 100
    ) {
        self.marginPerTrade = marginPerTrade
        self.maxLeverage = maxLeverage
        self.stopLossPercent = stopLossPercent
        self.takeProfitPercent = takeProfitPercent
        self.closeWithTrader = closeWithTrader
        self.maxChaseBps = maxChaseBps
    }
}

/// Limits across every trader being copied.
public struct CopyGuards: Codable, Sendable, Hashable {
    public var maxOpenCopies: Int
    /// Realised copy losses today, in whole AUSD, after which copying pauses itself.
    public var dailyLossLimit: Int

    public init(maxOpenCopies: Int = 3, dailyLossLimit: Int = 50) {
        self.maxOpenCopies = maxOpenCopies
        self.dailyLossLimit = dailyLossLimit
    }
}

/// A followed trader's position as read from mainnet, by market symbol.
public struct ObservedPosition: Sendable, Hashable {
    public let symbol: String
    public let side: Side
    public let size: Double
    public let entry: Double
    public let leverage: Double?

    public init(symbol: String, side: Side, size: Double, entry: Double, leverage: Double?) {
        self.symbol = symbol.uppercased()
        self.side = side
        self.size = size
        self.entry = entry
        self.leverage = leverage
    }
}

public enum TraderMove: Sendable, Hashable {
    case opened(ObservedPosition)
    /// Closed one side and opened the other in the same market between two readings.
    case flipped(ObservedPosition)
    case closed(ObservedPosition)
}

public enum CopySkip: Error, Sendable, Hashable {
    case marketNotListed
    case marketClosed
    case openCopiesLimit(Int)
    case dailyLossLimit(Int)
    case insufficientBalance
    case chased(bps: Int)
    case tooSmall
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

    /// The leverage a copy is sent at: the trader's, rounded, within both caps.
    public static func leverage(for position: ObservedPosition, rules: CopyRules, market: Market) -> Int {
        let theirs = Int((position.leverage ?? 1).rounded())
        return max(1, min(theirs, rules.maxLeverage, market.config.maxLeverage))
    }

    /// The order for copying `position`, or the reason it is not copied.
    public static func draft(
        copying position: ObservedPosition,
        rules: CopyRules,
        guards: CopyGuards,
        market: Market,
        mark: Price,
        free: Money?,
        openCopies: Int,
        realisedToday: Money
    ) -> Result<OrderDesk.Draft, CopySkip> {
        guard market.config.isOpen else { return .failure(.marketClosed) }
        guard openCopies < guards.maxOpenCopies else { return .failure(.openCopiesLimit(guards.maxOpenCopies)) }
        if realisedToday.raw < 0, -realisedToday.raw >= Int64(guards.dailyLossLimit) * 1_000_000 {
            return .failure(.dailyLossLimit(guards.dailyLossLimit))
        }
        let marginRaw = Int64(rules.marginPerTrade) * 1_000_000
        guard marginRaw > 0 else { return .failure(.tooSmall) }
        guard let free, free.raw >= marginRaw else { return .failure(.insufficientBalance) }

        let scale = pow(10, Double(mark.decimals))
        let markValue = Double(mark.raw) / scale
        if position.entry > 0 {
            let run = (markValue - position.entry) / position.entry * 10_000
            let against = position.side == .long ? run : -run
            if Int(against.rounded()) > rules.maxChaseBps { return .failure(.chased(bps: Int(against.rounded()))) }
        }

        let lev = leverage(for: position, rules: rules, market: market)
        // size = margin × leverage ÷ price, at the market's size scale, never rounded up.
        let sizeScale = Int128(10).power(Int(market.config.sizeDecimals) + Int(mark.decimals))
        let raw = Int128(marginRaw) * Int128(lev) * sizeScale / (Int128(mark.raw) * 1_000_000)
        guard raw > 0, let fitted = Int64(exactly: raw), let size = market.size(fitted) else {
            return .failure(.tooSmall)
        }

        let protection = OrderDesk.Draft.Protection(
            stopLoss: rules.stopLossPercent.flatMap { trigger(mark: mark, side: position.side, percent: -$0, leverage: lev) },
            takeProfit: rules.takeProfitPercent.flatMap { trigger(mark: mark, side: position.side, percent: $0, leverage: lev) })
        return .success(OrderDesk.Draft(
            side: position.side,
            size: size,
            leverageHundredths: lev * 100,
            slippageBps: min(50, market.maxMarketSlippageBps),
            protection: protection.stopLoss == nil && protection.takeProfit == nil ? nil : protection))
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

private extension Int128 {
    func power(_ exponent: Int) -> Int128 {
        (0..<Swift.max(0, exponent)).reduce(Int128(1)) { value, _ in value * self }
    }
}
