import DeskAuth
import Foundation
import Observation

/// A token bought through Desk, as the app remembers it.
///
/// The app remembers what was bought and what it cost; the chain is asked what is still
/// held. So a token sent on or sold elsewhere shows as what it is now, and one that was
/// never delivered shows as nothing rather than as the purchase.
struct SpotPurchase: Codable, Hashable, Identifiable, Sendable {
    let chainIndex: String
    let chainName: String
    let contract: String
    let symbol: String
    let name: String
    let logoURL: String
    /// What the purchase was worth in dollars at the quote, when the quote said.
    let paidUSD: Double?
    let boughtAt: Date

    var id: String { "\(chainIndex):\(contract.lowercased())" }
}

/// The purchases this wallet has made, kept on the device under the wallet's address.
enum SpotPurchases {
    private static func key(_ address: EthereumAddress) -> String {
        "desk.spotPurchases." + address.checksummed.lowercased()
    }

    static func load(for address: EthereumAddress) -> [SpotPurchase] {
        guard let data = UserDefaults.standard.data(forKey: key(address)) else { return [] }
        return (try? JSONDecoder().decode([SpotPurchase].self, from: data)) ?? []
    }

    /// One row per token. Buying the same token twice updates the cost rather than
    /// listing it twice: the chain reports one balance, so the app shows one holding.
    static func record(_ purchase: SpotPurchase, for address: EthereumAddress) {
        var list = load(for: address)
        if let index = list.firstIndex(where: { $0.id == purchase.id }) {
            let previous = list[index]
            let paid = (previous.paidUSD ?? 0) + (purchase.paidUSD ?? 0)
            list[index] = SpotPurchase(
                chainIndex: purchase.chainIndex, chainName: purchase.chainName, contract: purchase.contract,
                symbol: purchase.symbol, name: purchase.name, logoURL: purchase.logoURL,
                paidUSD: previous.paidUSD == nil && purchase.paidUSD == nil ? nil : paid,
                boughtAt: previous.boughtAt)
        } else {
            list.append(purchase)
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: key(address))
    }

    static func forget(_ id: String, for address: EthereumAddress) {
        let list = load(for: address).filter { $0.id != id }
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: key(address))
    }
}

/// A purchase with what the chain says about it now.
struct SpotHolding: Identifiable, Sendable {
    let purchase: SpotPurchase
    /// Nil when the chain could not be read; never a zero standing in for unknown.
    let balance: String?
    let value: Double?
    let price: Double?
    var id: String { purchase.id }

    /// Change since the purchase, as a fraction of what was paid. Nil without both sides.
    var changeSincePaid: Double? {
        guard let value, let paid = purchase.paidUSD, paid > 0 else { return nil }
        return (value - paid) / paid
    }
}

/// Reads the balances and prices of what this wallet bought, on a slow loop while Home
/// is showing. The list comes from the device; the figures come from each token's chain
/// and from the price feed, through the server so the app holds no API key.
@MainActor
@Observable
final class SpotHoldingsModel {
    private(set) var holdings: [SpotHolding] = []
    private(set) var isLoading = false
    private var address: EthereumAddress?

    private static let endpoint = "https://web-lovat-nine-49.vercel.app/api/token-details"

    private struct Response: Decodable {
        struct Row: Decodable {
            let chainIndex: String
            let contract: String
            let readable: Bool
            let balance: String?
            let price: Double?
            let value: Double?
        }
        let holdings: [Row]
    }

    func run(for address: EthereumAddress?) async {
        self.address = address
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(30))
        }
    }

    func refresh() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-holdings-demo") {
            holdings = Self.review
            return
        }
        #endif
        guard let address else { holdings = []; return }
        let purchases = SpotPurchases.load(for: address)
        guard !purchases.isEmpty else { holdings = []; return }
        isLoading = true
        defer { isLoading = false }
        var components = URLComponents(string: Self.endpoint)!
        components.queryItems = [
            URLQueryItem(name: "view", value: "holdings"),
            URLQueryItem(name: "address", value: address.checksummed),
            URLQueryItem(name: "items", value: purchases.map { "\($0.chainIndex):\($0.contract)" }.joined(separator: ",")),
        ]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try? JSONDecoder().decode(Response.self, from: data)
        else {
            // Keep what was last read rather than blanking the rows on one failed read.
            if holdings.isEmpty {
                holdings = purchases.map { SpotHolding(purchase: $0, balance: nil, value: nil, price: nil) }
            }
            return
        }
        let rows = Dictionary(uniqueKeysWithValues: body.holdings.map { ("\($0.chainIndex):\($0.contract.lowercased())", $0) })
        holdings = purchases.map { purchase in
            let row = rows[purchase.id]
            return SpotHolding(
                purchase: purchase,
                balance: row?.readable == true ? row?.balance : nil,
                value: row?.value,
                price: row?.price)
        }
    }
}

#if DEBUG
extension SpotHoldingsModel {
    /// Two holdings for the review screens, with figures a real read could return.
    static let review: [SpotHolding] = [
        SpotHolding(
            purchase: SpotPurchase(chainIndex: "4663", chainName: "Robinhood Chain", contract: "0x1", symbol: "WORM",
                                   name: "Worm", logoURL: "", paidUSD: 40, boughtAt: .now.addingTimeInterval(-86_400)),
            balance: "6412.5", value: 52.3, price: 0.00816),
        SpotHolding(
            purchase: SpotPurchase(chainIndex: "8453", chainName: "Base", contract: "0x2", symbol: "AERO",
                                   name: "Aerodrome", logoURL: "", paidUSD: 25, boughtAt: .now.addingTimeInterval(-3_600)),
            balance: "31.2", value: 23.1, price: 0.74),
    ]
}
#endif
