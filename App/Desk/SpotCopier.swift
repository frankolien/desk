import DeskAuth
import DeskChain
import DeskFlow
import Foundation
import Observation
import Security

/// Spot Auto-Copy (docs/spot-copy.md), seen from the phone. One Face ID puts Desk's copy key on
/// this wallet behind DeskCopyHook, which only lets it swap AUSD for a followed wallet's tokens
/// and back within the limits signed here. After that, the phone's device key steers who is
/// copied and how, with no Face ID; new limits and turning off are signed by the wallet again.
@MainActor @Observable final class SpotCopier {
    static let shared = SpotCopier()

    enum Failure: LocalizedError {
        case deviceKey, server(String), unreachable, notReady

        var errorDescription: String? {
            switch self {
            case .deviceKey: "This iPhone couldn't make its Auto-Copy key."
            case .server(let message): message
            case .unreachable: "Desk's server couldn't be reached."
            case .notReady: "Spot Auto-Copy isn't switched on yet."
            }
        }
    }

    struct Leader: Decodable, Equatable {
        let rules: SpotCopyProtocol.Rules
        let since: Double?
        let name: String?
    }

    struct Copier: Decodable {
        let wallet: String
        let stage: String
        let limits: SpotCopyProtocol.Limits
        let expiry: Double?
        let paused: Bool
        let pausedBy: String?
        let leaders: [String: Leader]
        let error: String?
    }

    struct Position: Decodable, Identifiable {
        let token: String
        let symbol: String?
        let copiedRaw: String
        var id: String { token }
    }

    struct LogRow: Decodable, Identifiable {
        let at: Double
        let leader: String?
        let token: String?
        let symbol: String?
        let side: String?
        let status: String
        let ausd: Double?
        let amount: Double?
        let hash: String?
        let detail: String?
        var id: String { "\(at)-\(token ?? "")-\(status)" }
        var date: Date { Date(timeIntervalSince1970: at / 1000) }
    }

    struct Snapshot: Decodable {
        let copier: Copier
        let live: Bool
        let remainingTodayRaw: String?
        let positions: [Position]
        let log: [LogRow]
    }

    /// What `spot-prepare` hands the phone to sign against.
    struct Prepared {
        let desk: String
        let hook: String
        let batchNonce: String
        let deadline: UInt64
        let authorizationNonce: UInt64?
        let feeBps: Int
        let delegation: String
    }

    nonisolated static let base = ServerCopy.base

    private(set) var address: String?
    private(set) var isOn = false
    private(set) var snapshot: Snapshot?
    private(set) var problem: String?
    private(set) var feeBps: Int?

    private var onKey: String? { address.map { "desk.copy.spot.\($0.lowercased())" } }

    func bind(address: String?) {
        guard address?.lowercased() != self.address?.lowercased() else { return }
        self.address = address
        isOn = onKey.map { UserDefaults.standard.bool(forKey: $0) } ?? false
        snapshot = nil
        problem = nil
    }

    private func setOn(_ on: Bool) {
        isOn = on
        if let onKey { UserDefaults.standard.set(on, forKey: onKey) }
    }

    var stage: String? { snapshot?.copier.stage }
    var isPaused: Bool { snapshot?.copier.paused ?? false }
    var limits: SpotCopyProtocol.Limits? { snapshot?.copier.limits }
    var expiry: Date? { snapshot?.copier.expiry.map { Date(timeIntervalSince1970: $0) } }
    var leaders: [String: Leader] { snapshot?.copier.leaders ?? [:] }
    var log: [LogRow] { snapshot?.log ?? [] }
    var positions: [Position] { snapshot?.positions ?? [] }
    var remainingToday: Double? { snapshot?.remainingTodayRaw.flatMap(Double.init).map { $0 / 1_000_000 } }

    func rules(for leader: String) -> SpotCopyProtocol.Rules? { leaders[leader.lowercased()]?.rules }

    // MARK: Switching on

    func prepare(wallet: String) async throws -> Prepared {
        let answer = try await Self.post("spot-prepare", json: ["wallet": wallet])
        guard let desk = answer["desk"] as? String, let hook = answer["hook"] as? String,
              let nonce = answer["batchNonce"] as? String, let deadline = (answer["deadline"] as? NSNumber)?.uint64Value
        else { throw Failure.notReady }
        let authorization = (answer["authorizationNonce"] as? String).flatMap(UInt64.init)
        let prepared = Prepared(desk: desk, hook: hook, batchNonce: nonce, deadline: deadline, authorizationNonce: authorization,
                                feeBps: (answer["feeBps"] as? NSNumber)?.intValue ?? 0, delegation: answer["delegation"] as? String ?? "none")
        feeBps = prepared.feeBps
        return prepared
    }

