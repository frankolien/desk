import CryptoKit
import Foundation

/// The texts Desk's server checks byte for byte when Auto-Copy runs there (web/api/_copy.mjs):
/// what the wallet signs to ask for a server key, the grant it signs to switch it on, and the
/// string the device key signs for every request after. The tests pin each to the server's own
/// output, so the two can't drift.
public enum ServerCopyProtocol {
    /// The hard limits the wallet approves with Face ID. Whole numbers, so the text the phone
    /// signs is the text the server writes.
    public struct Caps: Codable, Equatable, Sendable {
        public var maxMarginPerTrade: Int
        public var maxLeverage: Int
        public var maxOpenCopies: Int
        public var maxOpenNotional: Int
        public var maxDailyLoss: Int
        public var maxOrdersPerHour: Int

        public init(maxMarginPerTrade: Int, maxLeverage: Int, maxOpenCopies: Int, maxOpenNotional: Int, maxDailyLoss: Int, maxOrdersPerHour: Int) {
            self.maxMarginPerTrade = maxMarginPerTrade
            self.maxLeverage = maxLeverage
            self.maxOpenCopies = maxOpenCopies
            self.maxOpenNotional = maxOpenNotional
            self.maxDailyLoss = maxDailyLoss
            self.maxOrdersPerHour = maxOrdersPerHour
        }

        /// Room for the rules and guards already set, so switching on never refuses them:
        /// conviction sizing can double a margin, and every figure keeps a floor.
        public static func fitting(rules: [CopyRules], guards: CopyGuards) -> Caps {
            let margin = rules.map { $0.marginPerTrade * ($0.sizing == .conviction ? 2 : 1) }.max() ?? 0
            let leverage = rules.map(\.maxLeverage).max() ?? 0
            return Caps(
                maxMarginPerTrade: max(50, margin),
                maxLeverage: max(10, leverage),
                maxOpenCopies: max(5, guards.maxOpenCopies),
                maxOpenNotional: max(1_000, guards.maxMarketExposure),
                maxDailyLoss: max(100, guards.dailyLossLimit),
                maxOrdersPerHour: 30)
        }

        public func allows(rules: CopyRules) -> Bool {
            rules.marginPerTrade * (rules.sizing == .conviction ? 2 : 1) <= maxMarginPerTrade
                && rules.maxLeverage <= maxLeverage
        }

        public func allows(guards: CopyGuards) -> Bool {
            guards.maxOpenCopies <= maxOpenCopies
                && guards.dailyLossLimit <= maxDailyLoss
                && guards.maxMarketExposure <= maxOpenNotional
        }
    }

    /// JavaScript's `Date.prototype.toISOString`: UTC, always three fractional digits.
    public static func iso(milliseconds: Int64) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000))
    }

    public static func prepareText(account: String, network: DeskNetwork, issuedAt: Int64) -> String {
        [
            "Desk Auto-Copy: prepare a server key",
            "Account: \(account)",
            "Network: \(network.rawValue)",
            "Issued: \(iso(milliseconds: issuedAt))",
        ].joined(separator: "\n")
    }

    /// `serverKey` as the server reported it (0x and 64 lowercase hex); `deviceKey` the device
    /// key's X9.63 point, base64url.
    public static func grantText(account: String, network: DeskNetwork, serverKey: String, deviceKey: String, caps: Caps, issuedAt: Int64) -> String {
        [
            "Desk Auto-Copy grant",
            "I let Desk's server copy trades for this account within these limits.",
            "Account: \(account)",
            "Network: \(network.rawValue)",
            "Server key: \(serverKey)",
            "Device key: \(deviceKey)",
            "Max margin per trade: \(caps.maxMarginPerTrade) AUSD",
            "Max leverage: \(caps.maxLeverage)x",
            "Max open copies: \(caps.maxOpenCopies)",
            "Max open notional: \(caps.maxOpenNotional) AUSD",
            "Max daily loss: \(caps.maxDailyLoss) AUSD",
            "Max orders per hour: \(caps.maxOrdersPerHour)",
            "Issued: \(iso(milliseconds: issuedAt))",
        ].joined(separator: "\n")
    }

    /// What the device key signs for `/api/copy/<action>`; Perpl's shape with Desk's prefix.
    public static func canonical(chainID: UInt64, action: String, time: Int64, nonce: String, body: Data) -> String {
        let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        return ["desk-copy", String(chainID), "POST", "/api/copy/\(action)", String(time), nonce, hash].joined(separator: "\n")
    }

    /// Perpl's `typed_data`, spliced out of the payload untouched.
    public static func typedData(inPayload payload: Data) throws -> Data {
        try JSONSpan.value(of: "typed_data", in: payload)
    }

    /// Perpl's payload must name exactly the key the server reported: it's the key the wallet is
    /// about to authorise, so a payload for any other is refused before Face ID signs it.
    public static func payloadNamesKey(typedDataJSON: Data, serverKey: String) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: typedDataJSON) as? [String: Any],
              let message = root["message"] as? [String: Any],
              let named = message["publicKey"] as? String,
              let bytes = hexBytes(serverKey), bytes.count == 32
        else { return false }
        return named == base64URL(bytes)
    }

    /// Unpadded base64url, as the server and Perpl write it.
    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func hexBytes(_ text: String) -> Data? {
        let digits = Array((text.hasPrefix("0x") ? String(text.dropFirst(2)) : text).utf8)
        guard digits.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(digits.count / 2)
        for i in stride(from: 0, to: digits.count, by: 2) {
            guard let byte = UInt8(String(decoding: digits[i..<i + 2], as: UTF8.self), radix: 16) else { return nil }
            bytes.append(byte)
        }
        return Data(bytes)
    }
}
