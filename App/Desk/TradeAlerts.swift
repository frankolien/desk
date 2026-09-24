import Foundation
import Observation
import Security
import UIKit
import UserNotifications

/// A followed trader's move, as delivered by a push and opened by a tap.
struct TradeAlert: Identifiable, Hashable, Sendable {
    enum Event: String, Sendable { case opened, flipped, added, closed }

    let event: Event
    let trader: String
    let market: String
    let side: String
    let leverage: Double?
    let entry: String
    let value: String
    let observedAt: Date

    var id: String { "\(trader)-\(market)-\(event.rawValue)-\(observedAt.timeIntervalSince1970)" }
    var isLong: Bool { side == "long" }
    var canCopy: Bool { event != .closed }

    init?(userInfo: [AnyHashable: Any]) {
        guard let desk = userInfo["desk"] as? [String: Any], desk["type"] as? String == "trade",
              let event = (desk["event"] as? String).flatMap(Event.init(rawValue:)),
              let trader = desk["trader"] as? String,
              let market = desk["market"] as? String,
              let side = desk["side"] as? String else { return nil }
        self.init(event: event, trader: trader, market: market, side: side,
                  leverage: (desk["leverage"] as? NSNumber)?.doubleValue,
                  entry: desk["entry"] as? String ?? "", value: desk["value"] as? String ?? "",
                  observedAt: (desk["observedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } ?? .now)
    }

    init(event: Event, trader: String, market: String, side: String, leverage: Double?,
         entry: String, value: String, observedAt: Date) {
        self.event = event
        self.trader = trader
        self.market = market
        self.side = side
        self.leverage = leverage
        self.entry = entry
        self.value = value
        self.observedAt = observedAt
    }
}

@MainActor
@Observable
final class TradeAlerts {
    enum Permission: Equatable { case undetermined, allowed, denied }

    static let shared = TradeAlerts()

    private(set) var alerted: [String]
    private(set) var permission: Permission = .undetermined
    /// Set when the server could not be told, so the switch never claims more than is true.
    var problem: String?
    /// The alert the person tapped, waiting for the trading shell to open it.
    var opened: TradeAlert?
    /// Whether it was opened with the notification's Copy button, which goes straight to
    /// the ticket instead of the alert sheet.
    var openedToCopy = false

    private var deviceToken: String?
    private var confirmOnSync = false
    private var syncTask: Task<Void, Never>?
    /// Something changed on this phone that the server has not heard yet. Cleared by a
    /// successful sync, retried on the next foreground; never a dialog by itself.
    private var needsSync = false
    private var registrationRetry: Task<Void, Never>?

    private static let storageKey = "desk.alertedTraders"
    private static let pricesKey = "desk.alerts.prices"
    /// Levels broken and big days on every Perpl market. On unless switched off.
    private(set) var priceAlerts = UserDefaults.standard.object(forKey: "desk.alerts.prices") == nil
        || UserDefaults.standard.bool(forKey: "desk.alerts.prices")
    private static let nicknameKey = "desk.traderNicknames"
    private static let primerKey = "desk.alertsPrimerShown"
    private static let endpoint = URL(string: "https://web-lovat-nine-49.vercel.app/api/alerts")!
    private static let tokenKey = "desk.alertsDeviceToken"

    nonisolated static let copyAction = "desk.copy"
    nonisolated static let viewAction = "desk.view"
    nonisolated static let muteAction = "desk.mute"

    private init() {
        alerted = UserDefaults.standard.stringArray(forKey: Self.storageKey) ?? []
        // Cached so a Mute pressed from the lock screen can reach the server before iOS
        // hands a background launch a fresh token.
        deviceToken = UserDefaults.standard.string(forKey: Self.tokenKey)
    }

    /// The buttons a trade alert carries when pressed and held.
    static func registerCategories() {
        let copy = UNNotificationAction(
            identifier: copyAction, title: "Copy Trade", options: [.foreground, .authenticationRequired],
            icon: UNNotificationActionIcon(systemImageName: "doc.on.doc"))
        let view = UNNotificationAction(
            identifier: viewAction, title: "View Trader", options: [.foreground],
            icon: UNNotificationActionIcon(systemImageName: "person.crop.circle"))
        let mute = UNNotificationAction(
            identifier: muteAction, title: "Mute This Trader", options: [.destructive, .authenticationRequired],
            icon: UNNotificationActionIcon(systemImageName: "bell.slash"))
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: "desk.trade", actions: [copy, view, mute], intentIdentifiers: []),
            UNNotificationCategory(identifier: "desk.trade.closed", actions: [view, mute], intentIdentifiers: []),
        ])
    }