    private struct Signatures: Sendable {
        let batch: EthereumSignature
        let authorization: EthereumSignature?
        let grant: EthereumSignature?
    }

    /// One Face ID: the setup batch, the EIP-7702 authorization if the wallet doesn't run
    /// Calibur on Monad yet, and the grant naming this iPhone. The server rebuilds each and
    /// refuses any that differ.
    func enable(model: AppModel, limits: SpotCopyProtocol.Limits, days: Int, leader: String, name: String?, rules: SpotCopyProtocol.Rules) async throws {
        guard let wallet = model.address?.checksummed else { return }
        let prepared = try await prepare(wallet: wallet)
        guard let deviceKey = try DeviceKey.signer(network: .mainnet, address: wallet, create: true)?.publicKeyText else { throw Failure.deviceKey }
        let expiry = UInt64(Date().timeIntervalSince1970) + UInt64(days) * 86_400
        let calls = try SpotCopy.setupCalls(desk: prepared.desk, hook: prepared.hook, expiry: expiry, perTrade: limits.perTrade, perDay: limits.perDay)
        let digest = try SpotCopy.batchDigest(wallet: wallet, calls: calls, nonce: prepared.batchNonce, deadline: prepared.deadline, executor: prepared.desk)
        let issuedAt = Int64(Date().timeIntervalSince1970 * 1000)
        let grant = SpotCopyProtocol.grantText(wallet: wallet, desk: prepared.desk, deviceKey: deviceKey, limits: limits, expiry: expiry, issuedAt: issuedAt)
        let authorizationDigest = prepared.authorizationNonce.map(SpotCopy.authorizationDigest(nonce:))
        let signed: Signatures = try await model.withWallet { key in
            Signatures(
                batch: try WalletSigner.sign(digest: digest, with: key),
                authorization: try authorizationDigest.map { try WalletSigner.sign(digest: $0, with: key) },
                grant: try WalletSigner.sign(digest: PersonalMessage.digest(grant), with: key))
        }
        var body: [String: Any] = [
            "wallet": wallet, "deviceKey": deviceKey, "perTrade": limits.perTrade, "perDay": limits.perDay, "expiry": expiry,
            "nonce": prepared.batchNonce, "deadline": prepared.deadline, "signature": Self.hex(signed.batch.serialized),
            "grant": ["issuedAt": issuedAt, "signature": Self.hex(signed.grant?.serialized ?? Data())],
            "leaders": [leader.lowercased(): Self.leaderJSON(rules: rules, name: name)],
        ]
        if let authorization = signed.authorization, let nonce = prepared.authorizationNonce {
            body["authorization"] = [
                "chainId": SpotCopy.chainID, "address": SpotCopy.calibur, "nonce": nonce,
                "r": Self.hex(authorization.r), "s": Self.hex(authorization.s), "yParity": authorization.yParity,
            ]
        }
        if let push = TradeAlerts.shared.pushRegistration { body["push"] = ["token": push.token, "environment": push.environment] }
        _ = try await Self.post("spot-enable", json: body)
        model.noteMonadDelegated()
        setOn(true)
        problem = nil
        await refresh()
    }

    // MARK: Steering, with the device key

    /// Adds, changes or (with nil) stops copying one wallet. No Face ID: within the limits signed.
    func setRules(_ rules: SpotCopyProtocol.Rules?, for leader: String, name: String?) async throws {
        var map: [String: Any] = [:]
        for (address, entry) in leaders where address != leader.lowercased() {
            map[address] = Self.leaderJSON(rules: entry.rules, name: entry.name)
        }
        if let rules { map[leader.lowercased()] = Self.leaderJSON(rules: rules, name: name) }
        var body: [String: Any] = ["leaders": map]
        if let push = TradeAlerts.shared.pushRegistration { body["push"] = ["token": push.token, "environment": push.environment] }
        _ = try await signed("spot-rules", body: try JSONSerialization.data(withJSONObject: body, options: .sortedKeys))
        await refresh()
    }

