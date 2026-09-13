import DeskAuth
import SwiftUI

@main
struct DeskApp: App {
    @State private var model = AppModel(passkey: DeskApp.passkeyService)

    /// The relying party every passkey binds to, permanently.
    ///
    /// Read from the Info.plist rather than written here, so the entitlement, the
    /// association file and the ceremony all take the same string from one place — a
    /// mismatch between them only shows up on hardware, never in a build.
    ///
    /// Absent until the domain is chosen. That it is optional is deliberate: an empty
    /// string would be a relying party, and a wrong relying party is unrecoverable.
    static var relyingParty: RelyingParty? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "DeskRelyingParty") as? String,
              !text.isEmpty
        else { return nil }
        return try? RelyingParty(text)
    }

    /// The real ceremony once a relying party exists, and an honest failure until then.
    ///
    /// A release build with no relying party cannot sign in, and that is the correct
    /// failure: better a build that refuses than one that signs everybody in as the same
    /// person. The debug stub is compiled out of release entirely, because a fixed PRF
    /// output derives a fixed key and a shipped fallback to it would hand every user the
    /// same wallet.
    static var passkeyService: any PasskeyService {
        if let relyingParty {
            return PasskeyCeremony(relyingParty: relyingParty)
        }
        #if DEBUG
        return StubPasskeyService()
        #else
        return UnavailablePasskeyService()
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
