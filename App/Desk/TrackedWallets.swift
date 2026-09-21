import Foundation
import Observation

struct TrackedWallet: Codable, Identifiable, Hashable, Sendable {
    let address: String
    var name: String
    var minUsd: Double
    var firstBuysOnly: Bool

    var id: String { address.lowercased() }
    var shortAddress: String { address.count > 12 ? "\(address.prefix(6))…\(address.suffix(4))" : address }
    var displayName: String { name.isEmpty ? shortAddress : name }
}

/// Wallets this phone wants to hear about. The list lives here; the server only sees
/// it as part of the alert subscription, the same way followed traders do.
@MainActor
@Observable
final class TrackedWallets {
    static let shared = TrackedWallets()
    static let limit = 25
    private static let key = "desk.tracked"

    private(set) var list: [TrackedWallet]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode([TrackedWallet].self, from: data) {
            list = stored
        } else {
            list = []
        }
    }

    var isFull: Bool { list.count >= Self.limit }

    func isTracking(_ address: String) -> Bool { list.contains { $0.id == address.lowercased() } }

    func wallet(for address: String) -> TrackedWallet? { list.first { $0.id == address.lowercased() } }

    @discardableResult
    func track(_ address: String, name: String = "") -> Bool {
        guard !isTracking(address), !isFull, Self.isValid(address) else { return false }
        list.append(TrackedWallet(address: address, name: String(name.prefix(24)), minUsd: 250, firstBuysOnly: false))
        persist()
        return true
    }

    func untrack(_ address: String) {
        list.removeAll { $0.id == address.lowercased() }
        persist()
    }

    func update(_ wallet: TrackedWallet) {
        guard let index = list.firstIndex(where: { $0.id == wallet.id }) else { return }
        list[index] = wallet
        persist()
    }

    var payload: [[String: Any]] {
        list.map { ["address": $0.address.lowercased(), "name": $0.name, "minUsd": $0.minUsd, "firstBuysOnly": $0.firstBuysOnly] }
    }

    static func isValid(_ address: String) -> Bool {
        address.count == 42 && address.hasPrefix("0x") && address.dropFirst(2).allSatisfy(\.isHexDigit)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: Self.key) }
        TradeAlerts.shared.trackingChanged()
    }
}

/// A token someone asked to see from somewhere that cannot show it — a push, a signal
/// row. The search tab picks it up and opens it.
@MainActor
@Observable
final class TokenOpenRequest {
    struct Target: Equatable, Sendable {
        let chainIndex: String
        let contract: String
        var symbol: String? = nil
    }

    static let shared = TokenOpenRequest()
    private(set) var pending: Target?

    func open(_ target: Target) { pending = target }

    func take() -> Target? {
        defer { pending = nil }
        return pending
    }
}

/// A perp market a push asked to see. The perps tab picks it up and opens it.
@MainActor
@Observable
final class MarketOpenRequest {
    static let shared = MarketOpenRequest()
    private(set) var pending: String?

    func open(_ symbol: String) { pending = symbol.uppercased() }

    func take() -> String? {
        defer { pending = nil }
        return pending
    }
}
