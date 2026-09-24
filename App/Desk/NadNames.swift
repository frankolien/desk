import DeskAuth
import DeskChain
import Foundation
import Observation

/// One .nad name a wallet holds, with the records it carries.
struct NadName: Decodable, Identifiable, Hashable, Sendable {
    let name: String
    let label: String
    let isPrimary: Bool
    let records: [String: String]
    var id: String { label }
}

/// Whether a label can be had, and what it costs. Prices are one-time.
struct NadNameStatus: Decodable, Hashable, Sendable {
    let name: String
    let label: String
    let available: Bool
    let reserved: Bool
    let priceMON: String
    let priceUSDC: String?
    let owner: String?
    let records: [String: String]?

    var priceWei: NativeAmount? { NativeAmount(decimalText: priceMON) }
}

/// A transaction nad's contracts want, built by Desk's server and checked here before
/// the wallet key sees it: only the two pinned nad contracts, and only the quoted value.
struct NadCall: Decodable, Sendable {
    let to: String
    let value: String
    let data: String
    var priceMON: String? = nil

    static let nameService = "cc7a1bff8845573dbf0b3b96e25b9b549d4a2ec7"
    static let controller = "e18a7550aa35895c87a1069d1b775fa275bc93fb"

    enum Failure: Error { case unknownContract, malformed }

    func checked(expectingValue expected: NativeAmount) throws -> (to: EthereumAddress, data: Data, value: NativeAmount) {
        let target = to.lowercased().replacingOccurrences(of: "0x", with: "")
        guard target == Self.nameService || target == Self.controller,
              let address = Self.bytes(target).flatMap(EthereumAddress.init(bytes:)) else { throw Failure.unknownContract }
        guard let calldata = Self.bytes(data.lowercased().replacingOccurrences(of: "0x", with: "")), calldata.count >= 4,
              value.allSatisfy({ $0.isASCII && $0.isNumber }), value == expected.weiText else { throw Failure.malformed }
        return (address, calldata, expected)
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

/// Desk's server in front of Nad Name Service: reads from the chain, calldata for writes.
@MainActor
@Observable
final class NadNamesModel {
    private struct Owned: Decodable { let primary: String?; let names: [NadName] }
    private struct ServerError: Decodable { let error: String; let reason: String? }

    enum Failure: Error { case refused(String), unreachable, notOpen }

    private(set) var names: [NadName] = []
    private(set) var primary: String?
    private(set) var loaded = false
    private(set) var status: NadNameStatus?
    private(set) var isChecking = false
    private(set) var checkProblem: String?

    private static let endpoint = "https://web-lovat-nine-49.vercel.app/api/traders"

    static func isValidLabel(_ text: String) -> Bool {
        let label = text.lowercased()
        return (1...32).contains(label.count) && !label.hasPrefix("-") && !label.hasSuffix("-")
            && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    func load(address: String) async {
        var components = URLComponents(string: Self.endpoint)!
        components.queryItems = [URLQueryItem(name: "view", value: "nad"), URLQueryItem(name: "address", value: address)]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let owned = try? JSONDecoder().decode(Owned.self, from: data) else { loaded = true; return }
        names = owned.names
        primary = owned.primary
        loaded = true
    }

    /// Availability and price for a typed label, debounced by the caller.
    func check(_ label: String) async {
        checkProblem = nil
        guard Self.isValidLabel(label) else { status = nil; return }
        isChecking = true
        defer { isChecking = false }
        var components = URLComponents(string: Self.endpoint)!
        components.queryItems = [URLQueryItem(name: "view", value: "nad-name"), URLQueryItem(name: "name", value: label.lowercased())]
        guard let url = components.url, let (data, response) = try? await URLSession.shared.data(from: url) else {
            checkProblem = "Nad could not be reached."
            return
        }
        guard !Task.isCancelled else { return }
        if (response as? HTTPURLResponse)?.statusCode == 200, let found = try? JSONDecoder().decode(NadNameStatus.self, from: data) {
            status = found
        } else {
            status = nil
            checkProblem = (try? JSONDecoder().decode(ServerError.self, from: data))?.error ?? "Nad could not be read right now."
        }
    }

    func clearCheck() { status = nil; checkProblem = nil }

    /// Calldata for a write to a name this wallet owns.
    func calldata(_ body: [String: Any]) async throws -> NadCall {
        try await post(view: "nad-calldata", body: body)
    }

    /// The registration transaction, once nad has co-signed the request.
    func registration(label: String, owner: String, attributes: [String: String]) async throws -> NadCall {
        let list = attributes.filter { !$0.value.isEmpty }.map { ["key": $0.key, "value": $0.value] }
        return try await post(view: "nad-register", body: ["name": label, "owner": owner, "setAsPrimary": true, "attributes": list])
    }

    private func post(view: String, body: [String: Any]) async throws -> NadCall {
        var request = URLRequest(url: URL(string: "\(Self.endpoint)?view=\(view)")!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { throw Failure.unreachable }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let error = try? JSONDecoder().decode(ServerError.self, from: data)
            if error?.reason == "not-configured" { throw Failure.notOpen }
            throw Failure.refused(error?.error ?? "Nad refused the request.")
        }
        return try JSONDecoder().decode(NadCall.self, from: data)
    }
}
