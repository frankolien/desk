import CryptoKit
import DeskAuth
import DeskChain
import DeskFlow
import Foundation
import Observation
import Security

/// The phone's request key for Auto-Copy on Desk's server: P-256 in the Secure Enclave, so it
/// can't leave this iPhone. The grant registers its public half; after that it signs every change
/// (rules, pause, close, turn off) without Face ID. The simulator has no Secure Enclave and keeps
/// a software key instead.
enum DeviceKey {
    private static let service = "com.opia.desk.copy-device"

    struct Signer {
        let publicKey: Data // X9.63, 65 bytes
        let sign: (Data) throws -> Data // ECDSA over SHA-256, raw r‖s
        var publicKeyText: String { ServerCopyProtocol.base64URL(publicKey) }
    }

    static func signer(network: DeskNetwork, address: String, create: Bool) throws -> Signer? {
        let account = "\(network.rawValue):\(address.lowercased())"
        if let stored = read(account) { return try signer(from: stored) }
        guard create else { return nil }
        let blob: Data
        if SecureEnclave.isAvailable {
            blob = Data([1]) + (try SecureEnclave.P256.Signing.PrivateKey()).dataRepresentation
        } else {
            blob = Data([0]) + P256.Signing.PrivateKey().rawRepresentation
        }
        guard write(blob, account: account) else { throw ServerCopy.Failure.deviceKey }
        return try signer(from: blob)
    }

    static func forget(network: DeskNetwork, address: String) {
        SecItemDelete(query("\(network.rawValue):\(address.lowercased())") as CFDictionary)
    }

    private static func signer(from blob: Data) throws -> Signer {
        let body = blob.dropFirst()
        if blob.first == 1 {
            let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: body)
            return Signer(publicKey: key.publicKey.x963Representation) { try key.signature(for: $0).rawRepresentation }
        }
        let key = try P256.Signing.PrivateKey(rawRepresentation: body)
        return Signer(publicKey: key.publicKey.x963Representation) { try key.signature(for: $0).rawRepresentation }
    }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private static func read(_ account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    private static func write(_ data: Data, account: String) -> Bool {
        SecItemDelete(query(account) as CFDictionary)
        var q = query(account)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }
}

/// Auto-Copy running on Desk's server (docs/server-copy.md), seen from the phone: switching it on
/// with one Face ID, keeping the server's rules in step with the ones set here, and showing what
/// the server holds. While it's on, the phone's own CopyTrader stands aside for this account.
@MainActor @Observable final class ServerCopy {
    enum Failure: LocalizedError {
        case deviceKey, wrongKey, server(String), unreachable

        var errorDescription: String? {
            switch self {
            case .deviceKey: "This iPhone couldn't make its Auto-Copy key."
            case .wrongKey: "Perpl's registration named a different key than Desk's server reported, so nothing was signed."
            case .server(let message): message
            case .unreachable: "Desk's server couldn't be reached."
            }
        }
    }

    struct Copier: Decodable {
        let caps: ServerCopyProtocol.Caps
        let paused: Bool
        let pausedBy: String?
        let enrolledAt: Double?
    }

    struct Snapshot: Decodable {
        let copier: Copier
        let open: [ServerOpenCopy]
        let log: [CopyLogEntry]
        let engine: Engine
        struct Engine: Decodable { let lastSweepAgoMs: Double? }
    }

    /// A copy as the server stores it; mapped to the app's own `OpenCopy` for the existing rows.
    struct ServerOpenCopy: Decodable {
        let id: String
        let trader: String
        let marketId: UInt32
        let symbol: String
        let isLong: Bool
        let sizeRaw: String
        let leverage: Int
        let margin: Double
        let openedAt: Double
        let isShadow: Bool?
        let shadow: ShadowFill?
        let lastMark: Double?
        let theirEntry: Double?
        let state: String?

        var asOpenCopy: OpenCopy? {
            guard let uuid = UUID(uuidString: id) else { return nil }
            return OpenCopy(
                id: uuid, trader: trader, marketID: marketId, symbol: symbol, isLong: isLong, sizeRaw: Int64(sizeRaw) ?? 0,
                leverage: leverage, margin: margin, positionID: nil, openedAt: Date(timeIntervalSince1970: openedAt / 1000),
                isShadow: isShadow, shadow: shadow, lastMark: lastMark, theirEntry: theirEntry)
        }
    }

