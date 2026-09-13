import DeskMoney
import Foundation

public enum OrderType: Int, Sendable, Hashable {
    case openLong = 1
    case openShort = 2
    case closeLong = 3
    case closeShort = 4
    case cancel = 5
    case increasePositionCollateral = 6
    case change = 7
}

/// Good-till-cancelled is the absence of a flag, not a value.
public struct OrderFlags: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let goodTillCancelled = OrderFlags([])
    public static let postOnly = OrderFlags(rawValue: 1)
    public static let fillOrKill = OrderFlags(rawValue: 2)
    public static let immediateOrCancel = OrderFlags(rawValue: 4)
}

/// Message type 22.
///
/// There is no market order type and no reduce-only flag; everything composes from the
/// type, the flags and the price. A market order is a marketable limit at price zero
/// with immediate-or-cancel and a slippage bound.
public struct OrderRequest: Encodable, Sendable, Hashable {
    public let messageType = 22
    public let frameID: Int64
    public let requestID: Int64
    public let market: UInt32
    public let account: UInt32
    public let type: OrderType
    public let priceRaw: Int64
    public let sizeRaw: Int64
    public let flags: OrderFlags
    public let leverageHundredths: Int
    public let lastBlock: Int64
    public let maxSlippageBps: Int?
    public let orderID: Int64?

    enum CodingKeys: String, CodingKey {
        case messageType = "mt"
        case frameID = "sn"
        case requestID = "rq"
        case market = "mkt"
        case account = "acc"
        case type = "t"
        case priceRaw = "p"
        case sizeRaw = "s"
        case flags = "fl"
        case leverageHundredths = "lv"
        case lastBlock = "lb"
        case maxSlippageBps = "ms"
        case orderID = "oid"
    }

    public func encode(to encoder: any Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(messageType, forKey: .messageType)
        try box.encode(frameID, forKey: .frameID)
        try box.encode(requestID, forKey: .requestID)
        try box.encode(market, forKey: .market)
        try box.encode(account, forKey: .account)
        try box.encode(type.rawValue, forKey: .type)
        try box.encode(priceRaw, forKey: .priceRaw)
        try box.encode(sizeRaw, forKey: .sizeRaw)
        try box.encode(flags.rawValue, forKey: .flags)
        try box.encode(leverageHundredths, forKey: .leverageHundredths)
        try box.encode(lastBlock, forKey: .lastBlock)
        try box.encodeIfPresent(maxSlippageBps, forKey: .maxSlippageBps)
        try box.encodeIfPresent(orderID, forKey: .orderID)
    }
}

public enum OrderBuilder {
    public enum Failure: Error, Equatable, Sendable {
        case frameIDMustBeNonZero
        case sizeMustBePositive
        case leverageOutOfRange(Int, max: Int)
        case slippageOutOfRange(Int, max: Int)
        case priceScaleMismatch
        case sizeScaleMismatch
        case priceMustBePositive
        case deadlineOverflow(headBlock: Int64, ttl: UInt32)
    }

    /// `lb` is a block number, and `headBlock` arrives from the server. Swift traps on
    /// overflow rather than wrapping, and a trap is a dead app rather than a rejected
    /// order.
    static func deadline(headBlock: Int64, ttl: UInt32) throws -> Int64 {
        let (sum, overflowed) = headBlock.addingReportingOverflow(Int64(ttl))
        guard !overflowed else { throw Failure.deadlineOverflow(headBlock: headBlock, ttl: ttl) }
        return sum
    }

    /// A market order: price zero, immediate-or-cancel, bounded by slippage.
    public static func market(
        side: Side,
        market config: Market,
        account: UInt32,
        size: Size,
        leverageHundredths: Int,
        slippageBps: Int,
        headBlock: Int64,
        requestID: Int64,
        frameID: Int64
    ) throws -> OrderRequest {
        try validate(size: size, market: config, leverageHundredths: leverageHundredths, frameID: frameID)
        guard slippageBps > 0, slippageBps <= config.maxMarketSlippageBps else {
            throw Failure.slippageOutOfRange(slippageBps, max: config.maxMarketSlippageBps)
        }
        return OrderRequest(
            frameID: frameID,
            requestID: requestID,
            market: config.id,
            account: account,
            type: side == .long ? .openLong : .openShort,
            priceRaw: 0,
            sizeRaw: size.raw,
            flags: .immediateOrCancel,
            leverageHundredths: leverageHundredths,
            lastBlock: try deadline(headBlock: headBlock, ttl: config.orderTTLBlocks),
            maxSlippageBps: slippageBps,
            orderID: nil)
    }

