import DeskMoney
import Foundation

/// A position, as the venue reports it.
///
/// Message type 26 is the snapshot on sign-in and 27 is every update after; both carry an
/// array of these under `d`, so one type decodes both. Field names are the venue's own
/// two-letter keys, kept verbatim rather than renamed on the wire, because a mapping
/// invented here is a mapping that drifts.
///
/// Scaling is the part worth reading twice. `ep` and `xp` are at the market's
/// `price_decimals`; `s` is at its `size_decimals`; and `c`, `fee`, `dpnl` and `fnd` are
/// **raw integers at the collateral's six decimals**, sent as strings because they
/// outgrow a JSON number. The venue's own documentation calls those "decimal string",
/// which reads as "a number with a point in it" and is not what arrives — `"100000000"`
/// is one hundred AUSD, not one hundred million. Reading it the other way is wrong by a
/// factor of a million, which is the kind of error that shows a liquidated account as
/// solvent.
public struct PerplPosition: Decodable, Sendable, Hashable {
    public let marketID: UInt32
    public let accountID: UInt32
    public let positionID: Int64
    /// 1 long, 2 short.
    public let sideCode: Int
    /// Collateral committed to this position.
    public let collateralRaw: Int64
    /// Entry price, at the market's price decimals.
    public let entryRaw: Int64
    /// A Q16 fractional residue of the entry price: the true entry is
    /// `entryRaw + entryResidue / 65_536`.
    ///
    /// Optional on the wire and easy to ignore, which is why it is named here. Dropping
    /// it biases every PnL figure in the same direction by up to one price tick, and a
    /// bias that always leans the same way is the kind a user eventually notices as the
    /// app being wrong rather than as rounding.
    public let entryResidue: Int?
    /// Size, at the market's size decimals.
    public let sizeRaw: Int64
    public let feeRaw: Int64
    /// Funding accumulator at entry, signed.
    public let entryFundingSum: Int64
    /// Funding accumulator at exit, signed. Meaningless while the position is open.
    public let exitFundingSum: Int64
    /// Leverage in hundredths, the same unit `Margin` takes.
    public let leverageHundredths: Int
    /// Present once the position has been closed.
    public let exitRaw: Int64?
    public let realisedPnLRaw: Int64?
    public let realisedFundingRaw: Int64?
    public let statusCode: Int

    public var side: Side { sideCode == 2 ? .short : .long }

    /// Whether this is a position the user still holds.
    ///
    /// Keyed on the exit price rather than on `st`, because `PositionStatus`'s numeric
    /// values are not published and a guessed enum is a fabrication. An exit price is
    /// only written when a position closes, so its absence is the honest test. Revisit
    /// once a real `mt: 26` frame has been captured from a funded account — this is the
    /// one inference in the file, and it is marked so it does not become folklore.
    public var isOpen: Bool { exitRaw == nil && sizeRaw > 0 }

    enum CodingKeys: String, CodingKey {
        case marketID = "mkt"
        case accountID = "acc"
        case positionID = "pid"
        case sideCode = "sd"
        case collateral = "c"
        case entry = "ep"
        case entryResidue = "epr"
        case size = "s"
        case fee
        case entryFundingSum = "efs"
        case exitFundingSum = "xfs"
        case leverage = "lv"
        case exit = "xp"
        case realisedPnL = "dpnl"
        case realisedFunding = "fnd"
        case status = "st"
    }

    public init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        marketID = try box.decode(UInt32.self, forKey: .marketID)
        accountID = try box.decode(UInt32.self, forKey: .accountID)
        positionID = try box.decodeWireInt(.positionID)
        sideCode = try box.decode(Int.self, forKey: .sideCode)
        collateralRaw = try box.decodeWireInt(.collateral)
        entryRaw = try box.decodeWireInt(.entry)
        entryResidue = try box.decodeIfPresent(Int.self, forKey: .entryResidue)
        sizeRaw = try box.decodeWireInt(.size)
        feeRaw = (try? box.decodeWireInt(.fee)) ?? 0
        entryFundingSum = (try? box.decodeWireInt(.entryFundingSum)) ?? 0
        exitFundingSum = (try? box.decodeWireInt(.exitFundingSum)) ?? 0
        leverageHundredths = try box.decode(Int.self, forKey: .leverage)
        exitRaw = try? box.decodeWireInt(.exit)
        realisedPnLRaw = try? box.decodeWireInt(.realisedPnL)
        realisedFundingRaw = try? box.decodeWireInt(.realisedFunding)
        statusCode = (try? box.decode(Int.self, forKey: .status)) ?? 0
    }
}

/// Message types 26 and 27. The snapshot and the update carry the same array.
public struct PositionsFrame: Decodable, Sendable, Hashable {
    public let positions: [PerplPosition]

    enum CodingKeys: String, CodingKey { case positions = "d" }

    public init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        positions = (try? box.decode([PerplPosition].self, forKey: .positions)) ?? []
    }
}

/// Message type 21: the account, and the only authority on collateral held at the
/// exchange.
///
/// `b` is the balance and `lb` the part of it locked behind open positions, so what is
/// actually free to withdraw or commit is the difference. A screen that renders `b` as
/// "available" overstates it by exactly the margin backing the user's own position.
public struct PerplAccount: Decodable, Sendable, Hashable {
    public let instanceID: UInt32
    public let accountID: UInt32
    public let isFrozen: Bool
    /// Whether the venue will accept orders forwarded on this account's behalf. Without
    /// it every order is refused, which is why the opening sequence sets it.
    public let allowsForwarding: Bool
    public let balanceRaw: Int64
    public let lockedRaw: Int64

    public var balance: Money? { Money(raw: balanceRaw) }
    public var locked: Money? { Money(raw: lockedRaw) }
    public var free: Money? { Money(raw: balanceRaw - lockedRaw) }

    enum CodingKeys: String, CodingKey {
        case instanceID = "in"
        case accountID = "id"
        case isFrozen = "fr"
        case allowsForwarding = "fw"
        case balance = "b"
        case locked = "lb"
    }

    public init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        instanceID = try box.decode(UInt32.self, forKey: .instanceID)
        accountID = try box.decode(UInt32.self, forKey: .accountID)
        isFrozen = (try? box.decode(Bool.self, forKey: .isFrozen)) ?? false
        allowsForwarding = (try? box.decode(Bool.self, forKey: .allowsForwarding)) ?? false
        balanceRaw = try box.decodeWireInt(.balance)
        lockedRaw = (try? box.decodeWireInt(.locked)) ?? 0
    }
}
