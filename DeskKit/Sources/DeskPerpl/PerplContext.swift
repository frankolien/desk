import DeskMoney
import Foundation

/// `GET /api/v1/pub/context`, decoded.
///
/// The source of truth for every per-market number the app computes with. Nothing here
/// is hardcoded anywhere else: decimals, fees and margin fractions differ between
/// testnet and mainnet for the same asset.
public struct PerplContext: Decodable, Sendable {
    public let chain: ChainInfo
    public let instances: [Instance]
    public let tokens: [Token]
    public let markets: [Market]
    /// Perpl blocks these at its own gateway. Notably the United States and the United
    /// Kingdom, which is a fact about where the demo can be recorded, not a detail.
    public let geoBlock: [String]
    public let features: [String: String]

    enum CodingKeys: String, CodingKey {
        case chain, instances, tokens, markets, features
        case geoBlock = "geo_block"
    }

    /// Perpl can turn enrolment off for everyone. When it is off the app has no way in
    /// at all, so this is checked at sign-in and said out loud rather than surfacing as
    /// an enrolment that fails for no stated reason.
    public var apiKeysEnabled: Bool { features["apiKeysEnabled"] == "on" }

    public func market(id: UInt32) -> Market? { markets.first { $0.id == id } }
    public var collateralToken: Token? { tokens.first { $0.symbol == "AUSD" } }
}

public struct ChainInfo: Decodable, Sendable {
    public let chainID: UInt64
    public let name: String
    public let blockExplorerURLs: [String]
    public let gas: GasSnapshot?

    enum CodingKeys: String, CodingKey {
        case chainID = "chain_id"
        case blockExplorerURLs = "block_explorer_urls"
        case name, gas
    }
}

/// Monad's fee market, as Perpl already observes it.
///
/// Worth taking from here rather than from a separate RPC call: it arrives with the
/// context the app already fetches, and it carries the head block that an order's
/// `lb` deadline is measured from.
public struct GasSnapshot: Decodable, Sendable {
    public let observedAt: BlockStamp
    public let headBlock: Int64
    public let baseFeeWei: Int64
    public let medianFeeWei: Int64
    public let percentile95FeeWei: Int64
    public let maximumFeeWei: Int64
    public let minimumFeeWei: Int64

    enum CodingKeys: String, CodingKey {
        case observedAt = "at"
        case headBlock = "h"
        case baseFeeWei = "base"
        case medianFeeWei = "p50"
        case percentile95FeeWei = "p95"
        case maximumFeeWei = "max"
        case minimumFeeWei = "min"
    }

    public init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        observedAt = try box.decode(BlockStamp.self, forKey: .observedAt)
        headBlock = try box.decodeWireInt(.headBlock)
        baseFeeWei = try box.decodeWireInt(.baseFeeWei)
        medianFeeWei = try box.decodeWireInt(.medianFeeWei)
        percentile95FeeWei = try box.decodeWireInt(.percentile95FeeWei)
        maximumFeeWei = try box.decodeWireInt(.maximumFeeWei)
        minimumFeeWei = try box.decodeWireInt(.minimumFeeWei)
    }
}

public struct Instance: Decodable, Sendable {
    public let id: UInt32
    public let address: String
    public let collateralTokenID: UInt32
    public let minAccountOpenRaw: Int64
    public let minDepositRaw: Int64
    public let minWithdrawRaw: Int64
    public let maxAccountTriggerOrders: Int

    public var minAccountOpen: Money? { Money(raw: minAccountOpenRaw) }
    public var minDeposit: Money? { Money(raw: minDepositRaw) }
    public var minWithdraw: Money? { Money(raw: minWithdrawRaw) }

    enum CodingKeys: String, CodingKey {
        case id, address
        case collateralTokenID = "collateral_token_id"
        case minAccountOpenRaw = "min_account_open_amount"
        case minDepositRaw = "min_deposit_amount"
        case minWithdrawRaw = "min_withdraw_amount"
        case maxAccountTriggerOrders = "max_account_trigger_orders"
    }

