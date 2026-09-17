import DeskChain
import DeskPerpl
import Foundation
import Testing
@testable import DeskFlow

@Suite("Desk network")
struct DeskNetworkTests {
    @Test("every endpoint of a network names the same chain", arguments: DeskNetwork.allCases)
    func oneChain(network: DeskNetwork) throws {
        #expect(try network.rpc().chainID == network.chainID)
        #expect(try network.perpl().chainID == network.chainID)
        #expect(network.tradingSocket().chainIdentifier == network.chainID)
    }

    @Test("REST and market data point at the same Perpl", arguments: DeskNetwork.allCases)
    func oneVenue(network: DeskNetwork) throws {
        #expect(try network.perpl().baseURL.host() == network.marketDataURL.host())
    }

    @Test("only mainnet holds real funds, and only testnet has a faucet")
    func funds() {
        #expect(DeskNetwork.mainnet.holdsRealFunds && !DeskNetwork.mainnet.hasFaucet)
        #expect(!DeskNetwork.testnet.holdsRealFunds && DeskNetwork.testnet.hasFaucet)
    }
}
