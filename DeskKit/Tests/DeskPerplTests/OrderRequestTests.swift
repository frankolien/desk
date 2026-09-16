import DeskMoney
import Foundation
import Testing
@testable import DeskPerpl

@Suite("Order encoding")
struct OrderRequestTests {
    let context: PerplContext
    let btc: Market

    init() throws {
        let url = try #require(Bundle.module.url(forResource: "Context-testnet", withExtension: "json"))
        context = try JSONDecoder().decode(PerplContext.self, from: Data(contentsOf: url))
        btc = try #require(context.market(id: 16))
    }

    func encoded(_ order: OrderRequest) throws -> [String: Any] {
        let encoder = JSONEncoder()
        let data = try encoder.encode(order)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // There is no market order type: it is a marketable limit at price zero, with
    // immediate-or-cancel and a slippage bound.
    @Test("a market order is price zero, IOC and a slippage bound")
    func marketOrder() throws {
        let order = try OrderBuilder.market(
            side: .long, market: btc, account: 7,
            size: #require(Size(typed: "0.01480", decimals: 5)),
            leverageHundredths: 100, slippageBps: 50,
            headBlock: 62_050_000, requestID: 41, frameID: 1)

        let json = try encoded(order)
        #expect(json["mt"] as? Int == 22)
        #expect(json["t"] as? Int == 1)
        #expect(json["p"] as? Int == 0)
        #expect(json["s"] as? Int == 1480)
        #expect(json["fl"] as? Int == 4)
        #expect(json["lv"] as? Int == 100)
        #expect(json["ms"] as? Int == 50)
        #expect(json["mkt"] as? Int == 16)
        #expect(json["acc"] as? Int == 7)
        #expect(json["rq"] as? Int == 41)
        #expect(json["sn"] as? Int == 1)
        #expect(json["oid"] == nil)
    }

    @Test("version 235 client orders carry a zero last block")
    func lastBlockIsProtocolSentinel() throws {
        let head: Int64 = 62_050_000
        let order = try OrderBuilder.market(
            side: .long, market: btc, account: 7,
            size: #require(Size(typed: "0.001", decimals: 5)),
            leverageHundredths: 100, slippageBps: 50,
            headBlock: head, requestID: 1, frameID: 1)
        #expect(order.lastBlock == 0)
        #expect(try encoded(order)["lb"] as? Int == 0)
    }

    @Test("a short opens with type two")
    func shortOrder() throws {
        let order = try OrderBuilder.market(
            side: .short, market: btc, account: 7,
            size: #require(Size(typed: "0.001", decimals: 5)),
            leverageHundredths: 300, slippageBps: 50,
            headBlock: 1, requestID: 1, frameID: 1)
        #expect(order.type == .openShort)
        #expect(order.leverageHundredths == 300)
    }

    @Test("a limit order carries its price and no slippage bound")
    func limitOrder() throws {
        let order = try OrderBuilder.limit(
            side: .long, market: btc, account: 7,
            price: #require(Price(buying: "67412.37", decimals: 1)),
            size: #require(Size(typed: "0.01480", decimals: 5)),
            leverageHundredths: 100, postOnly: true,
            headBlock: 1, requestID: 1, frameID: 1)
        let json = try encoded(order)
        #expect(json["p"] as? Int == 674123)   // floored to the grid
        #expect(json["fl"] as? Int == 1)
        #expect(json["ms"] == nil)
    }

    // Closing by opening an opposing position inverts it and pays taker on the way.
    @Test("closing uses the close types, not an opposing open")
    func closeUsesCloseTypes() throws {
        let long = try OrderBuilder.close(
            side: .long, market: btc, account: 7,
            size: #require(Size(typed: "0.01480", decimals: 5)),
            slippageBps: 50, headBlock: 1, requestID: 1, frameID: 1)
        #expect(long.type == .closeLong)
        let short = try OrderBuilder.close(
            side: .short, market: btc, account: 7,
            size: #require(Size(typed: "0.01480", decimals: 5)),
            slippageBps: 50, headBlock: 1, requestID: 1, frameID: 1)
        #expect(short.type == .closeShort)
    }

    @Test("protective closes are linked mark-price triggers")
    func protectiveClose() throws {
        let order = try OrderBuilder.protectiveClose(
            side: .long, market: btc, account: 7,
            size: #require(Size(typed: "0.01480", decimals: 5)),
            triggerPrice: #require(Price(selling: "64000", decimals: 1)),
            condition: .lessThanOrEqualMark,
            linkedRequestID: 41, slippageBps: 50,
            requestID: 42, frameID: 2)
        let json = try encoded(order)
        #expect(json["t"] as? Int == 3)
        #expect(json["p"] as? Int == 0)
        #expect(json["fl"] as? Int == 4)
        #expect(json["tp"] as? Int == 640_000)
        #expect(json["tpc"] as? Int == 4)
        #expect(json["tr"] as? Int == 41)
        #expect(json["lb"] as? Int == 0)
        #expect(json["ms"] as? Int == 50)
    }

    @Test("a protective close cannot float without a request or position link")
    func protectionRequiresLink() throws {
        #expect(throws: OrderBuilder.Failure.triggerRequiresLink) {
            try OrderBuilder.protectiveClose(
                side: .short, market: btc, account: 7,
                size: #require(Size(typed: "0.01480", decimals: 5)),
                triggerPrice: #require(Price(buying: "70000", decimals: 1)),
                condition: .greaterThanOrEqualMark,
                slippageBps: 50, requestID: 42, frameID: 2)
        }
    }

