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

public enum TriggerPriceCondition: Int, Sendable, Hashable {
    case greaterThanOrEqualLast = 1
    case lessThanOrEqualLast = 2
    case greaterThanOrEqualMark = 3
    case lessThanOrEqualMark = 4
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
    public let triggerPriceRaw: Int64?
    public let triggerCondition: TriggerPriceCondition?
    public let linkedRequestID: Int64?
    public let linkedPositionID: Int64?

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
        case triggerPriceRaw = "tp"
        case triggerCondition = "tpc"
        case linkedRequestID = "tr"
        case linkedPositionID = "lp"
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
        try box.encodeIfPresent(triggerPriceRaw, forKey: .triggerPriceRaw)
        try box.encodeIfPresent(triggerCondition?.rawValue, forKey: .triggerCondition)
        try box.encodeIfPresent(linkedRequestID, forKey: .linkedRequestID)
        try box.encodeIfPresent(linkedPositionID, forKey: .linkedPositionID)
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
        case triggerRequiresLink
        case deadlineOverflow(headBlock: Int64, ttl: UInt32)
    }

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
            // Protocol v235 uses zero here for client orders. A future chain height was
            // accepted by the old gateway but is rejected by the deployed exchange.
            lastBlock: 0,
            maxSlippageBps: slippageBps,
            orderID: nil,
            triggerPriceRaw: nil, triggerCondition: nil,
            linkedRequestID: nil, linkedPositionID: nil)
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
        // Price zero is how this venue spells "marketable": a limit at zero would be a
        // good-till-cancelled market order with no slippage bound.
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
            lastBlock: 0,
            maxSlippageBps: nil,
            orderID: nil,
            triggerPriceRaw: nil, triggerCondition: nil,
            linkedRequestID: nil, linkedPositionID: nil)
    }

    /// Closing uses its own types, never an opposing open: they are exempt from the
    /// initial-margin check, so an underwater position can always be closed.
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
            lastBlock: 0,
            maxSlippageBps: slippageBps,
            orderID: nil,
            triggerPriceRaw: nil, triggerCondition: nil,
            linkedRequestID: nil, linkedPositionID: nil)
    }

    public static func protectiveClose(
        side: Side,
        market config: Market,
        account: UInt32,
        size: Size,
        triggerPrice: Price,
        condition: TriggerPriceCondition,
        linkedRequestID: Int64? = nil,
        linkedPositionID: Int64? = nil,
        slippageBps: Int,
        requestID: Int64,
        frameID: Int64
    ) throws -> OrderRequest {
        guard frameID != 0 else { throw Failure.frameIDMustBeNonZero }
        guard size.raw > 0 else { throw Failure.sizeMustBePositive }
        guard size.decimals == config.config.sizeDecimals else { throw Failure.sizeScaleMismatch }
        guard triggerPrice.decimals == config.config.priceDecimals else {
            throw Failure.priceScaleMismatch
        }
        guard triggerPrice.raw > 0 else { throw Failure.priceMustBePositive }
        guard linkedRequestID != nil || linkedPositionID != nil else {
            throw Failure.triggerRequiresLink
        }
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
            lastBlock: 0,
            maxSlippageBps: slippageBps,
            orderID: nil,
            triggerPriceRaw: triggerPrice.raw,
            triggerCondition: condition,
            linkedRequestID: linkedRequestID,
            linkedPositionID: linkedPositionID)
    }

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
            lastBlock: 0,
            maxSlippageBps: nil,
            orderID: orderID,
            triggerPriceRaw: nil, triggerCondition: nil,
            linkedRequestID: nil, linkedPositionID: nil)
    }

    private static func validate(
        size: Size, market config: Market, leverageHundredths: Int, frameID: Int64
    ) throws {
        // A zero frame id is omitted from the status response, so the order cannot be
        // correlated with its outcome.
        guard frameID != 0 else { throw Failure.frameIDMustBeNonZero }
        guard size.raw > 0 else { throw Failure.sizeMustBePositive }
        guard size.decimals == config.config.sizeDecimals else { throw Failure.sizeScaleMismatch }
        // Against the fraction itself: `maxLeverage * 100` truncates a 12.5x market to 12x.
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

    private static func after(_ value: Int64) -> Int64 {
        value == .max ? .max : value + 1
    }
}