    public static func limit(
        side: Side,
        market config: Market,
        account: UInt32,
        price: Price,
        size: Size,
        leverageHundredths: Int,
        postOnly: Bool = false,
        headBlock: Int64,
        requestID: Int64,
        frameID: Int64
    ) throws -> OrderRequest {
        try validate(size: size, market: config, leverageHundredths: leverageHundredths, frameID: frameID)
        guard price.decimals == config.config.priceDecimals else { throw Failure.priceScaleMismatch }
        // Price zero is how this venue spells "marketable". A limit order carrying it is
        // a market order with good-till-cancelled and no slippage bound at all — the
        // exact construction `market` exists to prevent.
        guard price.raw > 0 else { throw Failure.priceMustBePositive }
        return OrderRequest(
            frameID: frameID,
            requestID: requestID,
            market: config.id,
            account: account,
            type: side == .long ? .openLong : .openShort,
            priceRaw: price.raw,
            sizeRaw: size.raw,
            flags: postOnly ? .postOnly : .goodTillCancelled,
            leverageHundredths: leverageHundredths,
            lastBlock: try deadline(headBlock: headBlock, ttl: config.orderTTLBlocks),
            maxSlippageBps: nil,
            orderID: nil)
    }

    /// Closing uses its own types, never an opposing open.
    ///
    /// An opposing open inverts the position and pays taker on the way; the close types
    /// are free and are exempt from the initial-margin check, which is what lets an
    /// underwater position always be closed.
    public static func close(
        side: Side,
        market config: Market,
        account: UInt32,
        size: Size,
        slippageBps: Int,
        headBlock: Int64,
        requestID: Int64,
        frameID: Int64
    ) throws -> OrderRequest {
        guard frameID != 0 else { throw Failure.frameIDMustBeNonZero }
        guard size.raw > 0 else { throw Failure.sizeMustBePositive }
        // Without this a size at the wrong scale closes a hundredth of what was asked
        // for and leaves the position open, with nothing on screen to say so.
        guard size.decimals == config.config.sizeDecimals else { throw Failure.sizeScaleMismatch }
        guard slippageBps > 0, slippageBps <= config.maxMarketSlippageBps else {
            throw Failure.slippageOutOfRange(slippageBps, max: config.maxMarketSlippageBps)
        }
        return OrderRequest(
            frameID: frameID,
            requestID: requestID,
            market: config.id,
            account: account,
            type: side == .long ? .closeLong : .closeShort,
            priceRaw: 0,
            sizeRaw: size.raw,
            flags: .immediateOrCancel,
            leverageHundredths: 100,
            lastBlock: try deadline(headBlock: headBlock, ttl: config.orderTTLBlocks),
            maxSlippageBps: slippageBps,
            orderID: nil)
    }

    /// Cancel is message 22 with type 5, not a message of its own.
    public static func cancel(
        market config: Market,
        account: UInt32,
        orderID: Int64,
        headBlock: Int64,
        requestID: Int64,
        frameID: Int64
    ) throws -> OrderRequest {
        guard frameID != 0 else { throw Failure.frameIDMustBeNonZero }
        return OrderRequest(
            frameID: frameID,
            requestID: requestID,
            market: config.id,
            account: account,
            type: .cancel,
            priceRaw: 0,
            sizeRaw: 0,
            flags: .goodTillCancelled,
            leverageHundredths: 100,
            lastBlock: try deadline(headBlock: headBlock, ttl: config.orderTTLBlocks),
            maxSlippageBps: nil,
            orderID: orderID)
    }

    private static func validate(
        size: Size, market config: Market, leverageHundredths: Int, frameID: Int64
    ) throws {
        // A zero frame id is omitted from the status response, so the order cannot be
        // correlated with its outcome.
        guard frameID != 0 else { throw Failure.frameIDMustBeNonZero }
        guard size.raw > 0 else { throw Failure.sizeMustBePositive }
        guard size.decimals == config.config.sizeDecimals else { throw Failure.sizeScaleMismatch }
        // Against the fraction itself, not `maxLeverage * 100`: that round trip through
        // integer division turns a 12.5x market into a 12x one and refuses leverage the
        // venue allows.
        let maximum = config.config.initialMarginFraction
        guard leverageHundredths >= 100, leverageHundredths <= maximum else {
            throw Failure.leverageOutOfRange(leverageHundredths, max: maximum)
        }
    }
}

/// `rq` must strictly increase per account, seeded from the account's last-forwarded
/// value on every connect. A value at or below it rejects with `sr: 32`.
public actor RequestCounter {
    private var next: Int64

    public init(lastForwarded: Int64) { next = Self.after(lastForwarded) }

    public func take() -> Int64 {
        defer { next = Self.after(next) }
        return next
    }

    public func reseed(lastForwarded: Int64) {
        next = max(next, Self.after(lastForwarded))
    }

    /// Saturates. The seed arrives from the wallet snapshot on every connect, so a
    /// maximal value is a server's to send and `+ 1` on it kills the app.
    private static func after(_ value: Int64) -> Int64 {
        value == .max ? .max : value + 1
    }
}