    @Test("cancel is message 22 with type five and an order id")
    func cancelIsNotItsOwnMessage() throws {
        let order = try OrderBuilder.cancel(
            market: btc, account: 7, orderID: 99, headBlock: 1, requestID: 1, frameID: 1)
        let json = try encoded(order)
        #expect(json["mt"] as? Int == 22)
        #expect(json["t"] as? Int == 5)
        #expect(json["oid"] as? Int == 99)
    }

    // A zero frame id is omitted from the status response, so the order cannot be
    // matched to its outcome.
    @Test("a zero frame id is refused")
    func zeroFrameIDRefused() throws {
        #expect(throws: OrderBuilder.Failure.frameIDMustBeNonZero) {
            try OrderBuilder.market(
                side: .long, market: btc, account: 7,
                size: #require(Size(typed: "0.001", decimals: 5)),
                leverageHundredths: 100, slippageBps: 50,
                headBlock: 1, requestID: 1, frameID: 0)
        }
    }

    @Test("leverage beyond the market's ceiling is refused")
    func leverageCeiling() throws {
        let size = try #require(Size(typed: "0.001", decimals: 5))
        #expect(throws: OrderBuilder.Failure.leverageOutOfRange(1600, max: 1500)) {
            try OrderBuilder.market(side: .long, market: btc, account: 7, size: size,
                                    leverageHundredths: 1600, slippageBps: 50,
                                    headBlock: 1, requestID: 1, frameID: 1)
        }
        #expect(throws: OrderBuilder.Failure.leverageOutOfRange(50, max: 1500)) {
            try OrderBuilder.market(side: .long, market: btc, account: 7, size: size,
                                    leverageHundredths: 50, slippageBps: 50,
                                    headBlock: 1, requestID: 1, frameID: 1)
        }
        #expect(throws: Never.self) {
            try OrderBuilder.market(side: .long, market: btc, account: 7, size: size,
                                    leverageHundredths: 1500, slippageBps: 50,
                                    headBlock: 1, requestID: 1, frameID: 1)
        }
    }

    @Test("slippage beyond the market's cap is refused")
    func slippageCap() throws {
        let size = try #require(Size(typed: "0.001", decimals: 5))
        #expect(throws: OrderBuilder.Failure.slippageOutOfRange(1001, max: 1000)) {
            try OrderBuilder.market(side: .long, market: btc, account: 7, size: size,
                                    leverageHundredths: 100, slippageBps: 1001,
                                    headBlock: 1, requestID: 1, frameID: 1)
        }
    }

    @Test("a size from another market's scale is refused")
    func wrongScaleRefused() throws {
        let ethSize = try #require(Size(typed: "1.500", decimals: 3))  // ETH's scale
        #expect(throws: OrderBuilder.Failure.sizeScaleMismatch) {
            try OrderBuilder.market(side: .long, market: btc, account: 7, size: ethSize,
                                    leverageHundredths: 100, slippageBps: 50,
                                    headBlock: 1, requestID: 1, frameID: 1)
        }
    }

    @Test("a zero or negative size is refused")
    func sizeMustBePositive() throws {
        for text in ["0.00000", "-0.00100"] {
            #expect(throws: OrderBuilder.Failure.sizeMustBePositive) {
                try OrderBuilder.market(
                    side: .long, market: btc, account: 7,
                    size: #require(Size(typed: text, decimals: 5)),
                    leverageHundredths: 100, slippageBps: 50,
                    headBlock: 1, requestID: 1, frameID: 1)
            }
        }
    }

    // rq must strictly increase per account; at or below the last forwarded value the
    // gateway rejects with sr: 32.
    @Test("the request counter strictly increases and reseeds forward only")
    func requestCounter() async {
        let counter = RequestCounter(lastForwarded: 40)
        #expect(await counter.take() == 41)
        #expect(await counter.take() == 42)
        // A reconnect reports an older value; the counter must not go backwards.
        await counter.reseed(lastForwarded: 10)
        #expect(await counter.take() == 43)
        // A reconnect reporting a newer value jumps forward.
        await counter.reseed(lastForwarded: 100)
        #expect(await counter.take() == 101)
    }
}