    var hasSeenPrimer: Bool {
        get { UserDefaults.standard.bool(forKey: Self.primerKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.primerKey) }
    }

    func isOn(for address: String) -> Bool {
        alerted.contains { $0.caseInsensitiveCompare(address) == .orderedSame }
    }

    func refreshPermission() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        permission = switch status {
        case .notDetermined: .undetermined
        case .denied: .denied
        default: .allowed
        }
    }

    /// Re-registers on launch and on every return to the foreground, which also refreshes
    /// the server's copy before it expires and catches up on anything unsynced.
    func resume() async {
        await refreshPermission()
        // A silent wake needs a token but no permission, so copying registers regardless.
        let wantsAlerts = !alerted.isEmpty || priceAlerts || !TrackedWallets.shared.list.isEmpty
        guard (permission == .allowed && wantsAlerts) || !copying.isEmpty else { return }
        UIApplication.shared.registerForRemoteNotifications()
        if needsSync, deviceToken != nil { scheduleSync() }
    }

    /// Asks iOS if it has not been asked; false when notifications are off for Desk.
    @discardableResult
    func setPriceAlerts(_ on: Bool) async -> Bool {
        if on {
            let center = UNUserNotificationCenter.current()
            if await center.notificationSettings().authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            }
            await refreshPermission()
            guard permission == .allowed else { return false }
        }
        priceAlerts = on
        UserDefaults.standard.set(on, forKey: Self.pricesKey)
        if on { UIApplication.shared.registerForRemoteNotifications() }
        scheduleSync()
        return true
    }

    /// Asks iOS if it has not been asked, then watches the trader. False when notifications
    /// are off for Desk, which only Settings can change.
    @discardableResult
    func turnOn(for address: String) async -> Bool {
        let center = UNUserNotificationCenter.current()
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        await refreshPermission()
        guard permission == .allowed else { return false }
        guard !isOn(for: address) else { return true }
        confirmOnSync = confirmOnSync || alerted.isEmpty
        alerted.append(address)
        persist()
        UIApplication.shared.registerForRemoteNotifications()
        if deviceToken != nil { scheduleSync() }
        return true
    }

    func turnOff(for address: String) {
        guard isOn(for: address) else { return }
        alerted.removeAll { $0.caseInsensitiveCompare(address) == .orderedSame }
        persist()
        scheduleSync()
    }

    /// Mute from a notification, where Desk may only be awake for a few seconds: the
    /// server is told before this returns.
    func mute(_ address: String) async {
        guard isOn(for: address) else { return }
        alerted.removeAll { $0.caseInsensitiveCompare(address) == .orderedSame }
        persist()
        syncTask?.cancel()
        await sync()
    }

    /// Signing out: the server forgets the subscription, and so does this phone.
    ///
    /// The server holds the device token, the followed addresses and the names given to
    /// them for sixty days, refreshed on every launch. Nothing called this, so signing out
    /// left all of it in place and being renewed.
    func signOut() async {
        let hadSubscription = !alerted.isEmpty || !copying.isEmpty || priceAlerts || !TrackedWallets.shared.list.isEmpty
        alerted = []
        copying = []
        AutoCopyAway.isOn = false
        persist()
        syncTask?.cancel()
        if hadSubscription, let install = InstallSecret.value() {
            var request = URLRequest(url: Self.endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(
                withJSONObject: ["action": "unsubscribe", "install": install])
            _ = try? await URLSession.shared.data(for: request)
        }
        confirmOnSync = false
        problem = nil
        opened = nil
        openedToCopy = false
        for key in [Self.storageKey, Self.nicknameKey, Self.tokenKey, Self.primerKey, Self.copyingKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        deviceToken = nil
    }

    func didRegister(deviceToken data: Data) {
        registrationRetry?.cancel()
        let token = data.map { String(format: "%02x", $0) }.joined()
        deviceToken = token
        UserDefaults.standard.set(token, forKey: Self.tokenKey)
        scheduleSync()
    }

    /// Apple could not be reached for a token. The follow is already saved on this phone,
    /// so nothing is lost; iOS is asked again shortly, and again on the next foreground.
    func didFailToRegister() {
        needsSync = true
        registrationRetry?.cancel()
        registrationRetry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, self != nil else { return }
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func namesChanged() { if !alerted.isEmpty { scheduleSync() } }

    /// The perp markets on the watchlist, by symbol, for price alerts beyond Bitcoin and Monad.
    static var watchlistSymbols: [String] {
        let ids = UserDefaults.standard.string(forKey: "desk.watchlist")?.split(separator: ",").map(String.init) ?? []
        let symbols = UserDefaults.standard.dictionary(forKey: "desk.marketSymbols") as? [String: String] ?? [:]
        return ids.compactMap { symbols[$0] }.sorted()
    }

    func watchlistChanged() { if priceAlerts { scheduleSync() } }

    private static let lastSyncKey = "desk.alerts.lastSync"
    private(set) var lastSyncedAt: Date? = UserDefaults.standard.object(forKey: "desk.alerts.lastSync") as? Date

    private static let copyingKey = "desk.alerts.copying"
    private(set) var copying: [String] = UserDefaults.standard.stringArray(forKey: "desk.alerts.copying") ?? []

    /// The traders the copy loop wants to be woken for. A token is needed to be woken
    /// at all, and asking iOS for one shows no prompt.
    func setCopying(_ addresses: [String]) {
        guard addresses != copying else { return }
        copying = addresses
        UserDefaults.standard.set(addresses, forKey: Self.copyingKey)
        if deviceToken == nil, !addresses.isEmpty { UIApplication.shared.registerForRemoteNotifications() }
        scheduleSync()
    }

    /// Tracked wallets ride on the same subscription. Tracking one is a reason to hold a
    /// token even with no trader alerts on.
    func trackingChanged() {
        Task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-track-demo") { scheduleSync(); return }
            #endif
            if !TrackedWallets.shared.list.isEmpty {
                let center = UNUserNotificationCenter.current()
                if await center.notificationSettings().authorizationStatus == .notDetermined {
                    _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
                }
                await refreshPermission()
                if permission == .allowed {
                    // APNs tokens can rotate; ask iOS for the current one even if an
                    // older token was cached for a background mute operation.
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
            scheduleSync()
        }
    }

    private func persist() {
        UserDefaults.standard.set(alerted, forKey: Self.storageKey)
    }

    /// Changes made in quick succession go up as one request, in the order they were made.
    private func scheduleSync() {
        needsSync = true
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    private func sync() async {
        guard let deviceToken, let install = InstallSecret.value() else { return }
        needsSync = true
        let nicknames = UserDefaults.standard.dictionary(forKey: Self.nicknameKey) as? [String: String] ?? [:]
        let traders = alerted.map { $0.lowercased() }
        let confirm = confirmOnSync
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        let body: [String: Any] = [
            "install": install,
            "token": deviceToken,
            "environment": environment,
            "traders": traders,
            "names": nicknames.filter { traders.contains($0.key) },
            "copying": copying,
            "wallets": TrackedWallets.shared.payload,
            "prices": priceAlerts,
            "priceMarkets": Self.watchlistSymbols,
            "confirm": confirm,
        ]
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        // A dropped connection is retried here, then left for the next foreground. Only
        // the server saying no is worth a dialog.
        var answer: (Data, URLResponse)?
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(attempt * 3)) }
            guard !Task.isCancelled else { return }
            answer = try? await URLSession.shared.data(for: request)
            if answer != nil { break }
        }
        guard let (data, response) = answer else { return }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            if let reason = (try? JSONDecoder().decode(ServerError.self, from: data))?.error { problem = reason }
            return
        }
        if confirm { confirmOnSync = false }
        needsSync = false
        problem = nil
        lastSyncedAt = .now
        UserDefaults.standard.set(lastSyncedAt, forKey: Self.lastSyncKey)
    }

    private struct ServerError: Decodable { let error: String }
}

