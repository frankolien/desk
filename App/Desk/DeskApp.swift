import Combine
import DeskAuth
import SwiftUI
import UIKit

@main
struct DeskApp: App {
    @UIApplicationDelegateAdaptor(DeskAppDelegate.self) private var appDelegate
    @State private var model = AppModel(passkey: DeskApp.passkeyService)

    /// The relying party every passkey binds to, permanently.
    ///
    /// It is a constant here and a `webcredentials:` entry in `Desk.entitlements`, and the
    /// two must be identical. That is two copies of one string, which is a thing worth
    /// being unhappy about — but the alternatives are worse. Reading the entitlement at
    /// run time is macOS-only; `SecTaskCopyValueForEntitlement` is not in the iOS SDK. And
    /// an `INFOPLIST_KEY_DeskRelyingParty` build setting silently does not work: Xcode
    /// injects `INFOPLIST_KEY_*` only for keys it recognises, so a custom one vanishes
    /// from the built plist with no warning — which, since a missing value falls back to
    /// the debug stub, would have signed every user in as the same person.
    ///
    /// So the copies stay, and `tools/check-relying-party.sh` compares them. Run it before
    /// shipping; a mismatch fails only on hardware, because the association is checked by
    /// the system rather than by the app.
    static let relyingPartyIdentifier = "desk-trading-opia.vercel.app"

    static var relyingParty: RelyingParty? {
        // `RelyingParty` refuses the shapes that fail on a device rather than at build
        // time — a scheme, a path, a port, a trailing dot, a bare label.
        try? RelyingParty(relyingPartyIdentifier)
    }

    /// The real ceremony once a relying party exists, and an honest failure until then.
    ///
    /// A release build with no relying party cannot sign in, and that is the correct
    /// failure: better a build that refuses than one that signs everybody in as the same
    /// person. The debug stub is compiled out of release entirely, because a fixed PRF
    /// output derives a fixed key and a shipped fallback to it would hand every user the
    /// same wallet.
    static var passkeyService: any PasskeyService {
        // A simulator has no Secure Enclave and no real biometric, so the PRF output it
        // would produce is not the one a device produces — the whole point of the
        // derivation is that those bytes are the wallet. Development on a simulator
        // therefore keeps the stub, and every build on real hardware runs the real
        // ceremony.
        //
        // This regressed once: adopting the relying party made the ceremony the path on
        // every build, and the simulator then reported "no passkey on this device yet"
        // for a sign-in that could never have worked there.
        #if targetEnvironment(simulator) && DEBUG
        return StubPasskeyService()
        #else
        if let relyingParty {
            return PasskeyCeremony(relyingParty: relyingParty)
        }
        #if DEBUG
        return StubPasskeyService()
        #else
        return UnavailablePasskeyService()
        #endif
        #endif
    }
    @Environment(\.scenePhase) private var phase
    @State private var grace = KeyGrace()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .preferredColorScheme(.dark)
                // Putting the phone down is not switching apps. The grace exists for the
                // second case only, so a lock wipes the key at once.
                .onReceive(NotificationCenter.default.publisher(
                    for: UIApplication.protectedDataWillBecomeUnavailableNotification)
                ) { _ in
                    grace.lock(model)
                }
        }
        .onChange(of: phase) { _, new in
            switch new {
            case .background: grace.leave(model)
            case .active: grace.return(model)
            default: break
            }
        }
    }
}

/// The stage decides the screen, so there is no way to be on Fund without an address or
/// on Market without a desk.
struct RootView: View {
    let model: AppModel
    @State private var showsLaunchMoment = true

    var body: some View {
        ZStack {
            Group {
                switch model.stage {
                case .welcome:
                    WelcomeScreen(model: model)
                case .needsDesk:
                    FundScreen(model: model)
                case .trading:
                    // Rebuilt on a network switch, so no market or socket from the other
                    // network survives inside it.
                    TradingShell(model: model)
                        .id(model.network)
                }
            }

            if showsLaunchMoment {
                LaunchMoment()
                    .transition(.opacity.combined(with: .scale(scale: 1.035)))
                    .zIndex(1)
            }
        }
        .task { await DisplayCurrency.shared.refresh() }
        .task {
            guard showsLaunchMoment else { return }
            try? await Task.sleep(for: .milliseconds(3100))
            withAnimation(.easeInOut(duration: 0.62)) {
                showsLaunchMoment = false
            }
        }
    }
}

/// Keeps Desk running just long enough to wipe the trading key after it leaves the
/// foreground, and keeps the key's transitions in order.
///
/// A backgrounded app is suspended within about thirty seconds and a suspended app runs no
/// code, so a wipe merely scheduled for later would not happen until the person came back.
/// A background task holds execution open for the grace, and the wipe runs inside it. If
/// iOS ends that time early, the expiration handler locks on the spot.
///
/// Every transition goes through one queue. Leaving and returning are async calls on an
/// actor, and two unstructured tasks carry no ordering guarantee — a quick return could
/// otherwise land before the departure it answers, leaving an absence recorded against an
/// app that is open and a key that would then expire in front of the person.
///
/// One limit, stated rather than hidden: iOS may suspend the process the instant the
/// expiration handler returns, before the lock has run. The key would then sit in
/// suspended memory until Desk is next opened — and it is wiped before it can be used,
/// because `SigningSession` checks the absence again on the way back in and before every
/// signature.
@MainActor
final class KeyGrace {
    private var task: UIBackgroundTaskIdentifier = .invalid
    private var timer: Task<Void, Never>?
    private var queue: Task<Void, Never>?

    func leave(_ model: AppModel) {
        timer?.cancel()
        finishBackgroundTask()
        enqueue { await model.enterBackground() }

        task = UIApplication.shared.beginBackgroundTask(withName: "desk.trading-key-grace") { [weak self] in
            MainActor.assumeIsolated {
                self?.timer?.cancel()
                self?.enqueue { await model.lock() }
                // The handler must end the task before it returns, or iOS ends the app.
                self?.finishBackgroundTask()
            }
        }

        timer = Task { [weak self] in
            try? await Task.sleep(for: SigningSession.backgroundGrace)
            guard !Task.isCancelled, let self else { return }
            await enqueue { await model.expireIfAway() }.value
            finishBackgroundTask()
        }
    }

    func `return`(_ model: AppModel) {
        timer?.cancel()
        timer = nil
        finishBackgroundTask()
        enqueue { await model.enterForeground() }
    }

    func lock(_ model: AppModel) {
        enqueue { await model.lock() }
    }

    @discardableResult
    private func enqueue(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = queue
        let next = Task { @MainActor in
            await previous?.value
            await operation()
        }
        queue = next
        return next
    }

    private func finishBackgroundTask() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}
