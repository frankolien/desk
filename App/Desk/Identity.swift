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
        case "desk": "Desk"
        case "nad": "Nad Name Service"
        case "nadfun": "nad.fun"
        case "ens": "ENS"
        case "sns": "Solana Name Service"
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
    enum NameResult {
        case wallet(address: String, identity: Identity?)
        case solana(name: String, address: String)
        case notFound
        case unavailable
    }
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

    private func key(for address: String) -> String { address.hasPrefix("0x") ? address.lowercased() : address }

    func identity(for address: String) -> Identity? { identities[key(for: address)] }
    func name(for address: String) -> String? { identity(for: address)?.name }

    @discardableResult
    func rememberSolana(name: String, address: String) -> Identity {
        let identity = Identity(address: address, name: name, source: "sns", avatar: nil,
                                bio: nil, x: nil, farcaster: nil, perplAccount: nil)
        identities[address] = identity
        fetchedAt[address] = .now
        persist()
        return identity
    }

    /// Forgets what is held for one address and asks the server for a fresh answer,
    /// past its own cache: what a person just changed about themselves should show now.
    func refresh(_ address: String) async {
        let key = key(for: address)
        fetchedAt[key] = nil
        pinned.remove(key)
        await resolve([key], fresh: true)
    }

    func resolve(_ addresses: [String], fresh: Bool = false) async {
        let now = Date.now
        var wanted: [String] = []
        var seen: Set<String> = []
        for raw in addresses {
            let address = key(for: raw)
            let evm = address.count == 42 && address.hasPrefix("0x")
            guard (evm || TrackedWallets.isSolana(address)), seen.insert(address).inserted,
                  !inFlight.contains(address) else { continue }
            if !fresh, let at = fetchedAt[address], now.timeIntervalSince(at) < Self.maxAge { continue }
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
            if fresh { components.queryItems?.append(URLQueryItem(name: "fresh", value: "1")) }
            guard let url = components.url,
                  let (data, _) = try? await ResponseCache.shared.data(from: url, maxStale: fresh ? 0 : 3_600),
                  let body = try? JSONDecoder().decode(Response.self, from: data) else { continue }
            for (address, identity) in body.identities where !pinned.contains(key(for: address)) {
                let key = key(for: address)
                // A searched .sol name may not be the owner's primary domain. Do not
                // replace that verified forward lookup with an empty reverse result.
                if identity.name == nil, identities[key]?.source == "sns", identities[key]?.name != nil {
                    fetchedAt[key] = now
                    continue
                }
                identities[key] = identity
                fetchedAt[key] = now
            }
        }
        persist()
    }

    private struct LookupResponse: Decodable {
        let address: String?
        let identity: Identity?
        let name: String?
        let chain: String?
    }

    private struct SNSResponse: Decodable {
        let s: String
        let result: String?
    }

    private func lookupSNS(_ query: String) async -> NameResult {
        let name = query.lowercased().hasSuffix(".solana")
            ? String(query.dropLast(".solana".count)) + ".sol" : query
        guard let url = URL(string: "https://sdk-proxy-v2.sns.id/resolve/")?.appendingPathComponent(name) else {
            return .unavailable
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let status = (response as? HTTPURLResponse)?.statusCode else { return .unavailable }
            if status == 404 { return .notFound }
            guard status == 200, let body = try? JSONDecoder().decode(SNSResponse.self, from: data) else {
                return .unavailable
            }
            guard body.s == "ok", let address = body.result,
                  (32...44).contains(address.count),
                  address.rangeOfCharacter(from: CharacterSet(charactersIn: "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz").inverted) == nil else {
                return .notFound
            }
            return .solana(name: name, address: address)
        } catch {
            return .unavailable
        }
    }

    /// A typed blockchain name may resolve to either an EVM or Solana address.
    func lookup(_ query: String) async -> NameResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return .notFound }
        if TrackedWallets.isSolana(trimmed) { return .solana(name: trimmed, address: trimmed) }
        if TrackedWallets.isEVM(trimmed) {
            return .wallet(address: trimmed.lowercased(), identity: identity(for: trimmed))
        }
        // SNS names resolve independently of the EVM identity API. Keep this
        // working even while an older Desk server deployment is still live.
        let lower = trimmed.lowercased()
        if lower.hasSuffix(".sol") || lower.hasSuffix(".solana") || lower.hasSuffix(".sns") {
            return await lookupSNS(trimmed)
        }
        var components = URLComponents(string: Self.endpoint)!
        components.queryItems = [URLQueryItem(name: "view", value: "lookup"), URLQueryItem(name: "q", value: trimmed)]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              let status = (response as? HTTPURLResponse)?.statusCode else { return .unavailable }
        if status == 404 { return .notFound }
        guard status == 200,
              let body = try? JSONDecoder().decode(LookupResponse.self, from: data),
              let address = body.address else { return .unavailable }
        if body.chain == "solana" {
            return .solana(name: body.name ?? trimmed, address: address)
        }
        if let identity = body.identity {
            identities[address.lowercased()] = identity
            fetchedAt[address.lowercased()] = .now
            persist()
        }
        return .wallet(address: address, identity: body.identity)
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