    public init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decode(UInt32.self, forKey: .id)
        address = try box.decode(String.self, forKey: .address)
        collateralTokenID = try box.decode(UInt32.self, forKey: .collateralTokenID)
        minAccountOpenRaw = try box.decodeWireInt(.minAccountOpenRaw)
        minDepositRaw = try box.decodeWireInt(.minDepositRaw)
        minWithdrawRaw = try box.decodeWireInt(.minWithdrawRaw)
        maxAccountTriggerOrders = try box.decode(Int.self, forKey: .maxAccountTriggerOrders)
    }
}

public struct Token: Decodable, Sendable {
    public let id: UInt32
    public let address: String
    public let symbol: String
    public let decimals: UInt8
    public let displayPrecision: UInt8

    enum CodingKeys: String, CodingKey {
        case id, address, symbol, decimals
        case displayPrecision = "display_precision"
    }
}

public struct Market: Decodable, Sendable {
    public let id: UInt32
    /// The exchange instance which owns this market. Wallet snapshots may contain
    /// accounts for more than one instance; orders must use the matching account.
    public let instanceID: UInt32
    public let symbol: String
    public let sizeUnits: String
    public let fundingIntervalSeconds: Int
    public let orderTTLBlocks: UInt32
    public let maxMarketSlippageBps: Int
    public let maxNegativePnLCollateralBps: Int
    public let config: MarketConfig
    public let state: MarketState
    public let funding: MarketFunding?

    enum CodingKeys: String, CodingKey {
        case id, symbol, name, config, state, funding
        case instanceID = "instance_id"
        case sizeUnits = "size_units"
        case fundingIntervalSeconds = "funding_interval_sec"
        case orderTTLBlocks = "order_ttl_blocks"
        case maxMarketSlippageBps = "order_max_market_slippage_bps"
        case maxNegativePnLCollateralBps = "order_max_neg_pnl_collat_bps"
    }

    public init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decode(UInt32.self, forKey: .id)
        instanceID = try box.decode(UInt32.self, forKey: .instanceID)
        // Mainnet leaves `symbol` empty for its oldest markets (BTC, MON) and carries the
        // ticker in `name`; testnet fills both, with `name` as "BTC Perp".
        let symbol = try box.decodeIfPresent(String.self, forKey: .symbol) ?? ""
        let name = try box.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.symbol = symbol.isEmpty
            ? String(name.split(separator: " ").first ?? Substring(name))
            : symbol
        sizeUnits = try box.decode(String.self, forKey: .sizeUnits)
        fundingIntervalSeconds = try box.decode(Int.self, forKey: .fundingIntervalSeconds)
        orderTTLBlocks = try box.decode(UInt32.self, forKey: .orderTTLBlocks)
        maxMarketSlippageBps = try box.decode(Int.self, forKey: .maxMarketSlippageBps)
        maxNegativePnLCollateralBps = try box.decode(Int.self, forKey: .maxNegativePnLCollateralBps)
        config = try box.decode(MarketConfig.self, forKey: .config)
        state = try box.decode(MarketState.self, forKey: .state)
        funding = try box.decodeIfPresent(MarketFunding.self, forKey: .funding)
    }

    public func price(_ raw: Int64) -> Price? { Price(raw: raw, decimals: config.priceDecimals) }
    public func size(_ raw: Int64) -> Size? { Size(raw: raw, decimals: config.sizeDecimals) }
}

public struct MarketConfig: Decodable, Sendable {
    public let isOpen: Bool
    public let priceDecimals: UInt8
    public let sizeDecimals: UInt8
    /// Divisors in hundredths, not percentages. See `maxLeverage`.
    public let initialMarginFraction: Int
    public let maintenanceMarginFraction: Int
    public let makerFeeMicros: Int64
    public let takerFeeMicros: Int64
    public let makerFeeTiersMicros: [Int64]
    public let takerFeeTiersMicros: [Int64]

