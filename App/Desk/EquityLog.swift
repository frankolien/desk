import DeskMoney
import Foundation

/// What this account was worth, sampled on the phone as Profile saw it.
///
/// Perpl publishes no equity history, so the line on Profile is drawn from what this
/// device has observed: one point every ten minutes at most, kept for thirty days, per
/// network and address. It starts as a single dot and becomes a line by being used.
enum EquityLog {
    struct Point: Codable, Hashable, Sendable {
        let at: Date
        let raw: Int64
    }

    private static let minimumGap: TimeInterval = 600
    private static let keep: TimeInterval = 30 * 86_400

    private static func key(_ network: String, _ address: String) -> String {
        "desk.equity.\(network).\(address.lowercased())"
    }

    static func points(network: String, address: String) -> [Point] {
        guard let data = UserDefaults.standard.data(forKey: key(network, address)),
              let points = try? JSONDecoder().decode([Point].self, from: data) else { return [] }
        return points
    }

    static func record(_ total: Money, network: String, address: String, now: Date = .now) {
        var points = self.points(network: network, address: address)
        if let last = points.last, now.timeIntervalSince(last.at) < minimumGap, last.raw == total.raw { return }
        if let last = points.last, now.timeIntervalSince(last.at) < minimumGap {
            points[points.count - 1] = Point(at: now, raw: total.raw)
        } else {
            points.append(Point(at: now, raw: total.raw))
        }
        points.removeAll { now.timeIntervalSince($0.at) > keep }
        if let data = try? JSONEncoder().encode(points) {
            UserDefaults.standard.set(data, forKey: key(network, address))
        }
    }

    static func forget(network: String, address: String) {
        UserDefaults.standard.removeObject(forKey: key(network, address))
    }
}
