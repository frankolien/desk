import DeskMoney
import Foundation

/// `ep`/`xp` are at the market's price decimals, `s` at its size decimals; `c`, `fee`, `dpnl`, `fnd`
/// are raw integer strings at six decimals: `"100000000"` is 100 AUSD, despite the docs' "decimal string".
public struct PerplPosition: Decodable, Sendable, Hashable {
    public let marketID: UInt32
    public let accountID: UInt32
    public let positionID: Int64
    /// 1 long, 2 short.
    public let sideCode: Int
    public let collateralRaw: Int64
    public let entryRaw: Int64
    /// Q16 residue: the true entry is `entryRaw + entryResidue / 65_536`. Dropping it biases every
    /// PnL figure the same way by up to one tick.
    public let entryResidue: Int?
    public let sizeRaw: Int64
    /// Since contract 1.7.5 (23 September 2026): on an open position, the entry-side fee
    /// still carried by the remaining size; on a closed one, every fee it paid.
    public let feeRaw: Int64
    public let closeFeeRaw: Int64?
    public let entryFundingSum: Int64
    public let exitFundingSum: Int64
    /// Leverage in hundredths, the same unit `Margin` takes.
    public let leverageHundredths: Int
    public let exitRaw: Int64?
    public let realisedPnLRaw: Int64?
    public let realisedFundingRaw: Int64?
    public let statusCode: Int
    /// From `at`, the block and time of the row; absent on frames that omit it.
    public let updatedBlock: Int64?
    public let updatedAt: Date?

    public var side: Side { sideCode == 2 ? .short : .long }

    /// Keyed on the exit price, not `st`: `PositionStatus`'s numeric values are unpublished, and an
    /// exit price is only written on close.
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
        case closeFee = "cfee"
        case entryFundingSum = "efs"
        case exitFundingSum = "xfs"
        case leverage = "lv"
        case exit = "xp"
        case realisedPnL = "dpnl"
        case realisedFunding = "fnd"
        case status = "st"
        case stamp = "at"
    }

    private struct Stamp: Decodable {
        let b: Int64?
        let t: Int64?
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
        closeFeeRaw = try? box.decodeWireInt(.closeFee)
        entryFundingSum = (try? box.decodeWireInt(.entryFundingSum)) ?? 0
        exitFundingSum = (try? box.decodeWireInt(.exitFundingSum)) ?? 0
        leverageHundredths = try box.decode(Int.self, forKey: .leverage)
        exitRaw = try? box.decodeWireInt(.exit)
        realisedPnLRaw = try? box.decodeWireInt(.realisedPnL)
        realisedFundingRaw = try? box.decodeWireInt(.realisedFunding)
        statusCode = (try? box.decode(Int.self, forKey: .status)) ?? 0
        let stamp = try? box.decode(Stamp.self, forKey: .stamp)
        updatedBlock = stamp?.b
        updatedAt = stamp?.t.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }
}

/// `GET /v1/trading/position-history`, newest first, paged by the opaque `np` cursor.
public struct PositionHistoryPage: Decodable, Sendable {
    public let positions: [PerplPosition]
    public let nextPage: String?

    enum CodingKeys: String, CodingKey {
        case positions = "d"
        case nextPage = "np"
    }

    public init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        positions = try box.decodeIfPresent([PerplPosition].self, forKey: .positions) ?? []
        nextPage = (try? box.decode(String.self, forKey: .nextPage)).flatMap { $0.isEmpty ? nil : $0 }
    }
}

public struct PositionsFrame: Decodable, Sendable, Hashable {
    public let positions: [PerplPosition]

    enum CodingKeys: String, CodingKey { case positions = "d" }

    public init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        positions = (try? box.decode([PerplPosition].self, forKey: .positions)) ?? []
    }
}

/// Message type 21. `b` is the balance and `lb` the part locked behind open positions; only the
/// difference is free to withdraw or commit.
public struct PerplAccount: Decodable, Sendable, Hashable {
    public let instanceID: UInt32
    public let accountID: UInt32
    public let isFrozen: Bool
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

    public init(
        instanceID: UInt32,
        accountID: UInt32,
        isFrozen: Bool,
        allowsForwarding: Bool,
        balanceRaw: Int64,
        lockedRaw: Int64
    ) {
        self.instanceID = instanceID
        self.accountID = accountID
        self.isFrozen = isFrozen
        self.allowsForwarding = allowsForwarding
        self.balanceRaw = balanceRaw
        self.lockedRaw = lockedRaw
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