    nonisolated static let base = URL(string: "https://web-lovat-nine-49.vercel.app/api/copy/")!

    let network: DeskNetwork
    private(set) var address: String?
    private(set) var isOn = false
    private(set) var snapshot: Snapshot?
    private(set) var checkedAt: Date?
    private(set) var problem: String?
    private var pendingRules: Task<Void, Never>?
    private var lastSent: Data?

    init(network: DeskNetwork) { self.network = network }

    var open: [OpenCopy] { snapshot?.open.compactMap(\.asOpenCopy) ?? [] }
    var log: [CopyLogEntry] { snapshot?.log ?? [] }
    var isPaused: Bool { snapshot?.copier.paused ?? false }
    var caps: ServerCopyProtocol.Caps? { snapshot?.copier.caps }

    private var onKey: String? { address.map { "desk.copy.server.\(network.rawValue).\($0.lowercased())" } }

    func bind(address: String?) {
        guard address != self.address else { return }
        self.address = address
        isOn = onKey.map { UserDefaults.standard.bool(forKey: $0) } ?? false
        snapshot = nil
        lastSent = nil
    }

    private func setOn(_ on: Bool) {
        isOn = on
        if let onKey { UserDefaults.standard.set(on, forKey: onKey) }
    }

    // MARK: Switching on

    /// One Face ID: the wallet asks for a server key, checks Perpl's registration names it, and
    /// signs that registration and the grant with these caps. The device key is made first, so
    /// its public half can go into the grant.
    func enable(model: AppModel, caps: ServerCopyProtocol.Caps, timeZone: String = TimeZone.current.identifier) async throws {
        guard let address = model.address?.checksummed else { return }
        let network = network
        guard let deviceKey = try DeviceKey.signer(network: network, address: address, create: true)?.publicKeyText else {
            throw Failure.deviceKey
        }
        let push = TradeAlerts.shared.pushRegistration
        let enrolled: Data = try await model.withWallet { wallet in
            let issued = Int64(Date().timeIntervalSince1970 * 1000)
            let ask = ServerCopyProtocol.prepareText(account: address, network: network, issuedAt: issued)
            let askSignature = try WalletSigner.sign(digest: PersonalMessage.digest(ask), with: wallet)
            let prepared = try await Self.post("prepare", json: [
                "network": network.rawValue, "address": address, "issuedAt": issued, "signature": Self.hex(askSignature.serialized),
            ])
            guard let serverKey = prepared["serverKey"] as? String, let payload = prepared["payload"] as? String else {
                throw Failure.server("Desk's server answered without a key.")
            }
            let typedRaw = try ServerCopyProtocol.typedData(inPayload: Data(payload.utf8))
            guard ServerCopyProtocol.payloadNamesKey(typedDataJSON: typedRaw, serverKey: serverKey) else { throw Failure.wrongKey }
            let typed = try JSONDecoder().decode(EIP712.TypedData.self, from: typedRaw)
            let digest = try EIP712.digest(typed, expecting: .perplEnrolment(signer: address, chainID: network.chainID))
            let walletSignature = try WalletSigner.sign(digest: digest, with: wallet)
            let grant = ServerCopyProtocol.grantText(
                account: address, network: network, serverKey: serverKey, deviceKey: deviceKey, caps: caps,
                issuedAt: Int64(Date().timeIntervalSince1970 * 1000))
            let grantSignature = try WalletSigner.sign(digest: PersonalMessage.digest(grant), with: wallet)
            var body: [String: Any] = [
                "network": network.rawValue, "address": address, "walletSignature": Self.hex(walletSignature.serialized),
                "grant": ["text": grant, "signature": Self.hex(grantSignature.serialized)], "timeZone": timeZone,
            ]
            if let push { body["push"] = ["token": push.token, "environment": push.environment] }
            return try JSONSerialization.data(withJSONObject: try await Self.post("enroll", json: body))
        }
        _ = enrolled
        setOn(true)
        problem = nil
    }

