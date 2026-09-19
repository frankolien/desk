import Combine
import DeskAuth
import SwiftUI
import UIKit

@main
struct DeskApp: App {
    @UIApplicationDelegateAdaptor(DeskAppDelegate.self) private var appDelegate
    @State private var model = AppModel(passkey: DeskApp.passkeyService)


    static let relyingPartyIdentifier = "desk-trading-opia.vercel.app"

    static var relyingParty: RelyingParty? {
        // `RelyingParty` refuses the shapes that fail on a device rather than at build
        // time — a scheme, a path, a port, a trailing dot, a bare label.
        try? RelyingParty(relyingPartyIdentifier)
    }


    static var passkeyService: any PasskeyService {

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

            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-widget-gallery") {
                WidgetGallery().zIndex(2)
            }
            #endif

            if showsLaunchMoment {
                LaunchMoment()
                    .transition(.opacity.combined(with: .scale(scale: 1.035)))
                    .zIndex(1)
            }
        }
        .task { await DisplayCurrency.shared.refresh() }
        .task {
            guard showsLaunchMoment else { return }
            // The mark's own animation chain finishes at about 1.28 s, once the wordmark
            // and the tagline that followed it are gone. Waiting 3.1 s on top of iOS's
            // launch frame held a working app behind a logo for nearly four seconds, on
            // every launch, warm or cold.
            try? await Task.sleep(for: .milliseconds(1_300))
            withAnimation(.easeInOut(duration: 0.62)) {
                showsLaunchMoment = false
            }
        }
    }
}


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
