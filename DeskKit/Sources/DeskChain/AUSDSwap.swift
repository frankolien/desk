import DeskAuth
import DeskMoney
import Foundation

/// Every field comes from a quote service. Signing is allowed only for a call to 0x's AllowanceHolder on
/// Monad mainnet sending exactly the typed MON; what the route delivers is simulated before Face ID.
public struct AUSDSwap: Sendable, Hashable {
    public enum Failure: Error, Sendable, Equatable {
        case wrongChain(UInt64)
        case unknownContract(String)
        case unexpectedCall
        case amountMismatch
        case malformed
    }

    public static let chainID: UInt64 = 143
    /// 0x AllowanceHolder, one CREATE2 address on every chain 0x deploys to.
    public static let allowanceHolder = "0000000000001ff3684f28c67538d4d072c22734"
    public static let execSelector = "2213bc0b"

    public let to: EthereumAddress
    public let data: Data
    public let value: NativeAmount
    public let minimumOut: Money

    public init(
        chainID: UInt64, to: String, data: String, value: String,
        amount: NativeAmount, minimumOut: Money
    ) throws {
        guard chainID == Self.chainID else { throw Failure.wrongChain(chainID) }
        let target = Self.strip(to).lowercased()
        guard target == Self.allowanceHolder,
              let address = Self.bytes(target).flatMap(EthereumAddress.init(bytes:))
        else { throw Failure.unknownContract(to) }
        guard let calldata = Self.bytes(Self.strip(data)), calldata.count > 4 + 32 * 5 else {
            throw Failure.malformed
        }
        guard calldata.prefix(4).map({ String(format: "%02x", $0) }).joined() == Self.execSelector else {
            throw Failure.unexpectedCall
        }
        guard value.allSatisfy(\.isASCIIDigit), !value.isEmpty, value == amount.weiText, !amount.isZero else {
            throw Failure.amountMismatch
        }
        guard minimumOut.raw > 0 else { throw Failure.malformed }
        self.to = address
        self.data = calldata
        self.value = amount
        self.minimumOut = minimumOut
    }

    private static func strip(_ text: String) -> String {
        text.hasPrefix("0x") || text.hasPrefix("0X") ? String(text.dropFirst(2)) : text
    }

    private static func bytes(_ hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }
}