    // MARK: Signed requests

    /// The current rules and guards, sent whenever they change here; the server refuses any past
    /// the grant, and says so.
    func syncRules(traders: [CopiedTrader], guards: CopyGuards) {
        guard isOn else { return }
        var map: [String: Any] = [:]
        for trader in traders {
            guard let rules = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(trader.rules)) else { continue }
            map[trader.address.lowercased()] = ["rules": rules]
        }
        var body: [String: Any] = ["traders": map, "timeZone": TimeZone.current.identifier]
        if let guards = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(guards)) { body["guards"] = guards }
        if let push = TradeAlerts.shared.pushRegistration { body["push"] = ["token": push.token, "environment": push.environment] }
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: .sortedKeys), data != lastSent else { return }
        pendingRules?.cancel()
        pendingRules = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, !Task.isCancelled else { return }
            do {
                _ = try await self.signed("rules", body: data)
                self.lastSent = data
                self.problem = nil
            } catch {
                self.problem = error.localizedDescription
            }
        }
    }

    func refresh() async {
        guard isOn else { return }
        do {
            let data = try await signed("state", body: Data("{}".utf8))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            snapshot = try decoder.decode(Snapshot.self, from: data)
            checkedAt = .now
            problem = nil
        } catch Failure.server(let message) where message.contains("isn't on") {
            setOn(false) // turned off elsewhere
        } catch {
            problem = error.localizedDescription
        }
    }

    func setPaused(_ paused: Bool) async {
        do { _ = try await signed(paused ? "pause" : "resume", body: Data("{}".utf8)); await refresh() }
        catch { problem = error.localizedDescription }
    }

    func close(_ copy: OpenCopy) async {
        let body = try? JSONSerialization.data(withJSONObject: ["copyId": copy.id.uuidString.lowercased()])
        do { _ = try await signed("close", body: body ?? Data()); await refresh() }
        catch { problem = error.localizedDescription }
    }

    /// The server stops and retires its key; open copies keep whatever stops Perpl holds for them.
    func disable() async throws {
        _ = try await signed("disable", body: Data("{}".utf8))
        setOn(false)
        snapshot = nil
        lastSent = nil
        if let address { DeviceKey.forget(network: network, address: address) }
    }

    // MARK: Transport

    private func signed(_ action: String, body: Data) async throws -> Data {
        guard let address, let device = try DeviceKey.signer(network: network, address: address, create: false) else {
            throw Failure.deviceKey
        }
        let time = Int64(Date().timeIntervalSince1970 * 1000)
        var nonceBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, nonceBytes.count, &nonceBytes)
        let nonce = ServerCopyProtocol.base64URL(Data(nonceBytes))
        let message = ServerCopyProtocol.canonical(chainID: network.chainID, action: action, time: time, nonce: nonce, body: body)
        let signature = try device.sign(Data(message.utf8))
        var request = URLRequest(url: Self.base.appending(path: action), timeoutInterval: 20)
        request.httpMethod = "POST"
        // text/plain, so the server hashes the bytes that were signed rather than a re-parse.
        request.setValue("text/plain;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(network.rawValue, forHTTPHeaderField: "X-Desk-Network")
        request.setValue(address, forHTTPHeaderField: "X-Desk-Account")
        request.setValue(String(time), forHTTPHeaderField: "X-Desk-Time")
        request.setValue(nonce, forHTTPHeaderField: "X-Desk-Nonce")
        request.setValue(ServerCopyProtocol.base64URL(signature), forHTTPHeaderField: "X-Desk-Signature")
        request.httpBody = body
        return try await Self.send(request)
    }

    private nonisolated static func post(_ action: String, json: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: base.appending(path: action), timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        let data = try await send(request)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private nonisolated static func send(_ request: URLRequest) async throws -> Data {
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode
        else { throw Failure.unreachable }
        guard (200..<300).contains(status) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw Failure.server(message ?? "Desk's server answered \(status).")
        }
        return data
    }

    private nonisolated static func hex(_ data: Data) -> String {
        "0x" + data.map { String(format: "%02x", $0) }.joined()
    }
}
