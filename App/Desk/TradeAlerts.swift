import Foundation
import Observation
import Security
import UIKit
import UserNotifications

struct TradeAlert: Identifiable, Hashable, Sendable {
    enum Event: String, Sendable { case opened, flipped, added, reduced, closed }

    let event: Event
    let trader: String
    let market: String
    let side: String
    let leverage: Double?
    let entry: String
    let value: String
    var previousValue: String? = nil
    let observedAt: Date

    var id: String { "\(trader)-\(market)-\(event.rawValue)-\(observedAt.timeIntervalSince1970)" }
    var isLong: Bool { side == "long" }
    var canCopy: Bool { event == .opened || event == .flipped || event == .added }

    init?(userInfo: [AnyHashable: Any]) {
        guard let desk = userInfo["desk"] as? [String: Any], desk["type"] as? String == "trade",
              let event = (desk["event"] as? String).flatMap(Event.init(rawValue:)),
              let trader = desk["trader"] as? String, !trader.isEmpty,
              let market = desk["market"] as? String, !market.isEmpty,
              let side = desk["side"] as? String, side == "long" || side == "short" else { return nil }
        self.init(event: event, trader: trader, market: market, side: side,
                  leverage: Self.number(desk["leverage"]).flatMap { $0 > 0 && $0 < 10_000 ? $0 : nil },
                  entry: Self.text(desk["entry"]) ?? "", value: Self.text(desk["value"]) ?? "",
                  previousValue: Self.text(desk["previousValue"]),
                  observedAt: Self.number(desk["observedAt"]).map { Date(timeIntervalSince1970: $0 / 1000) } ?? .now)
    }

    init(event: Event, trader: String, market: String, side: String, leverage: Double?,
         entry: String, value: String, previousValue: String? = nil, observedAt: Date) {
        self.event = event
        self.trader = trader
        self.market = market
        self.side = side
        self.leverage = leverage
        self.entry = entry
        self.value = value
        self.previousValue = previousValue
        self.observedAt = observedAt
    }

    private static func number(_ raw: Any?) -> Double? {
        if let number = raw as? NSNumber { return number.doubleValue }
        return (raw as? String).flatMap(Double.init)
    }

    private static func text(_ raw: Any?) -> String? {
        if let text = raw as? String { return text }
        return (raw as? NSNumber)?.stringValue
    }
}

@MainActor
@Observable
final class TradeAlerts {
    enum Permission: Equatable { case undetermined, allowed, denied }

    static let shared = TradeAlerts()

    private(set) var alerted: [String]
    private(set) var permission: Permission = .undetermined
    var problem: String?
    var opened: TradeAlert?
    var openedToCopy = false
    var openedTrader: String?
    var opensProfile = false

    private var deviceToken: String?
    private var confirmOnSync = false
    private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var needsSync = UserDefaults.standard.bool(forKey: "desk.alerts.needsSync") {
        didSet { if needsSync != oldValue { UserDefaults.standard.set(needsSync, forKey: Self.dirtyKey) } }
    }
    private var registrationRetry: Task<Void, Never>?

    private static let storageKey = "desk.alertedTraders"
    private static let pricesKey = "desk.alerts.prices"
    private static let targetsKey = "desk.alerts.targets"
    private(set) var targets: [PriceTarget] = {
        guard let data = UserDefaults.standard.data(forKey: "desk.alerts.targets") else { return [] }
        return (try? JSONDecoder().decode([PriceTarget].self, from: data)) ?? []
    }()
    private(set) var priceAlerts = UserDefaults.standard.bool(forKey: "desk.alerts.prices")
    private static let depositsKey = "desk.alerts.deposits"
    private(set) var depositAlerts = UserDefaults.standard.object(forKey: "desk.alerts.deposits") as? Bool ?? true
    private static let dirtyKey = "desk.alerts.needsSync"
    private static let mutedMigratedKey = "desk.alerts.mutedMigrated"
    private static let sentMeKey = "desk.alerts.sentMe"
    private static let nicknameKey = "desk.traderNicknames"
    private static let primerKey = "desk.alertsPrimerShown"
    private static let endpoint = URL(string: "https://web-lovat-nine-49.vercel.app/api/alerts")!
    private static let tokenKey = "desk.alertsDeviceToken"
    private static let mutedKey = "desk.alerts.muted"
    private static let meKey = "desk.alerts.me"
    private(set) var muted: [String] = UserDefaults.standard.stringArray(forKey: "desk.alerts.muted") ?? []
    private(set) var me: String? = UserDefaults.standard.string(forKey: "desk.alerts.me")
    var sendsDeposits: Bool { me != nil && depositAlerts && permission == .allowed }

