import Foundation

/// Reports and blocks for what other people write and show. A block is this phone's own
/// and takes effect at once; a report goes to Desk's server, where three phones agreeing
/// hides the thing and repeat offenders lose the rooms.
@MainActor
enum Moderation {
    private static let host = "https://web-lovat-nine-49.vercel.app"
    private static let blockedKey = "desk.chat.blocked"

    /// Posters this phone has blocked, by the same hash the rooms use.
    private(set) static var blockedWhos: Set<String> = Set(UserDefaults.standard.stringArray(forKey: blockedKey) ?? [])

    static func block(_ who: String) {
        blockedWhos.insert(who)
        UserDefaults.standard.set(Array(blockedWhos).sorted(), forKey: blockedKey)
    }

    static func unblock(_ who: String) {
        blockedWhos.remove(who)
        UserDefaults.standard.set(Array(blockedWhos).sorted(), forKey: blockedKey)
    }

    @discardableResult
    static func reportMessage(_ message: ChatMessage, market: String) async -> Bool {
        guard let install = InstallSecret.value() else { return false }
        return await post("/api/activity?view=chat-report",
                          ["install": install, "market": market, "id": message.id, "who": message.who])
    }

    @discardableResult
    static func reportProfile(_ address: String) async -> Bool {
        guard let install = InstallSecret.value() else { return false }
        return await post("/api/traders?view=profile-report", ["install": install, "address": address])
    }

    private static func post(_ path: String, _ payload: [String: String]) async -> Bool {
        guard let url = URL(string: host + path) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}
