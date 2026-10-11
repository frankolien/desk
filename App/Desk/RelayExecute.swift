import DeskAuth
import DeskChain
import Foundation

/// Hands a signed gasless sale to the Desk server, which forwards it to Relay under the
/// server's key: Calibur's batch signature, and the EIP-7702 authorization when the wallet
/// does not yet run Calibur on that chain. The same shape as `DeskProfile`'s signed requests.
enum RelayExecute {
    enum Failure: Error, Equatable, Sendable {
        case refused(String)
        case unreachable
    }

    private static let endpoint = URL(string: "https://web-lovat-nine-49.vercel.app/api/relay-quote?view=execute")!

    /// Returns Relay's request id, the one `relay-status` follows to the fill.
    static func submit(_ sale: GaslessSale, signatures: GaslessSale.Signatures) async throws -> String {
        let hex = { (data: Data) in "0x" + data.map { String(format: "%02x", $0) }.joined() }
        var payload: [String: Any] = [
            "chainId": sale.chainID,
            "user": sale.wallet.checksummed,
            "requestId": sale.requestID,
            "calls": sale.calls.map { ["to": hex($0.to.bytes), "value": "0", "data": hex($0.data)] },
            "batchNonce": sale.batchNonce,
            "signature": hex(signatures.batch.serialized),
        ]
        if let authorization = signatures.authorization, let nonce = sale.authorizationNonce {
            payload["authorization"] = ["nonce": nonce, "yParity": Int(authorization.yParity), "r": hex(authorization.r), "s": hex(authorization.s)]
        }
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { throw Failure.unreachable }
        let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200, let requestID = body["requestId"] as? String else {
            throw Failure.refused(body["error"] as? String ?? "Relay could not take this sale right now.")
        }
        return requestID
    }
}
