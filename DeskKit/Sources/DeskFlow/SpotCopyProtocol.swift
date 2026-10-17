import DeskAuth
import Foundation

/// Spot Auto-Copy's texts and rules as the server reads them (web/api/_spot.mjs,
/// web/copyd/spot-rules.mjs). The grant is checked byte for byte; the tests pin it.
public enum SpotCopyProtocol {
    /// Per followed wallet. Amounts in AUSD; the max per buy can't pass the per-trade limit the
    /// wallet set on-chain.
    public struct Rules: Codable, Equatable, Sendable {
        public enum Sizing: String, Codable, Sendable { case fixed, match }
        public var sizing: Sizing
        public var amount: Double
        public var maxPerBuy: Double
        public var copySells: Bool
        public var buyOnce: Bool
        public var minLeaderUsd: Double
        public var maxLeaderUsd: Double?
        public var slippageBps: Int

        public init(sizing: Sizing = .fixed, amount: Double = 10, maxPerBuy: Double = 25, copySells: Bool = true, buyOnce: Bool = true,
                    minLeaderUsd: Double = 250, maxLeaderUsd: Double? = nil, slippageBps: Int = 500) {
            self.sizing = sizing
            self.amount = amount
            self.maxPerBuy = maxPerBuy
            self.copySells = copySells
            self.buyOnce = buyOnce
            self.minLeaderUsd = minLeaderUsd
            self.maxLeaderUsd = maxLeaderUsd
            self.slippageBps = slippageBps
        }

        /// The most one copy can spend under these rules.
        public var mostPerBuy: Double { sizing == .fixed ? amount : maxPerBuy }
    }

    /// The limits the chain holds, approved with Face ID. Whole AUSD, as the server requires.
    public struct Limits: Codable, Equatable, Sendable {
        public var perTrade: Int
        public var perDay: Int
        public init(perTrade: Int, perDay: Int) {
            self.perTrade = perTrade
            self.perDay = perDay
        }
    }

    /// `wallet` and `desk` any case; written checksummed, as the server writes them.
    public static func grantText(wallet: String, desk: String, deviceKey: String, limits: Limits, expiry: UInt64, issuedAt: Int64) -> String {
        [
            "Desk Spot Auto-Copy",
            "I let Desk's key copy token trades for this wallet, within these limits, until the date below.",
            "Wallet: \(checksummed(wallet))",
            "Desk key: \(checksummed(desk))",
            "Device key: \(deviceKey)",
            "Max per buy: \(limits.perTrade) AUSD",
            "Max per day: \(limits.perDay) AUSD",
            "Until: \(ServerCopyProtocol.iso(milliseconds: Int64(expiry) * 1000))",
            "Issued: \(ServerCopyProtocol.iso(milliseconds: issuedAt))",
        ].joined(separator: "\n")
    }

    static func checksummed(_ address: String) -> String {
        guard let bytes = ServerCopyProtocol.hexBytes(address.lowercased()), let parsed = EthereumAddress(bytes: bytes) else { return address }
        return parsed.checksummed
    }
}
