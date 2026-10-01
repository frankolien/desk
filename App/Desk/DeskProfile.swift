import DeskAuth
import Foundation

struct DeskProfile: Sendable {
    struct Saved: Decodable, Sendable {
        let name: String?
        let avatar: String?
    }

    enum Failure: Error, Sendable {
        case refused(String)
        case unreachable
    }

    private static let endpoint = URL(string: "https://web-lovat-nine-49.vercel.app/api/traders?view=profile")!

    static func message(address: EthereumAddress, timestamp: Int64) -> String {
        "Desk profile\n\(address.checksummed.lowercased())\n\(timestamp)"
    }

    static func deleteMessage(address: EthereumAddress, timestamp: Int64) -> String {
        "Delete Desk profile\n\(address.checksummed.lowercased())\n\(timestamp)"
    }

    static func delete(address: EthereumAddress, sign: @Sendable (Data) async throws -> EthereumSignature) async throws {
        let timestamp = Int64(Date.now.timeIntervalSince1970 * 1000)
        let signature = try await sign(PersonalMessage.digest(deleteMessage(address: address, timestamp: timestamp)))
        let payload: [String: Any] = [
            "action": "delete",
            "address": address.checksummed,
            "timestamp": timestamp,
            "signature": "0x" + signature.serialized.map { String(format: "%02x", $0) }.joined(),
        ]
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { throw Failure.unreachable }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let reason = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw Failure.refused(reason ?? "The profile could not be deleted.")
        }
    }

    /// `image` nil keeps the current picture; empty removes it.
    static func save(
        address: EthereumAddress, name: String, image: Data?,
        sign: @Sendable (Data) async throws -> EthereumSignature
    ) async throws -> Saved {
        let timestamp = Int64(Date.now.timeIntervalSince1970 * 1000)
        let signature = try await sign(PersonalMessage.digest(message(address: address, timestamp: timestamp)))
        var payload: [String: Any] = [
            "address": address.checksummed,
            "name": name,
            "timestamp": timestamp,
            "signature": "0x" + signature.serialized.map { String(format: "%02x", $0) }.joined(),
        ]
        if let image { payload["image"] = image.base64EncodedString() }
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { throw Failure.unreachable }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let reason = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw Failure.refused(reason ?? "The profile could not be saved.")
        }
        struct Envelope: Decodable { let profile: Saved }
        return try JSONDecoder().decode(Envelope.self, from: data).profile
    }
}
