import Foundation

/// Perpl's position events, as they stream from a Monad websocket.
///
/// None of their parameters are indexed, so a subscription cannot filter by account; the
/// account id is read from the second word of the data. That is cheap, and it lets a copy
/// react to the block a trader's position changed in rather than to the next poll.
public enum PositionEvents {
    public static let topics = [
        "0x04cc3d2fc73a9dca30eba1d05eca80b1b1216350243580027046f434fed4db18", // PositionOpenedV2
        "0x599b5f439ed4daf1f28ae8638e5439d3982e8001fb26dd8f70021b38672eb26f", // PositionClosed
        "0x6fc9c0ea1c0531654320ba06740c802447dbdef7c26cf749c4f12553cdd958a9", // PositionLiquidated
        "0x99a74f70c224396b9ba5fcd5a6e5f480db23e7a25a2b16a8c133ec2efb3e646c", // PositionIncreasedV2
        "0xcd4a9f7ae1cc250eaa0be6bdb30d07efaf0faafb4ff0e76d8fe09a8373e43f85", // PositionDecreased
    ]

    /// The `eth_subscribe` request for every position event on one exchange.
    public static func subscription(exchange: String, id: Int = 1) -> String {
        let topicList = topics.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"jsonrpc":"2.0","id":\#(id),"method":"eth_subscribe","params":["logs",{"address":"\#(exchange)","topics":[[\#(topicList)]]}]}"#
    }

    /// The account a pushed log belongs to, or nil when the frame is not a position event.
    public static func account(inFrame text: String) -> UInt64? {
        guard let data = text.data(using: .utf8),
              let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let params = frame["params"] as? [String: Any],
              let log = params["result"] as? [String: Any],
              let topic = (log["topics"] as? [String])?.first?.lowercased(), topics.contains(topic),
              let hex = log["data"] as? String else { return nil }
        let digits = hex.hasPrefix("0x") ? hex.dropFirst(2) : Substring(hex)
        guard digits.count >= 128 else { return nil }
        let word = digits.dropFirst(64).prefix(64)
        // Account ids fit comfortably in 64 bits; anything wider is not an account.
        guard word.prefix(48).allSatisfy({ $0 == "0" }) else { return nil }
        return UInt64(word.suffix(16), radix: 16)
    }
}
