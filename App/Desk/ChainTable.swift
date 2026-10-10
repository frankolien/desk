import Foundation

/// The chains Desk names and buys on, mirrored from the API's `_chains.mjs` so a token that
/// arrives without its chain's name (a holding, a tracked wallet's trade, an alert) still reads
/// and still buys. Monad buys through 0x in the app itself; the rest are Relay's destinations,
/// delivered for MON paid on Monad.
enum ChainTable {
    static let monad = "143"
    static let solana = "501"

    private static let names: [String: String] = [
        "1": "Ethereum", "10": "OP Mainnet", "56": "BNB Chain", "130": "Unichain", "137": "Polygon",
        "143": "Monad", "146": "Sonic", "196": "X Layer", "480": "World Chain", "501": "Solana",
        "999": "HyperEVM", "2741": "Abstract", "4217": "Tempo", "4663": "Robinhood Chain",
        "5000": "Mantle", "5042": "Arc", "8453": "Base", "9745": "Plasma", "10143": "Monad Testnet",
        "42161": "Arbitrum One", "43114": "Avalanche", "57073": "Ink", "59144": "Linea",
        "80094": "Berachain", "534352": "Scroll",
    ]

    private static let relayDestinations: Set<String> = [
        "1", "10", "25", "56", "100", "130", "137", "146", "169", "196", "288", "324", "360",
        "480", "747", "988", "999", "1088", "1135", "1868", "2020", "2741", "2818", "4217",
        "4326", "4663", "5000", "5031", "5042", "5330", "8453", "9745", "33139", "34443",
        "42018", "42161", "42220", "43114", "48900", "57073", "59144", "60808", "80094",
        "81457", "97477", "98866", "534352", "685689", "747474", "5064014", "7777777",
    ]

    static func name(_ chainIndex: String) -> String {
        names[chainIndex] ?? "Chain \(chainIndex)"
    }

    /// Whether a token on this chain can be bought from the app with MON.
    static func buys(on chainIndex: String) -> Bool {
        chainIndex == monad || relayDestinations.contains(chainIndex)
    }

    /// A name the feed left as a placeholder is replaced by the table's.
    static func displayName(_ chainName: String, chainIndex: String) -> String {
        chainName.isEmpty || chainName.hasPrefix("Chain ") ? name(chainIndex) : chainName
    }
}
