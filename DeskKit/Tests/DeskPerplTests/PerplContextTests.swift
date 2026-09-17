import DeskMoney
import Foundation
import Testing
@testable import DeskPerpl

/// Pinned to a payload captured from https://testnet.perpl.xyz on 13 September 2026.
@Suite("Perpl context")
struct PerplContextTests {
    let context: PerplContext

    init() throws {
        let url = try #require(Bundle.module.url(forResource: "Context-testnet", withExtension: "json"))
        context = try JSONDecoder().decode(PerplContext.self, from: Data(contentsOf: url))
    }

    @Test("the live payload decodes and satisfies every invariant")
    func decodesAndValidates() throws {
        try context.validated()
        #expect(context.chain.chainID == 10143)
        #expect(context.markets.count == 7)
    }

    @Test("BTC carries the numbers the spec was written against")
    func btcMarket() throws {
        let btc = try #require(context.market(id: 16))
        #expect(btc.symbol == "BTC")
        #expect(btc.config.priceDecimals == 1)
        #expect(btc.config.sizeDecimals == 5)
        #expect(btc.config.maxLeverage == 15)
        #expect(btc.config.initialMarginFraction == 1500)
        #expect(btc.config.maintenanceMarginFraction == 2500)
        #expect(btc.config.makerFeeMicros == 45)
        #expect(btc.config.takerFeeMicros == 345)
        #expect(btc.fundingIntervalSeconds == 2580)
        #expect(btc.orderTTLBlocks == 20)
        #expect(btc.maxMarketSlippageBps == 1000)
    }

    @Test("AUSD is the collateral at six decimals")
    func collateral() throws {
        let ausd = try #require(context.collateralToken)
        #expect(ausd.decimals == Money.decimals)
        #expect(ausd.displayPrecision == 2)
        #expect(ausd.address == "0xa9012a055bd4e0edff8ce09f960291c09d5322dc")
    }

    @Test("opening an account needs 100 AUSD on testnet")
    func minimums() throws {
        let instance = try #require(context.instances.first)
        #expect(try #require(instance.minAccountOpen).display() == "100.00")
        #expect(try #require(instance.minDeposit).display() == "10.00")
    }

    // The reason decimals are never constants: three live testnet markets sum to five,
    // where the naive price * size shortcut is out by exactly ten.
    @Test("three markets do not sum to six decimals")
    func decimalsAreNotAConstant() {
        let sums = Dictionary(uniqueKeysWithValues: context.markets.map {
            ($0.symbol, Int($0.config.priceDecimals) + Int($0.config.sizeDecimals))
        })
        #expect(sums["BTC"] == 6)
        #expect(sums["ETH"] == 5)
        #expect(sums["SOL"] == 5)
        #expect(sums["MON"] == 5)
        #expect(context.markets.filter { Int($0.config.priceDecimals) + Int($0.config.sizeDecimals) != 6 }.count == 3)
    }

    @Test("notional is right on a market whose decimals do not sum to six")
    func notionalOnLiveETH() throws {
        let eth = try #require(context.market(id: 32))
        let price = try #require(Price(text: "2466.40", decimals: eth.config.priceDecimals, rounding: .towardZero))
        let size = try #require(Size(typed: "1.500", decimals: eth.config.sizeDecimals))
        let notional = try #require(Money.notional(price: price, size: size, rounding: .towardZero))
        #expect(notional.display() == "3,699.60")
    }

    @Test("market state prices decode at the market's scale")
    func stateDecodes() throws {
        let btc = try #require(context.market(id: 16))
        let mark = try #require(btc.price(btc.state.markRaw))
        #expect(mark.text == "77245.8")
        #expect(btc.state.observedAt.block > 62_000_000)
        #expect(try #require(btc.price(btc.state.askRaw)) > #require(btc.price(btc.state.bidRaw)))
    }

    @Test("funding carries a micros rate and the interval is 43 minutes")
    func funding() throws {
        let btc = try #require(context.market(id: 16))
        let funding = try #require(btc.funding)
        #expect(funding.rateMicros == 30)
        #expect(btc.fundingIntervalSeconds == 2580)
        #expect(Double(btc.fundingIntervalSeconds) / 60 == 43)
    }