    nonisolated static let copyAction = "desk.copy"
    nonisolated static let viewAction = "desk.view"
    nonisolated static let muteAction = "desk.mute"

    private init() {
        alerted = UserDefaults.standard.stringArray(forKey: Self.storageKey) ?? []
        // Cached so a Mute pressed from the lock screen can reach the server before iOS
        // hands a background launch a fresh token.
        deviceToken = UserDefaults.standard.string(forKey: Self.tokenKey)
    }

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
            UNNotificationCategory(identifier: "desk.receipt", actions: [], intentIdentifiers: []),
        ])
    }

    var hasSeenPrimer: Bool {
        get { UserDefaults.standard.bool(forKey: Self.primerKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.primerKey) }
    }

    func isOn(for address: String) -> Bool {
        alerted.contains { $0.caseInsensitiveCompare(address) == .orderedSame }
    }

    func isMuted(_ address: String) -> Bool {
        muted.contains { $0.caseInsensitiveCompare(address) == .orderedSame }
    }

    private func setMuted(_ address: String, _ on: Bool) {
        guard isMuted(address) != on else { return }
        if on { muted.append(address) } else { muted.removeAll { $0.caseInsensitiveCompare(address) == .orderedSame } }
        UserDefaults.standard.set(muted, forKey: Self.mutedKey)
    }

    func signedIn(as address: String) {
        let key = address.lowercased()
        guard key != me else { return }
        me = key
        UserDefaults.standard.set(key, forKey: Self.meKey)
        confirmOnSync = true
        Task {
            await refreshPermission()
            if permission == .allowed { UIApplication.shared.registerForRemoteNotifications() }
            scheduleSync()
        }
    }

    func askForDeposits() async {
        guard me != nil, depositAlerts else { return }
        let center = UNUserNotificationCenter.current()
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        await refreshPermission()
        guard permission == .allowed else { return }
        alertFollowed()
        UIApplication.shared.registerForRemoteNotifications()
        scheduleSync()
    }

    private func alertFollowed() {
        let followed = UserDefaults.standard.stringArray(forKey: TraderDirectory.storageKey) ?? []
        var missing: [String] = []
        for address in followed + TrackedWallets.shared.list.map(\.address)
        where TrackedWallets.isEVM(address) && !isOn(for: address) && !isMuted(address)
            && !missing.contains(where: { $0.caseInsensitiveCompare(address) == .orderedSame }) {
            missing.append(address)
        }
        guard !missing.isEmpty else { return }
        alerted.append(contentsOf: missing)
        persist()
        needsSync = true
    }

    func refreshPermission() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        permission = switch status {
        case .notDetermined: .undetermined
        case .denied: .denied
        default: .allowed
        }
        // The server keeps the deposit address only while this phone can show the push.
        if sendsDeposits != UserDefaults.standard.bool(forKey: Self.sentMeKey), deviceToken != nil { scheduleSync() }
    }

    func resume() async {
        // Before 1 Oct a missing setting meant on, so the server may still push prices to this
        // install. Say off once, explicitly, so it stops.
        if UserDefaults.standard.object(forKey: Self.pricesKey) == nil {
            UserDefaults.standard.set(false, forKey: Self.pricesKey)
            if deviceToken != nil || lastSyncedAt != nil { scheduleSync() }
        }
        if !UserDefaults.standard.bool(forKey: Self.mutedMigratedKey) {
            // Before the muted list, a followed trader with no alerts had its bell turned off.
            let followed = UserDefaults.standard.stringArray(forKey: TraderDirectory.storageKey) ?? []
            for trader in followed where !isOn(for: trader) { setMuted(trader, true) }
            UserDefaults.standard.set(true, forKey: Self.mutedMigratedKey)
        }
        await refreshPermission()
        if permission == .allowed { alertFollowed() }
        let wantsAlerts = !alerted.isEmpty || priceAlerts || !TrackedWallets.shared.list.isEmpty || !targets.isEmpty
            || (me != nil && depositAlerts)
        if needsSync, deviceToken != nil { scheduleSync() }
        guard (permission == .allowed && wantsAlerts) || !copying.isEmpty else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

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

    @discardableResult
    func setDepositAlerts(_ on: Bool) async -> Bool {
        if on {
            let center = UNUserNotificationCenter.current()
            if await center.notificationSettings().authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            }
            await refreshPermission()
            guard permission == .allowed else { return false }
        }
        depositAlerts = on
        UserDefaults.standard.set(on, forKey: Self.depositsKey)
        if on { UIApplication.shared.registerForRemoteNotifications() }
        scheduleSync()
        return true
    }

    func targets(for market: String) -> [PriceTarget] {
        targets.filter { $0.market == market.uppercased() }
    }

    @discardableResult
    func addTarget(market: String, price: Double, mark: Double) async -> Bool {
        guard price > 0, price != mark else { return false }
        let center = UNUserNotificationCenter.current()
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        await refreshPermission()
        guard permission == .allowed else { return false }
        let target = PriceTarget(market: market.uppercased(), price: price, direction: price > mark ? .above : .below)
        guard !targets.contains(target) else { return true }
        targets.append(target)
        if targets.count > 20 { targets.removeFirst(targets.count - 20) }
        persistTargets()
        UIApplication.shared.registerForRemoteNotifications()
        scheduleSync()
        return true
    }

    func removeTarget(_ target: PriceTarget) {
        targets.removeAll { $0 == target }
        persistTargets()
        scheduleSync()
    }

    func targetFired(market: String, level: Double) {
        targets.removeAll { $0.market == market.uppercased() && $0.price == level }
        persistTargets()
    }

    private func persistTargets() {
        UserDefaults.standard.set(try? JSONEncoder().encode(targets), forKey: Self.targetsKey)
    }

    @discardableResult
    func turnOn(for address: String) async -> Bool {
        setMuted(address, false)
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

    func turnOff(for address: String, muting: Bool = false) {
        setMuted(address, muting)
        guard isOn(for: address) else { return }
        alerted.removeAll { $0.caseInsensitiveCompare(address) == .orderedSame }
        persist()
        scheduleSync()
    }

    func mute(_ address: String) async {
        setMuted(address, true)
        guard isOn(for: address) else { return }
        alerted.removeAll { $0.caseInsensitiveCompare(address) == .orderedSame }
        persist()
        // A cold launch from the push hasn't read the permission yet; without it the sync drops `me`.
        await refreshPermission()
        syncTask?.cancel()
        await sync()
    }

    func signOut() async {
        let hadSubscription = !alerted.isEmpty || !copying.isEmpty || priceAlerts || !TrackedWallets.shared.list.isEmpty || !targets.isEmpty
            || deviceToken != nil || lastSyncedAt != nil || me != nil
        alerted = []
        muted = []
        me = nil
        copying = []
        targets = []
        persistTargets()
        AutoCopyAway.isOn = false
        persist()
        syncTask?.cancel()
        needsSync = false
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
        openedTrader = nil
        opensProfile = false
        for key in [Self.storageKey, Self.nicknameKey, Self.tokenKey, Self.primerKey, Self.copyingKey, Self.mutedKey, Self.meKey, Self.sentMeKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        deviceToken = nil
    }

    func didRegister(deviceToken data: Data) {
        registrationRetry?.cancel()
        let token = data.map { String(format: "%02x", $0) }.joined()
        let current = token == deviceToken && !needsSync
            && lastSyncedAt.map { Date.now.timeIntervalSince($0) < 12 * 3600 } == true
        deviceToken = token
        UserDefaults.standard.set(token, forKey: Self.tokenKey)
        if !current { scheduleSync() }
    }

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

    func setCopying(_ addresses: [String]) {
        guard addresses != copying else { return }
        copying = addresses
        UserDefaults.standard.set(addresses, forKey: Self.copyingKey)
        if deviceToken == nil, !addresses.isEmpty { UIApplication.shared.registerForRemoteNotifications() }
        scheduleSync()
    }

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
        needsSync = true
        guard let deviceToken, let install = InstallSecret.value() else { return }
        let nicknames = UserDefaults.standard.dictionary(forKey: Self.nicknameKey) as? [String: String] ?? [:]
        let traders = alerted.map { $0.lowercased() }
        var names: [String: String] = [:]
        for trader in traders {
            let name = nicknames[trader].flatMap { $0.isEmpty ? nil : $0 } ?? TrackedWallets.shared.wallet(for: trader)?.name
            if let name, !name.isEmpty { names[trader] = name }
        }
        let confirm = confirmOnSync
        let sentTargets = targets
        let sentMe = sendsDeposits ? me : nil
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        var body: [String: Any] = [
            "install": install,
            "token": deviceToken,
            "environment": environment,
            "traders": traders,
            "names": names,
            "copying": copying,
            "wallets": TrackedWallets.shared.payload,
            "prices": priceAlerts,
            "priceMarkets": Self.watchlistSymbols,
            "targets": sentTargets.map { ["market": $0.market, "price": $0.price, "direction": $0.direction.rawValue] as [String: Any] },
            "confirm": confirm,
            "moves": 2,
        ]
        if let sentMe { body["me"] = ["address": sentMe, "networks": ["mainnet", "testnet"]] }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
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
        let kept = (try? JSONDecoder().decode(SyncAnswer.self, from: data))?.targets ?? []
        let fired = sentTargets.filter { !kept.contains($0) }
        if !fired.isEmpty { targets.removeAll { fired.contains($0) }; persistTargets() }
        needsSync = false
        problem = nil
        UserDefaults.standard.set(sentMe != nil, forKey: Self.sentMeKey)
        lastSyncedAt = .now
        UserDefaults.standard.set(lastSyncedAt, forKey: Self.lastSyncKey)
    }

    private struct ServerError: Decodable { let error: String }
    private struct SyncAnswer: Decodable { let targets: [PriceTarget]? }
}

