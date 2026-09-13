import DeskAuth
import DeskFlow
import DeskMoney
import DeskPerpl
import Foundation
import Observation
import UIKit

/// Where the app is. Not a router: the state decides the screen, so there is no way to
/// be on Fund with no address or on Market with no desk.
@MainActor
@Observable
final class AppModel {
    enum Stage: Equatable {
        case welcome
        case needsDesk
        case trading
    }

    private(set) var stage: Stage = .welcome
    private(set) var address: EthereumAddress?
    private(set) var signInProblem: String?
    private(set) var isWorking = false

    /// Collateral held at the exchange.
    private(set) var collateral = LastGood<Money>()
    /// What the wallet holds before a desk exists.
    private(set) var walletAUSD = LastGood<Money>()
    private(set) var walletMON = LastGood<Money>()

    private(set) var sessionRemaining: Duration = .zero
    /// Shown once, ever, the first time leverage is reached.
    var hasSeenLeverageExplainer = false
    private let session = SigningSession()
    private let passkey: any PasskeyService
    private var ticker: Task<Void, Never>?

    init(passkey: any PasskeyService) {
        self.passkey = passkey
        #if DEBUG
        // `-stage fund|market` jumps straight to a screen, so each one can be captured
        // and reviewed without walking the flow. Debug only, and never a way into a
        // signed-in state on a real build.
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-stage"),
           index + 1 < ProcessInfo.processInfo.arguments.count {
            let name = ProcessInfo.processInfo.arguments[index + 1]
            stage = switch name {
            case "market", "signals", "signal-detail", "empty": .trading
            case "fund": .needsDesk
            default: .welcome
            }
            // `empty` is the state a real first run is actually in: signed in, funded by
            // nothing. It is the screen most likely to be wrong and the least likely to
            // be looked at, so it gets its own way in.
            if name == "empty" {
                address = try? PasskeyAccounts.deriveAddress(prfOutput: Data(repeating: 0x2A, count: 32))
                walletAUSD.record(.zero)
                walletMON.record(.zero)
                collateral.record(.zero)
                sessionRemaining = .seconds(596)
            } else if stage != .welcome {
                address = try? PasskeyAccounts.deriveAddress(prfOutput: Data(repeating: 0x2A, count: 32))
                walletAUSD.record(Money(text: "10000") ?? .zero)
                walletMON.record(Money(text: "0.19") ?? .zero)
                collateral.record(Money(text: "1282.18") ?? .zero)
                sessionRemaining = .seconds(552)
            }
        }
        #endif
    }

    var sessionFraction: Double {
        let total = Double(SigningSession.defaultLifetime.components.seconds)
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(sessionRemaining.components.seconds) / total))
    }

    var addressShort: String {
        guard let address else { return "—" }
        let text = address.checksummed
        return text.prefix(6) + "…" + text.suffix(4)
    }

    func advance(to stage: Stage) { self.stage = stage }

    /// The checksummed address, not the shortened one — a truncated address pasted into a
    /// block explorer is a support ticket.
    func copyAddress() {
        guard let address else { return }
        UIPasteboard.general.string = address.checksummed
    }

    func signIn() async {
        isWorking = true
        signInProblem = nil
        defer { isWorking = false }
        do {
            let keys = try await passkey.deriveAccounts()
            // The address guard runs before any balance is shown: Apple's synced-passkey
            // bug derives a different address on a second device, and rendering that
            // account's zero would read as theft.
            let verdict = AddressGuard.check(derived: keys.address, against: passkey.lastSeenAddress)
            guard verdict.mayShowBalance else {
                signInProblem = "This passkey derived a different address than last time. "
                    + "Your funds are safe — do not continue until this is sorted."
                return
            }
            address = keys.address
            await session.open(keys.trading)
            startTicking()
            stage = keys.hasDesk ? .trading : .needsDesk
            // Placeholder figures until the chain reads are wired to a funded address.
            walletAUSD.record(Money(text: "10000") ?? .zero)
            walletMON.record(Money(text: "0.19") ?? .zero)
            collateral.record(Money(text: "1240") ?? .zero)
        } catch let failure as PasskeyFailure {
            signInProblem = failure.sentence
        } catch {
            signInProblem = "Sign in could not finish. Try again."
        }
    }

    func openDesk() async {
        isWorking = true
        defer { isWorking = false }
        // The real four-step sequence lives in DeskFlow and needs a funded address; this
        // is the screen's side of it.
        try? await Task.sleep(for: .seconds(1))
        stage = .trading
    }

    func endSession() async {
        await session.end()
        sessionRemaining = .zero
        stage = .welcome
        address = nil
        ticker?.cancel()
        ticker = nil
    }

    func enterBackground() async {
        await session.enterBackground()
        sessionRemaining = .zero
    }

    private func startTicking() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                sessionRemaining = await session.remaining ?? .zero
                if sessionRemaining == .zero, await session.isOpen == false, stage != .welcome {
                    stage = .welcome
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

extension Duration {
    /// `9m 12s`, the shape the Account screen's countdown wants.
    var clockText: String {
        let total = Int(components.seconds)
        return "\(total / 60)m \(String(format: "%02d", total % 60))s"
    }
}
