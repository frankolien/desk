import SwiftUI

@main
struct DeskApp: App {
    @State private var model = AppModel(passkey: DeskApp.passkeyService)

    /// There is no real ceremony yet — it needs an associated domain, which needs the
    /// relying party. Until then a release build has nothing to sign in with, and that is
    /// the correct failure: better a build that cannot sign in than one that signs
    /// everybody in as the same person.
    static var passkeyService: any PasskeyService {
        #if DEBUG
        StubPasskeyService()
        #else
        UnavailablePasskeyService()
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
