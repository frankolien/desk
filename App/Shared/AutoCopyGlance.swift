import ActivityKit
import Foundation

/// The App Group Desk shares with its widgets, Live Activity and controls.
enum DeskGroup {
    static let identifier = "group.com.opia.desk"
    static var defaults: UserDefaults { UserDefaults(suiteName: identifier) ?? .standard }
}

/// Auto-copy's on/off switch, readable and writable from outside Desk: Siri, Shortcuts,
/// Control Center and the widget's button all set it, and the copy loop reads it every tick.
enum AutoCopySwitch {
    private static let key = "desk.copy.paused"

    static var isPaused: Bool {
        get { DeskGroup.defaults.bool(forKey: key) }
        set { DeskGroup.defaults.set(newValue, forKey: key) }
    }
}

/// What auto-copy is doing, as the app last wrote it for surfaces outside the app.
struct AutoCopyGlance: Codable, Hashable, Sendable {
    struct Move: Codable, Hashable, Sendable, Identifiable {
        enum Kind: String, Codable, Sendable { case opened, closed }

        let id: UUID
        let date: Date
        let trader: String
        let symbol: String
        let isLong: Bool
        let kind: Kind
        let leverage: Int?
        let pnl: Double?

        var sideWord: String { isLong ? "Long" : "Short" }
    }

    var traders: Int
    var openCopies: Int
    var today: Double
    var realised: Double
    var closedTrades: Int
    var winRate: Double?
    var isShadow: Bool
    var moves: [Move]
    var updatedAt: Date

    var isSetUp: Bool { traders > 0 || openCopies > 0 }

    private static let key = "desk.copy.glance"

    static func load() -> AutoCopyGlance? {
        DeskGroup.defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(AutoCopyGlance.self, from: $0) }
    }

    func save() {
        DeskGroup.defaults.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }

    /// Signing out. The widget and the Live Activity read this, so leaving it behind shows
    /// the previous account's traders and result on the Lock Screen of whoever signs in next.
    static func forget() {
        DeskGroup.defaults.removeObject(forKey: key)
    }

    static func money(_ value: Double, signed: Bool = true) -> String {
        let magnitude = abs(value)
        let digits = magnitude >= 1_000 ? String(format: "%.1fK", magnitude / 1_000) : String(format: "%.2f", magnitude)
        guard signed else { return "$" + digits }
        return (value < 0 ? "\u{2212}$" : "+$") + digits
    }

    static let preview = AutoCopyGlance(
        traders: 3, openCopies: 2, today: 14.62, realised: 131.4, closedTrades: 22, winRate: 0.64, isShadow: false,
        moves: [
            Move(id: UUID(), date: .now.addingTimeInterval(-120), trader: "Whale", symbol: "ETH", isLong: true,
                 kind: .opened, leverage: 5, pnl: nil),
            Move(id: UUID(), date: .now.addingTimeInterval(-2_400), trader: "0x8310…E1a2", symbol: "BTC", isLong: false,
                 kind: .closed, leverage: 3, pnl: 3.12),
            Move(id: UUID(), date: .now.addingTimeInterval(-7_200), trader: "Whale", symbol: "SOL", isLong: true,
                 kind: .closed, leverage: 4, pnl: -1.4),
        ],
        updatedAt: .now)
}

/// Auto-copy on the Lock Screen and in the Dynamic Island while Desk is copying.
struct AutoCopyActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var today: Double
        var openCopies: Int
        var traders: Int
        var isPaused: Bool
        var isStreaming: Bool
        var isShadow: Bool
        var lastMove: AutoCopyGlance.Move?
    }
}