    @Test("a payload with the margin fractions read as percentages is refused")
    func invertedMarginsRefused() throws {
        let url = try #require(Bundle.module.url(forResource: "Context-testnet", withExtension: "json"))
        var json = try String(contentsOf: url, encoding: .utf8)
        // Swap BTC's two margin numbers, which is what the percentage misreading implies.
        json = json.replacingOccurrences(
            of: "\"initial_margin\": 1500, \"maintenance_margin\": 2500",
            with: "\"initial_margin\": 2500, \"maintenance_margin\": 1500")
        if json == (try String(contentsOf: url, encoding: .utf8)) {
            json = json.replacingOccurrences(of: "\"initial_margin\":1500,\"maintenance_margin\":2500",
                                             with: "\"initial_margin\":2500,\"maintenance_margin\":1500")
        }
        let doctored = try JSONDecoder().decode(PerplContext.self, from: Data(json.utf8))
        #expect(throws: PerplContext.Invariant.marginFractionsInverted(
            market: 16, initial: 2500, maintenance: 1500)) {
            try doctored.validated()
        }
    }

    @Test("wire integers decode whether sent as a number or a string")
    func wireIntegers() throws {
        struct Box: Decodable { let value: Int64
            enum CodingKeys: String, CodingKey { case value }
            init(from decoder: any Decoder) throws {
                value = try decoder.container(keyedBy: CodingKeys.self).decodeWireInt(.value)
            }
        }
        #expect(try JSONDecoder().decode(Box.self, from: Data(#"{"value":123}"#.utf8)).value == 123)
        #expect(try JSONDecoder().decode(Box.self, from: Data(#"{"value":"316833663305"}"#.utf8)).value == 316_833_663_305)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(Box.self, from: Data(#"{"value":"abc"}"#.utf8))
        }
    }
}

@Suite("Context: the live shape")
struct LiveContextTests {
    private func context() throws -> PerplContext {
        let url = try #require(Bundle.module.url(forResource: "Context-testnet", withExtension: "json"))
        return try JSONDecoder().decode(PerplContext.self, from: try Data(contentsOf: url))
    }

    @Test("Monad's fee market arrives with the context, above the 100 gwei floor")
    func gasSnapshot() throws {
        let gas = try #require(try context().chain.gas)
        #expect(gas.baseFeeWei == 100_000_000_000)
        #expect(gas.medianFeeWei >= gas.baseFeeWei)
        #expect(gas.maximumFeeWei >= gas.percentile95FeeWei)
        #expect(gas.headBlock > 0)
        #expect(gas.headBlock == gas.observedAt.block)
    }

    @Test("Enrolment is gated on a flag Perpl can turn off")
    func apiKeysFlag() throws {
        #expect(try context().apiKeysEnabled)
    }

    @Test("The United States and the United Kingdom are blocked at the gateway")
    func geoBlock() throws {
        let blocked = Set(try context().geoBlock)
        #expect(blocked.contains("US"))
        #expect(blocked.contains("GB"))
    }

    @Test("Opening a desk costs a hundred AUSD, not a dust amount")
    func minimums() throws {
        let instance = try #require(try context().instances.first)
        #expect(instance.minAccountOpenRaw == 100_000_000)
        #expect(instance.minAccountOpen?.text == "100.000000")
        #expect(instance.minDepositRaw == 10_000_000)
    }

    @Test("BTC prices to a tenth and sizes to a hundred-thousandth")
    func btcScales() throws {
        let btc = try #require(try context().market(id: 16))
        #expect(btc.config.priceDecimals == 1)
        #expect(btc.config.sizeDecimals == 5)
        #expect(btc.config.maxLeverage == 15)
        #expect(btc.maxMarketSlippageBps == 1000)
        #expect(btc.orderTTLBlocks == 20)
    }
}

/// Pinned to a payload captured from https://app.perpl.xyz on 17 September 2026.
@Suite("Perpl mainnet context")
struct PerplMainnetContextTests {
    let context: PerplContext

    init() throws {
        let url = try #require(Bundle.module.url(forResource: "Context-mainnet", withExtension: "json"))
        context = try JSONDecoder().decode(PerplContext.self, from: Data(contentsOf: url))
    }

    @Test("the mainnet payload decodes and satisfies every invariant")
    func decodes() throws {
        try context.validated()
        #expect(context.chain.chainID == 143)
    }

    @Test("markets with an empty symbol take their ticker from the name")
    func symbols() throws {
        #expect(try #require(context.market(id: 1)).symbol == "BTC")
        #expect(try #require(context.market(id: 10)).symbol == "MON")
        #expect(try #require(context.market(id: 20)).symbol == "ETH")
    }
}
