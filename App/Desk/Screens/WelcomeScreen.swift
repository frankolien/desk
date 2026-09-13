import DeskUI
import SwiftUI

/// The way in.
///
/// Laid out after the reference app's own first screen: a ticker of what the product does
/// running in the upper two thirds, one phrase lit in glass and the rest nearly gone, and
/// beneath it a warm bloom rising off the bottom edge carrying the mark, the promise and
/// the action. The ticker's timings come from the sibling app, where the same control
/// sits commented out — 1.45 seconds a step, 0.55 to cross.
///
/// It is the sign-in screen too. A welcome that says "Get started" followed by a screen
/// that says "Continue with Face ID" is two screens doing one job, and both reference
/// wallets create the account from the landing screen itself.
struct WelcomeScreen: View {
    let model: AppModel
    @State private var showsExplainer = false
    @State private var showsCreateWarning = false

    private let features: [(symbol: String, title: String)] = [
        ("faceid", "Face ID Sign-In"),
        ("key.slash", "No Seed Phrase"),
        ("bolt.fill", "Gasless Orders"),
        ("lock.open", "Key Never Stored"),
    ]

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.height < 760
            // Keep the composition deliberately close to the top-leading edge. The
            // safe area already supplies the necessary physical clearance; a second
            // large inset made the onboarding feel centered and overly cautious.
            let contentInset: CGFloat = compact ? 24 : 30

            ZStack(alignment: .bottom) {
                DeskColor.night.color

                // The bloom is the screen's light source: it rises off the bottom edge,
                // so the mark and the button sit in the lit part and the ticker fades
                // into the dark above them.
                RadialGradient(
                    colors: [
                        Color(red: 0.55, green: 0.27, blue: 0.04).opacity(0.94),
                        DeskColor.action.color.opacity(0.28),
                        .clear,
                    ],
                    center: UnitPoint(x: 0.5, y: 0.94),
                    startRadius: 0,
                    endRadius: proxy.size.height * 0.62)

                VStack(alignment: .leading, spacing: 0) {
                    FeatureTicker(items: features)
                        .padding(.horizontal, contentInset + 2)
                        .frame(height: proxy.size.height * (compact ? 0.39 : 0.40), alignment: .bottom)

                    Spacer(minLength: 0)

                    DeskMark(size: compact ? 48 : 52)
                        .padding(.horizontal, contentInset)

                    Text("Trade perps,\nwith your face")
                        .font(.system(size: compact ? 38 : 42, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .lineSpacing(1)
                        .padding(.horizontal, contentInset)
                        .padding(.top, compact ? 22 : 28)

                    Text("Passkey sign-in, AUSD collateral, gasless orders on Monad")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.58))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, contentInset)
                        .padding(.top, 22)

                    if let problem = model.signInProblem {
                        Text(problem)
                            .font(DeskType.caption)
                            .foregroundStyle(DeskColor.fall.color)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, contentInset)
                            .padding(.top, 12)
                            .transition(.opacity)
                    }

                    // Named with the method, because Apple's guidance is to say which
                    // biometric rather than show a generic verb.
                    PrimaryButton(
                        title: model.isWorking ? "Deriving your keys…" : "Continue with Face ID",
                        isEnabled: !model.isWorking
                    ) {
                        Task { await model.signIn() }
                    }
                    .padding(.horizontal, contentInset)
                    .padding(.top, compact ? 26 : 30)

                    // Present on a device with no account and absent once one exists.
                    // Secondary to Face ID on purpose: a device without its own passkey
                    // most often has one synced from another, and sign-in is the right
                    // first attempt. Creating is behind a confirmation because it makes a
                    // wallet — the version of this screen that reached creation by
                    // dismissing a sheet could strand somebody's funds.
                    if model.mayOfferCreate {
                        Button("New here? Create an account") { showsCreateWarning = true }
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(DeskColor.action.color)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 20)
                            .transition(.opacity)
                    }

                    Button("What is a perpetual?") { showsExplainer = true }
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.58))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 26)

                    Spacer(minLength: 0)
                        .frame(height: max(proxy.safeAreaInsets.bottom, 18) + 6)
                }
                .offset(y: -14)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .animation(.snappy, value: model.signInProblem)
        // Offered, never forced. A pre-roll tutorial measurably makes tasks feel harder,
        // so this is a link a curious person pulls rather than a wall everyone climbs.
        .sheet(isPresented: $showsExplainer) {
            PerpetualExplainer { showsExplainer = false }
        }
        // One confirmation, and it states the irreversible part rather than asking "are
        // you sure". A new passkey is a new wallet; the old one keeps its money.
        .confirmationDialog(
            "Create a new account?",
            isPresented: $showsCreateWarning,
            titleVisibility: .visible
        ) {
            Button("Create new account") { Task { await model.createAccount() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This makes a brand new wallet. If you already have a Desk account on "
                 + "another device, sign in with that passkey instead — a new one cannot "
                 + "reach the old account's funds.")
        }
        .animation(.snappy, value: model.mayOfferCreate)
    }
}
