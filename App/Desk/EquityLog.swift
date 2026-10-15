import DeskMoney
import Foundation

/// Perpl publishes no equity history, so Profile's line is sampled on this device: at most one point
/// every ten minutes, kept for a year, per network and address.
enum EquityLog {
    struct Point: Codable, Hashable, Sendable {
        let at: Date
        let raw: Int64
        let pnlRaw: Int64?
    }

    private static let minimumGap: TimeInterval = 600
    private static let keep: TimeInterval = 365 * 86_400

    /// v2 counts open positions at their value; v1 points left them out, so a v1 history would
    /// show every open trade as a drop and its margin as a gain the day this changed.
    private static func key(_ network: String, _ address: String) -> String {
        "desk.equity.v2.\(network).\(address.lowercased())"
    }

    private static func legacyKey(_ network: String, _ address: String) -> String {
        "desk.equity.\(network).\(address.lowercased())"
    }

    static func points(network: String, address: String) -> [Point] {
        guard let data = UserDefaults.standard.data(forKey: key(network, address)),
              let points = try? JSONDecoder().decode([Point].self, from: data) else { return [] }
        return points
    }

    static func record(
        _ total: Money,
        pnl: Money? = nil,
        network: String,
        address: String,
        now: Date = .now
    ) {
        var points = self.points(network: network, address: address)
        if let last = points.last,
           now.timeIntervalSince(last.at) < minimumGap,
           last.raw == total.raw,
           last.pnlRaw == pnl?.raw { return }
        if let last = points.last, now.timeIntervalSince(last.at) < minimumGap {
            points[points.count - 1] = Point(at: now, raw: total.raw, pnlRaw: pnl?.raw)
        } else {
            points.append(Point(at: now, raw: total.raw, pnlRaw: pnl?.raw))
        }
        points.removeAll { now.timeIntervalSince($0.at) > keep }
        if let data = try? JSONEncoder().encode(points) {
            UserDefaults.standard.set(data, forKey: key(network, address))
            UserDefaults.standard.removeObject(forKey: legacyKey(network, address))
        }
    }

    static func forget(network: String, address: String) {
        UserDefaults.standard.removeObject(forKey: key(network, address))
        UserDefaults.standard.removeObject(forKey: legacyKey(network, address))
    }
}
