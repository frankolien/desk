import Foundation
import Observation

struct Identity: Codable, Hashable, Sendable {
    let address: String
    let name: String?
    let source: String?
    let avatar: String?
    let bio: String?
    let x: String?
    let farcaster: String?
    let perplAccount: String?

    var avatarURL: URL? { avatar.flatMap(URL.init(string:)) }
    var isEmpty: Bool { name == nil && avatar == nil && perplAccount == nil }

    var sourceLabel: String? {
        switch source {
        case "nad": "Nad Name Service"
        case "nadfun": "nad.fun"
        case "ens": "ENS"
        case "farcaster": "Farcaster"
        default: nil
        }
    }

    var profileURL: URL? {
        switch source {
        case "nad": URL(string: "https://app.nad.domains/name/\(name ?? "")")
        case "nadfun": URL(string: "https://nad.fun/profile/\(address)")
        case "ens": URL(string: "https://app.ens.domains/\(name ?? "")")
        case "farcaster": farcaster.flatMap { URL(string: "https://warpcast.com/\($0)") }
        default: nil
        }
    }

    var xURL: URL? { x.flatMap { URL(string: "https://x.com/\($0)") } }
}

/// Names for wallets, resolved once a day through the server and kept on disk, so a
/// holder list or leaderboard shows the same faces it showed last time before the
/// network answers.
@MainActor
@Observable
final class IdentityDirectory {
    static let shared = IdentityDirectory()

    private(set) var identities: [String: Identity] = [:]
    private var fetchedAt: [String: Date] = [:]
    private var inFlight: Set<String> = []
    private var pinned: Set<String> = []

    private static let endpoint = "https://web-lovat-nine-49.vercel.app/api/traders"
    private static let maxAge: TimeInterval = 86_400
    private static let batch = 50

    private struct Entry: Codable { let identity: Identity; let at: Date }
    private struct Response: Decodable { let identities: [String: Identity] }

    private static var file: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("desk.identities.json")
    }

    init() {
        guard let data = try? Data(contentsOf: Self.file),
              let stored = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        for (address, entry) in stored {
            identities[address] = entry.identity
            fetchedAt[address] = entry.at
        }
    }

    func identity(for address: String) -> Identity? { identities[address.lowercased()] }
    func name(for address: String) -> String? { identity(for: address)?.name }

    func resolve(_ addresses: [String]) async {
        let now = Date.now
        var wanted: [String] = []
        var seen: Set<String> = []
        for raw in addresses {
            let address = raw.lowercased()
            guard address.count == 42, address.hasPrefix("0x"), seen.insert(address).inserted,
                  !inFlight.contains(address) else { continue }
            if let at = fetchedAt[address], now.timeIntervalSince(at) < Self.maxAge { continue }
            wanted.append(address)
        }
        guard !wanted.isEmpty else { return }
        inFlight.formUnion(wanted)
        defer { inFlight.subtract(wanted) }

        for start in stride(from: 0, to: wanted.count, by: Self.batch) {
            let chunk = Array(wanted[start..<min(start + Self.batch, wanted.count)]).sorted()
            var components = URLComponents(string: Self.endpoint)!
            components.queryItems = [
                URLQueryItem(name: "view", value: "identity"),
                URLQueryItem(name: "addresses", value: chunk.joined(separator: ",")),
            ]
            guard let url = components.url,
                  let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let body = try? JSONDecoder().decode(Response.self, from: data) else { continue }
            for (address, identity) in body.identities where !pinned.contains(address.lowercased()) {
                identities[address.lowercased()] = identity
                fetchedAt[address.lowercased()] = now
            }
        }
        persist()
    }

    private struct LookupResponse: Decodable { let address: String; let identity: Identity? }

    /// A typed name to a wallet: .nad, .eth, @farcaster, or an address as itself.
    func lookup(_ query: String) async -> (address: String, identity: Identity?)? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return nil }
        var components = URLComponents(string: Self.endpoint)!
        components.queryItems = [URLQueryItem(name: "view", value: "lookup"), URLQueryItem(name: "q", value: trimmed)]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try? JSONDecoder().decode(LookupResponse.self, from: data) else { return nil }
        if let identity = body.identity {
            identities[body.address.lowercased()] = identity
            fetchedAt[body.address.lowercased()] = .now
            persist()
        }
        return (body.address, body.identity)
    }

    /// Names already on this phone that contain the text, for instant matches.
    func matches(_ query: String, limit: Int = 3) -> [Identity] {
        let wanted = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard wanted.count >= 2 else { return [] }
        return Array(identities.values.filter { ($0.name ?? "").lowercased().contains(wanted) }.prefix(limit))
    }

    private func persist() {
        var stored: [String: Entry] = [:]
        for (address, identity) in identities {
            stored[address] = Entry(identity: identity, at: fetchedAt[address] ?? .now)
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: Self.file, options: .atomic)
    }

    #if DEBUG
    func seedForReview(_ address: String, name: String, source: String, avatar: String?, bio: String? = nil, x: String? = nil) {
        identities[address.lowercased()] = Identity(address: address.lowercased(), name: name, source: source,
                                                    avatar: avatar, bio: bio, x: x, farcaster: nil, perplAccount: nil)
        fetchedAt[address.lowercased()] = .now
        pinned.insert(address.lowercased())
    }
    #endif
}
