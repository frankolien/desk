import DeskMoney
import Foundation

/// One open position, reduced to what risk is computed from.
///
/// Figures are in collateral units rather than raw integers: this is the one place where
/// positions from different markets, at different price and size decimals, are added
/// together, and adding raw integers from two scales is how that goes wrong.
public struct RiskPosition: Sendable, Hashable, Identifiable {
    public enum Source: Sendable, Hashable {
        case yours
        /// Opened by auto-copy, naming whom it followed.
        case copy(trader: String)

        public var isCopy: Bool { if case .copy = self { true } else { false } }
        public var trader: String? { if case .copy(let trader) = self { trader } else { nil } }
    }

    public let id: String
    public let symbol: String
    public let side: Side
    /// Position value at the mark.
    public let notional: Double
    /// Collateral committed to this position, which is also the most it can lose.
    public let margin: Double
    public let mark: Double
    public let liquidation: Double?
    public let unrealised: Double
    public let source: Source

    public init(id: String, symbol: String, side: Side, notional: Double, margin: Double,
                mark: Double, liquidation: Double?, unrealised: Double, source: Source) {
        self.id = id
        self.symbol = symbol
        self.side = side
        self.notional = notional
        self.margin = margin
        self.mark = mark
        self.liquidation = liquidation
        self.unrealised = unrealised
        self.source = source
    }

    public var isLong: Bool { side == .long }
    /// Signed by side, so a long and a short of the same size cancel.
    public var signedNotional: Double { isLong ? notional : -notional }

    /// How far the mark may move from here before this position is liquidated, as a
    /// fraction. Nil when the venue gives no liquidation price, zero when it is already
    /// past it.
    public var roomToLiquidation: Double? {
        guard let liquidation, mark > 0 else { return nil }
        let past = isLong ? mark <= liquidation : mark >= liquidation
        return past ? 0 : abs(mark - liquidation) / mark
    }
}

/// What one market holds, netted.
public struct MarketExposure: Sendable, Hashable, Identifiable {
    public let symbol: String
    public let longNotional: Double
    public let shortNotional: Double
    public let margin: Double

    public var id: String { symbol }
    public var gross: Double { longNotional + shortNotional }
    public var net: Double { longNotional - shortNotional }
    public var isNetLong: Bool { net >= 0 }
    /// True when both sides are held here, so the gross overstates what is actually at risk.
    public var isHedged: Bool { longNotional > 0 && shortNotional > 0 }
}

/// What a move of the whole market would do to this book.
public struct StressResult: Sendable, Hashable {
    /// The move applied to every mark, as a fraction. Negative is a fall.
    public let move: Double
    /// Profit or loss across the book, with each position's loss capped at its margin.
    public let pnl: Double
    /// Equity after the move.
    public let equity: Double
    /// Positions whose liquidation price the move reaches.
    public let liquidated: [RiskPosition]

    public var liquidates: Bool { !liquidated.isEmpty }
}

/// The whole book in one place: what it is exposed to, where that exposure came from, and
/// what a move against it would cost.
///
/// Every figure here is derived from positions the venue reports and the marks the app
/// already has. Nothing is predicted and no correlation is modelled: the stress test moves
/// every market by the same amount, which is the honest assumption on a day when
/// everything falls together, and is stated that way on screen.
public struct RiskBook: Sendable {
    public let positions: [RiskPosition]
    /// Collateral not committed to any position.
    public let free: Double

    public init(positions: [RiskPosition], free: Double) {
        self.positions = positions
        self.free = free
    }

    public var isEmpty: Bool { positions.isEmpty }

    public var margin: Double { positions.reduce(0) { $0 + $1.margin } }
    public var unrealised: Double { positions.reduce(0) { $0 + $1.unrealised } }
    /// Free collateral, plus what is committed, plus what the book is up or down.
    public var equity: Double { free + margin + unrealised }

    public var grossNotional: Double { positions.reduce(0) { $0 + $1.notional } }
    public var netNotional: Double { positions.reduce(0) { $0 + $1.signedNotional } }
    public var longNotional: Double { positions.filter(\.isLong).reduce(0) { $0 + $1.notional } }
    public var shortNotional: Double { positions.filter { !$0.isLong }.reduce(0) { $0 + $1.notional } }

    /// Gross exposure against equity. Two times means a 10% move is a 20% swing in the
    /// account.
    public var accountLeverage: Double? {
        guard equity > 0, grossNotional > 0 else { return nil }
        return grossNotional / equity
    }

    /// Markets held, largest first.
    public var exposures: [MarketExposure] {
        Dictionary(grouping: positions, by: \.symbol)
            .map { symbol, held in
                MarketExposure(
                    symbol: symbol,
                    longNotional: held.filter(\.isLong).reduce(0) { $0 + $1.notional },
                    shortNotional: held.filter { !$0.isLong }.reduce(0) { $0 + $1.notional },
                    margin: held.reduce(0) { $0 + $1.margin })
            }
            .sorted { $0.gross > $1.gross }
    }

    /// The share of gross exposure sitting in the single largest market.
    public var concentration: Double? {
        guard grossNotional > 0, let largest = exposures.first else { return nil }
        return largest.gross / grossNotional
    }

    /// The share of gross exposure auto-copy opened.
    public var copyShare: Double? {
        guard grossNotional > 0 else { return nil }
        return positions.filter { $0.source.isCopy }.reduce(0) { $0 + $1.notional } / grossNotional
    }

    /// The trader whose copies carry the most exposure, and how much.
    public var heaviestTrader: (trader: String, notional: Double)? {
        let byTrader = Dictionary(grouping: positions.compactMap { position in
            position.source.trader.map { (trader: $0, notional: position.notional) }
        }, by: \.trader)
        return byTrader
            .map { (trader: $0.key, notional: $0.value.reduce(0) { $0 + $1.notional }) }
            .max { $0.notional < $1.notional }
    }

    /// The position closest to liquidation, which is the one that decides how much room
    /// the account really has.
    public var tightest: RiskPosition? {
        positions
            .filter { $0.roomToLiquidation != nil }
            .min { ($0.roomToLiquidation ?? 1) < ($1.roomToLiquidation ?? 1) }
    }

    /// A move of every market at once, applied to this book.
    ///
    /// A position cannot lose more than the collateral behind it, because the venue closes
    /// it first; that cap is what makes this different from multiplying notional by the
    /// move and calling it a loss.
    public func stress(move: Double) -> StressResult {
        var pnl = 0.0
        var liquidated: [RiskPosition] = []
        for position in positions {
            let direction = position.isLong ? 1.0 : -1.0
            let uncapped = position.notional * move * direction
            let reached = position.liquidation.map { liquidation -> Bool in
                let after = position.mark * (1 + move)
                return position.isLong ? after <= liquidation : after >= liquidation
            } ?? (uncapped <= -position.margin)
            if reached {
                liquidated.append(position)
                pnl -= position.margin
            } else {
                pnl += max(uncapped, -position.margin)
            }
        }
        return StressResult(move: move, pnl: pnl, equity: equity + pnl, liquidated: liquidated)
    }

    /// The largest fall this book survives with nothing liquidated, searched in tenths of
    /// a percent down to the given floor.
    public func survivableFall(floor: Double = -0.5) -> Double? {
        guard !positions.isEmpty else { return nil }
        var move = 0.0
        while move > floor {
            if stress(move: move - 0.001).liquidates { return -move }
            move -= 0.001
        }
        return -floor
    }
}