    func refresh() async {
        guard isOn else { return }
        do {
            let data = try await signed("spot-state", body: Data("{}".utf8))
            snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            if snapshot?.copier.stage == "off" { setOn(false) }
            problem = nil
        } catch Failure.server(let message) where message.contains("isn't on") {
            setOn(false)
            snapshot = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    func setPaused(_ paused: Bool) async {
        do { _ = try await signed(paused ? "spot-pause" : "spot-resume", body: Data("{}".utf8)); await refresh() }
        catch { problem = error.localizedDescription }
    }

    // MARK: Signed by the wallet again

    /// New limits or a new end date: one Face ID, relayed by Desk like the first.
    func changeLimits(model: AppModel, limits: SpotCopyProtocol.Limits, days: Int) async throws {
        guard let wallet = model.address?.checksummed else { return }
        let prepared = try await prepare(wallet: wallet)
        let expiry = UInt64(Date().timeIntervalSince1970) + UInt64(days) * 86_400
        let calls = try SpotCopy.limitCalls(desk: prepared.desk, hook: prepared.hook, expiry: expiry, perTrade: limits.perTrade, perDay: limits.perDay)
        let digest = try SpotCopy.batchDigest(wallet: wallet, calls: calls, nonce: prepared.batchNonce, deadline: prepared.deadline, executor: prepared.desk)
        let signature = try await model.withWallet { key in try WalletSigner.sign(digest: digest, with: key) }
        let body: [String: Any] = [
            "perTrade": limits.perTrade, "perDay": limits.perDay, "expiry": expiry,
            "nonce": prepared.batchNonce, "deadline": prepared.deadline, "signature": Self.hex(signature.serialized),
        ]
        _ = try await signed("spot-limits", body: try JSONSerialization.data(withJSONObject: body, options: .sortedKeys))
        await refresh()
    }

    /// Copying stops at once; Desk's key comes off the wallet when the signed revoke lands.
    func disable(model: AppModel) async throws {
        guard let wallet = model.address?.checksummed else { return }
        let prepared = try await prepare(wallet: wallet)
        let calls = try SpotCopy.revokeCalls(desk: prepared.desk)
        let digest = try SpotCopy.batchDigest(wallet: wallet, calls: calls, nonce: prepared.batchNonce, deadline: prepared.deadline, executor: prepared.desk)
        let signature = try await model.withWallet { key in try WalletSigner.sign(digest: digest, with: key) }
        let body: [String: Any] = ["nonce": prepared.batchNonce, "deadline": prepared.deadline, "signature": Self.hex(signature.serialized)]
        _ = try await signed("spot-disable", body: try JSONSerialization.data(withJSONObject: body, options: .sortedKeys))
        await refresh()
    }

    // MARK: Transport

    private static func leaderJSON(rules: SpotCopyProtocol.Rules, name: String?) -> [String: Any] {
        var entry: [String: Any] = [:]
        if let data = try? JSONEncoder().encode(rules), let object = try? JSONSerialization.jsonObject(with: data) { entry["rules"] = object }
        if let name, !name.isEmpty { entry["name"] = name }
        return entry
    }

    private func signed(_ action: String, body: Data) async throws -> Data {
        guard let address, let device = try DeviceKey.signer(network: .mainnet, address: address, create: false) else {
            throw Failure.deviceKey
        }
        let time = Int64(Date().timeIntervalSince1970 * 1000)
        var nonceBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, nonceBytes.count, &nonceBytes)
        let nonce = ServerCopyProtocol.base64URL(Data(nonceBytes))
        let message = ServerCopyProtocol.canonical(chainID: SpotCopy.chainID, action: action, time: time, nonce: nonce, body: body)
        let signature = try device.sign(Data(message.utf8))
        var request = URLRequest(url: Self.base.appending(path: action), timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("text/plain;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(address, forHTTPHeaderField: "X-Desk-Wallet")
        request.setValue(String(time), forHTTPHeaderField: "X-Desk-Time")
        request.setValue(nonce, forHTTPHeaderField: "X-Desk-Nonce")
        request.setValue(ServerCopyProtocol.base64URL(signature), forHTTPHeaderField: "X-Desk-Signature")
        request.httpBody = body
        return try await Self.send(request)
    }

    private nonisolated static func post(_ action: String, json: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: base.appending(path: action), timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("text/plain;charset=UTF-8", forHTTPHeaderField: "Content-Type")
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
