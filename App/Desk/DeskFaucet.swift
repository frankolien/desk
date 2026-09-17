import DeskAuth
import Foundation

/// Desk's testnet faucet. The paying wallet's key lives only in the server's environment;
/// the app sends an address and learns what arrived.
struct DeskFaucet: Sendable {
    struct Delivery: Decodable, Sendable {
        let status: String
        let reason: String?

        var arrived: Bool { status == "sent" }
    }

    struct Outcome: Decodable, Sendable {
        let mon: Delivery
        let ausd: Delivery
    }

    enum Failure: Error, Sendable {
        /// The faucet is unconfigured or unreachable, so the manual route is the only one.
        case unavailable
        case tooSoon
    }

    private static let endpoint = URL(string: "https://web-lovat-nine-49.vercel.app/api/faucet")!

    func fund(_ address: EthereumAddress) async throws -> Outcome {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["address": address.checksummed])

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else {
            throw Failure.unavailable
        }
        switch status {
        case 200:
            guard let outcome = try? JSONDecoder().decode(Outcome.self, from: data) else {
                throw Failure.unavailable
            }
            return outcome
        case 429: throw Failure.tooSoon
        default: throw Failure.unavailable
        }
    }

    /// The one sentence worth showing, or nil when everything needed arrived.
    static func problem(in outcome: Outcome) -> String? {
        if outcome.mon.status == "unavailable" {
            return "Desk's MON faucet is dry right now. Use Monad's faucet instead."
        }
        guard outcome.ausd.status == "unavailable" else { return nil }
        return switch outcome.ausd.reason {
        case "cooldown": "Agora's AUSD faucet is cooling down. Try again in a minute."
        case "faucet-empty": "Agora's AUSD faucet could not send right now."
        default: "Test AUSD could not be claimed. Try again in a minute."
        }
    }
}