/// Proves to Desk's server that a subscription belongs to this install. Random, kept in the
/// keychain on this device only, and never derived from the wallet or the device token.
enum InstallSecret {
    private static let service = "com.opia.desk.alerts-install"

    static func value() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data, let text = String(data: data, encoding: .utf8), text.count == 64 {
            return text
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let text = bytes.map { String(format: "%02x", $0) }.joined()
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecValueData as String: Data(text.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess ? text : nil
    }
}

final class DeskAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        TradeAlerts.registerCategories()
        Task { await TradeAlerts.shared.resume() }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        TradeAlerts.shared.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        TradeAlerts.shared.didFailToRegister()
    }

    /// A background push: a trader this phone copies has moved. The loop takes the copy
    /// itself if it is still running with its key; otherwise the alert, if any, stands.
    func application(
        _ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        guard let desk = userInfo["desk"] as? [String: Any], desk["type"] as? String == "wake",
              let trader = desk["trader"] as? String else { return .noData }
        // The push is a hint, not an instruction: the loop runs only for a trader this phone
        // still copies, and only while away copying is on.
        guard await MainActor.run(body: { AutoCopyAway.isOn && CopyTrader.current?.isCopying(trader) == true }) else { return .noData }
        let copier = await MainActor.run { CopyTrader.current }
        return await copier?.wake() == true ? .newData : .noData
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        if let desk = userInfo["desk"] as? [String: Any], desk["type"] as? String == "price",
           let market = desk["market"] as? String {
            await MainActor.run { MarketOpenRequest.shared.open(market) }
            return
        }
        if let desk = userInfo["desk"] as? [String: Any], desk["type"] as? String == "wallet",
           let token = desk["token"] as? String {
            let wallet = desk["wallet"] as? String ?? ""
            let chainIndex = desk["chainIndex"] as? String ?? "143"
            // Only wallets this phone tracks can open a token from a push, for the same reason as below.
            guard await TrackedWallets.shared.isTracking(wallet) else { return }
            let symbol = desk["symbol"] as? String
            await MainActor.run { TokenOpenRequest.shared.open(.init(chainIndex: chainIndex, contract: token, symbol: symbol)) }
            return
        }
        guard let alert = TradeAlert(userInfo: userInfo) else { return }
        // A payload naming a trader this phone does not follow did not come from a
        // subscription this phone made. Nothing here can trade, but it can put a stranger's
        // position in front of someone with a Copy button beside it.
        guard await TradeAlerts.shared.isOn(for: alert.trader) else { return }
        let action = response.actionIdentifier
        if action == TradeAlerts.muteAction {
            await TradeAlerts.shared.mute(alert.trader)
            return
        }
        await MainActor.run {
            TradeAlerts.shared.openedToCopy = action == TradeAlerts.copyAction && alert.canCopy
            TradeAlerts.shared.opened = alert
        }
    }
}
