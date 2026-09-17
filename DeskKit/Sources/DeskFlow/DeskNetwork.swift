import DeskChain
import DeskPerpl
import Foundation

/// Which Monad and which Perpl the whole app talks to.
///
/// Every endpoint lives here, so switching cannot leave one socket on testnet while the
/// balances read mainnet. The two differ in more than URLs: mainnet holds real funds, has
/// no faucet, and numbers its markets differently (BTC is 16 on testnet, 1 on mainnet).
public enum DeskNetwork: String, CaseIterable, Sendable, Identifiable {
    case testnet
    case mainnet

    public var id: String { rawValue }

    public var chainID: UInt64 {
        switch self {
        case .testnet: 10143
        case .mainnet: 143
        }
    }

    public var name: String {
        switch self {
        case .testnet: "Monad testnet"
        case .mainnet: "Monad mainnet"
        }
    }

    public var shortName: String {
        switch self {
        case .testnet: "Testnet"
        case .mainnet: "Mainnet"
        }
    }

    public var holdsRealFunds: Bool { self == .mainnet }
    public var hasFaucet: Bool { self == .testnet }

    public func rpc() throws -> MonadRPC.Configuration {
        switch self {
        case .testnet: try .testnet()
        case .mainnet: try .mainnet()
        }
    }

    public func perpl() throws -> PerplREST.Configuration {
        switch self {
        case .testnet: try .testnet()
        case .mainnet: try .mainnet()
        }
    }

    public func tradingSocket() -> PerplSocket {
        switch self {
        case .testnet: .testnet()
        case .mainnet: .mainnet()
        }
    }

    public var marketDataURL: URL {
        switch self {
        case .testnet: URL(string: "wss://testnet.perpl.xyz/ws/v1/market-data")!
        case .mainnet: URL(string: "wss://app.perpl.xyz/ws/v1/market-data")!
        }
    }

    public var explorer: URL {
        switch self {
        case .testnet: URL(string: "https://testnet.monadexplorer.com")!
        case .mainnet: URL(string: "https://monadvision.com")!
        }
    }

    /// BTC, which the market screen opens on before the context says what else exists.
    public var defaultMarketID: UInt32 {
        switch self {
        case .testnet: 16
        case .mainnet: 1
        }
    }
}