    /// `initial_margin: 1500` is 15x, not 15%. The maintenance number being larger means
    /// a *smaller* rate, and the two readings coincide at exactly 1000 — so a market
    /// configured there passes either way and the misreading survives casual testing.
    public var maxLeverage: Int { initialMarginFraction / 100 }

    /// Maintenance margin as a percentage, for display only. Compute with the fractions.
    public var maintenanceMarginPercent: Double { 100.0 / Double(maintenanceMarginFraction) * 100 }

    enum CodingKeys: String, CodingKey {
        case isOpen = "is_open"
        case priceDecimals = "price_decimals"
        case sizeDecimals = "size_decimals"
        case initialMarginFraction = "initial_margin"
        case maintenanceMarginFraction = "maintenance_margin"
        case makerFeeMicros = "maker_fee"
        case takerFeeMicros = "taker_fee"
        case makerFeeTiersMicros = "maker_fees"
        case takerFeeTiersMicros = "taker_fees"
    }
}

public struct MarketState: Decodable, Sendable {
    public let observedAt: BlockStamp
    public let oracleRaw: Int64
    public let markRaw: Int64
    public let lastRaw: Int64
    public let midRaw: Int64
    public let bidRaw: Int64
    public let askRaw: Int64
    public let previousRaw: Int64
    public let openInterestRaw: Int64

    enum CodingKeys: String, CodingKey {
        case observedAt = "at"
        case oracleRaw = "orl"
        case markRaw = "mrk"
        case lastRaw = "lst"
        case midRaw = "mid"
        case bidRaw = "bid"
        case askRaw = "ask"
        case previousRaw = "prv"
        case openInterestRaw = "oi"
    }

    // Perpl sends a scaled integer as a number while it is small and as a string once it
    // is large, per field and without warning. One market crossing that threshold used to
    // fail the whole context decode, which is the app failing to start.
    public init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        observedAt = try box.decode(BlockStamp.self, forKey: .observedAt)
        oracleRaw = try box.decodeWireInt(.oracleRaw)
        markRaw = try box.decodeWireInt(.markRaw)
        lastRaw = try box.decodeWireInt(.lastRaw)
        midRaw = try box.decodeWireInt(.midRaw)
        bidRaw = try box.decodeWireInt(.bidRaw)
        askRaw = try box.decodeWireInt(.askRaw)
        previousRaw = try box.decodeWireInt(.previousRaw)
        openInterestRaw = try box.decodeWireInt(.openInterestRaw)
    }
}

public struct MarketFunding: Decodable, Sendable {
    public let observedAt: BlockStamp
    public let eventBlock: Int64
    /// In micros. No field name says so; the contract calls it `fundingRatePct100k`.
    public let rateMicros: Int64
    public let indexRaw: Int64
    public let premiumPnLRaw: Int64
    public let sumRaw: Int64
    public let divisor: Int64

    enum CodingKeys: String, CodingKey {
        case observedAt = "at"
        case eventBlock = "feb"
        case rateMicros = "rate"
        case indexRaw = "idx"
        case premiumPnLRaw = "ppl"
        case sumRaw = "sum"
        case divisor = "div"
    }

    public init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        observedAt = try box.decode(BlockStamp.self, forKey: .observedAt)
        eventBlock = try box.decodeWireInt(.eventBlock)
        rateMicros = try box.decodeWireInt(.rateMicros)
        indexRaw = try box.decodeWireInt(.indexRaw)
        premiumPnLRaw = try box.decodeWireInt(.premiumPnLRaw)
        sumRaw = try box.decodeWireInt(.sumRaw)
        divisor = try box.decodeWireInt(.divisor)
    }
}

/// A block and the wall-clock time it was observed at — Perpl's `at` on every snapshot.
///
/// Named `BlockStamp` rather than the obvious `Observation`, which would shadow Swift's
/// own `Observation` module for every file that imports this one and break the
/// `@Observable` macro with an error that names neither this type nor that module.
public struct BlockStamp: Decodable, Sendable {
    public let block: Int64
    public let timestampMilliseconds: Int64