struct PriceTarget: Codable, Hashable, Identifiable {
    enum Side: String, Codable { case above, below }
    var market: String
    var price: Double
    var direction: Side
    var id: String { "\(market)-\(price)-\(direction.rawValue)" }
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
        await Self.noteFiredTarget(notification.request.content.userInfo)
        return [.banner, .list, .sound]
    }

    nonisolated private static func noteFiredTarget(_ userInfo: [AnyHashable: Any]) async {
        guard let desk = userInfo["desk"] as? [String: Any], desk["type"] as? String == "price",
              desk["kind"] as? String == "target", let market = desk["market"] as? String,
              let level = (desk["level"] as? NSNumber)?.doubleValue else { return }
        await MainActor.run { TradeAlerts.shared.targetFired(market: market, level: level) }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        await Self.noteFiredTarget(userInfo)
        if let desk = userInfo["desk"] as? [String: Any], desk["type"] as? String == "price",
           let market = desk["market"] as? String {
            await MainActor.run { MarketOpenRequest.shared.open(market) }
            return
        }
        if let desk = userInfo["desk"] as? [String: Any], desk["type"] as? String == "wallet",
           let token = desk["token"] as? String {
            let wallet = desk["wallet"] as? String ?? ""
            let chainIndex = desk["chainIndex"] as? String ?? "143"
            guard await TrackedWallets.shared.isTracking(wallet) else { return }
            let symbol = desk["symbol"] as? String
            await MainActor.run { TokenOpenRequest.shared.open(.init(chainIndex: chainIndex, contract: token, symbol: symbol)) }
            return
        }
        if let desk = userInfo["desk"] as? [String: Any], desk["type"] as? String == "receipt" {
            await MainActor.run {
                guard TradeAlerts.shared.me != nil else { return }
                TradeAlerts.shared.opensProfile = true
            }
            return
        }
        let action = response.actionIdentifier
        if let desk = userInfo["desk"] as? [String: Any], desk["type"] as? String == "trade",
           desk["event"] as? String == "summary" {
            guard let trader = desk["trader"] as? String, !trader.isEmpty,
                  await TradeAlerts.shared.isOn(for: trader) else { return }
            if action == TradeAlerts.muteAction {
                await TradeAlerts.shared.mute(trader)
            } else {
                await MainActor.run { TradeAlerts.shared.openedTrader = trader }
            }
            return
        }
        guard let alert = TradeAlert(userInfo: userInfo) else { return }
        // A trader this phone does not follow came from no subscription it made; showing it
        // would put a stranger's position beside a Copy button.
        guard await TradeAlerts.shared.isOn(for: alert.trader) else { return }
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
