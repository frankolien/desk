import DeskPerpl
import Foundation
import Observation

struct ClosedTrade: Codable, Identifiable, Hashable, Sendable {
    let positionID: Int64
    let marketID: UInt32
    let isLong: Bool
    let leverageHundredths: Int
    let entryRaw: Int64
    let exitRaw: Int64?
    let realisedPnLRaw: Int64?
    let sizeRaw: Int64
    let collateralRaw: Int64
    let feeRaw: Int64
    let closedAt: Date

    var id: Int64 { positionID }

    init(position: PerplPosition, closedAt: Date = .now) {
        positionID = position.positionID
        marketID = position.marketID
        isLong = position.side == .long
        leverageHundredths = position.leverageHundredths
        entryRaw = position.entryRaw
        exitRaw = position.exitRaw
        realisedPnLRaw = position.realisedPnLRaw
        sizeRaw = position.sizeRaw
        collateralRaw = position.collateralRaw
        feeRaw = position.feeRaw
        self.closedAt = closedAt
    }
}

@MainActor
@Observable
final class ClosedPositionsStore {
    static let shared = ClosedPositionsStore()
    private static let limit = 500

    private var byAccount: [String: [ClosedTrade]]
    private let file: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        file = base.appending(path: "closed-positions.json")
        if let data = try? Data(contentsOf: file),
           let stored = try? JSONDecoder().decode([String: [ClosedTrade]].self, from: data) {
            byAccount = stored
        } else {
            byAccount = [:]
        }
    }

    private static func key(network: String, address: String) -> String { "\(network):\(address.lowercased())" }

    func trades(network: String, address: String) -> [ClosedTrade] {
        (byAccount[Self.key(network: network, address: address)] ?? []).sorted { $0.positionID > $1.positionID }
    }

    func record(_ positions: [PerplPosition], network: String, address: String) {
        let closed = positions.filter { !$0.isOpen }
        guard !closed.isEmpty else { return }
        let key = Self.key(network: network, address: address)
        var known = byAccount[key] ?? []
        var changed = false
        for position in closed {
            if let index = known.firstIndex(where: { $0.positionID == position.positionID }) {
                let refreshed = ClosedTrade(position: position, closedAt: known[index].closedAt)
                if refreshed != known[index] { known[index] = refreshed; changed = true }
            } else {
                known.append(ClosedTrade(position: position, closedAt: position.updatedAt ?? .now))
                changed = true
            }
        }
        guard changed else { return }
        byAccount[key] = Array(known.sorted { $0.positionID > $1.positionID }.prefix(Self.limit))
        persist()
    }

    func forget(address: String) {
        let suffix = ":\(address.lowercased())"
        let before = byAccount.count
        byAccount = byAccount.filter { !$0.key.hasSuffix(suffix) }
        if byAccount.count != before { persist() }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(byAccount) {
            try? data.write(to: file, options: [.atomic, .completeFileProtection])
        }
    }
}
