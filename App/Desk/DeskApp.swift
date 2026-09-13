import DeskAuth
import SwiftUI

@main
struct DeskApp: App {
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
    static let relyingPartyIdentifier = "desk-trading.vercel.app"

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

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .preferredColorScheme(.dark)
        }
        .onChange(of: phase) { _, new in
            // Backgrounding zeroes the key, and the next order proves it by asking for
            // Face ID again.
            if new == .background { Task { await model.enterBackground() } }
        }
    }
}

/// The stage decides the screen, so there is no way to be on Fund without an address or
/// on Market without a desk.
struct RootView: View {
    let model: AppModel

    var body: some View {
        switch model.stage {
        case .welcome:
            WelcomeScreen(model: model)
        case .needsDesk:
            FundScreen(model: model)
        case .trading:
            TradingShell(model: model)
        }
    }
}
