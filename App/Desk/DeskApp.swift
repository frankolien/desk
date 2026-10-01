import Combine
import DeskAuth
import DeskUI
import SwiftUI
import UIKit

@main
struct DeskApp: App {
    @UIApplicationDelegateAdaptor(DeskAppDelegate.self) private var appDelegate
    @State private var model = AppModel(passkey: DeskApp.passkeyService)

    static let relyingPartyIdentifier = "desk-trading-opia.vercel.app"

    static var relyingParty: RelyingParty? {
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
            case .active:
                grace.return(model)
                Task { await TradeAlerts.shared.resume() }
            default: break
            }
        }
    }
}

struct RootView: View {
    let model: AppModel
    @State private var showsLaunchMoment = true

    private static var isStaged: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-stage")
        #else
        false
        #endif
    }

    var body: some View {
        ZStack {
            Group {
                switch model.stage {
                case .welcome:
                    WelcomeScreen(model: model)
                case .needsDesk:
                    FundScreen(model: model)
                case .trading:
                    if model.showsNameOnboarding && Showcase.nadNames {
                        NadOnboardingScreen(model: model) { model.finishNameOnboarding() }
                            .transition(.opacity)
                    } else {
                        TradingShell(model: model)
                            .id(model.network)
                    }
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
        .overlay(alignment: .top) {
            if !Connectivity.shared.isOnline {
                OfflineBanner()
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(3)
            }
        }
        .animation(.snappy, value: Connectivity.shared.isOnline)
        .animation(.easeInOut(duration: 0.3), value: model.showsNameOnboarding)
        .task { await DisplayCurrency.shared.refresh() }
        .task {
            guard showsLaunchMoment else { return }
            try? await Task.sleep(for: .milliseconds(1_300))
            if model.isReturning, model.stage == .welcome, !Self.isStaged {
                if await model.resume() == .unavailable { await model.signIn() }
            }
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
                // iOS is out of patience, not the grace: the session checks the absence on return against a
                // monotonic clock, so nothing is wiped here (this fires at about thirty seconds regardless).
                self?.timer?.cancel()
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

private struct OfflineBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 13, weight: .bold))
            Text("No internet connection")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(DeskColor.nightText.color)
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 0.5))
        .padding(.top, 8)
        .accessibilityAddTraits(.isStaticText)
    }
}