    enum CodingKeys: String, CodingKey {
        case block = "b"
        case timestampMilliseconds = "t"
    }

    public init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        block = try box.decodeWireInt(.block)
        timestampMilliseconds = try box.decodeWireInt(.timestampMilliseconds)
    }
}

extension KeyedDecodingContainer {
    /// Perpl sends small scaled integers as JSON numbers and large ones as strings.
    func decodeWireInt(_ key: Key) throws -> Int64 {
        if let value = try? decode(Int64.self, forKey: key) { return value }
        let text = try decode(String.self, forKey: key)
        guard let value = Int64(text) else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: self, debugDescription: "not an integer: \(text)")
        }
        return value
    }
}

extension PerplContext {
    public enum Invariant: Error, Equatable, Sendable {
        case collateralTokenMissing
        case collateralDecimalsUnexpected(UInt8)
        case marginFractionsInverted(market: UInt32, initial: Int, maintenance: Int)
        case decimalsUnusable(market: UInt32, price: UInt8, size: UInt8)
        case marginFractionOutOfRange(market: UInt32, initial: Int, maintenance: Int)
        case slippageCapUnusable(market: UInt32, bps: Int)
        case orderTTLUnusable(market: UInt32, blocks: UInt32)
        case headBlockUnusable(Int64)
    }

    /// Blocks arrive at roughly two a second, so this is some hundreds of millions of
    /// years away and anything past it is a bad answer rather than a distant one.
    public static let implausibleBlock: Int64 = 1 << 52

    /// Checks what the app assumes before it computes anything with this.
    ///
    /// The margin check is the valuable one: `maintenance > initial` holds only under
    /// the divisor reading. Read as percentages a fresh long's liquidation price lands
    /// *above* its entry, and no other assertion catches it.
    @discardableResult
    public func validated() throws -> Self {
        guard let collateral = collateralToken else { throw Invariant.collateralTokenMissing }
        guard collateral.decimals == Money.decimals else {
            throw Invariant.collateralDecimalsUnexpected(collateral.decimals)
        }
        if let head = chain.gas?.headBlock {
            // `lb` is computed from this, and an unbounded value traps on the addition.
            guard head > 0, head < Self.implausibleBlock else { throw Invariant.headBlockUnusable(head) }
        }
        for market in markets {
            // A divisor at or below 100 is not leverage, and a maintenance divisor of
            // zero makes the displayed margin percentage infinite.
            guard market.config.initialMarginFraction >= 100,
                  market.config.maintenanceMarginFraction > 0
            else {
                throw Invariant.marginFractionOutOfRange(
                    market: market.id,
                    initial: market.config.initialMarginFraction,
                    maintenance: market.config.maintenanceMarginFraction)
            }
            // A zero cap would refuse every close, which is a server locking a user out
            // of their own position.
            guard market.maxMarketSlippageBps > 0 else {
                throw Invariant.slippageCapUnusable(market: market.id, bps: market.maxMarketSlippageBps)
            }
            guard market.orderTTLBlocks > 0 else {
                throw Invariant.orderTTLUnusable(market: market.id, blocks: market.orderTTLBlocks)
            }
            guard market.config.maintenanceMarginFraction > market.config.initialMarginFraction else {
                throw Invariant.marginFractionsInverted(
                    market: market.id,
                    initial: market.config.initialMarginFraction,
                    maintenance: market.config.maintenanceMarginFraction)
            }
            guard Price(raw: 0, decimals: market.config.priceDecimals) != nil,
                  Size(raw: 0, decimals: market.config.sizeDecimals) != nil
            else {
                throw Invariant.decimalsUnusable(
                    market: market.id,
                    price: market.config.priceDecimals,
                    size: market.config.sizeDecimals)
            }
        }
        return self
    }
}
