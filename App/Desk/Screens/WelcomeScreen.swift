import DeskUI
import SwiftUI

/// The way in.
///
/// Laid out after the reference app's own first screen: a ticker of what the product does
/// running in the upper two thirds, one phrase lit in glass and the rest dimmed, and
/// beneath it the mark, the promise and the action on the same ground every other screen
/// uses. The ticker's timings come from the sibling app, where the same control sits
/// commented out — 1.45 seconds a step, 0.55 to cross.
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
                // The same ground as every other screen, rather than one this screen
                // invented. A saturated bloom used to rise off the bottom edge over most
                // of the screen; it lit the button so brightly that amber stopped meaning
                // "you can act here", because everything down there was already amber.
                DeskBackground()

                // One warm corner under the action, and no more than that. It reaches a
                // third of the way up at sixteen percent, so it warms the ground the
                // button sits on without competing with the button for the eye.
                RadialGradient(
                    colors: [DeskColor.action.color.opacity(0.16), .clear],
                    center: UnitPoint(x: 0.02, y: 0.94),
                    startRadius: 0,
                    endRadius: proxy.size.height * 0.34)
                    .allowsHitTesting(false)

                VStack(alignment: .leading, spacing: 0) {
                    FeatureTicker(items: features)
                        .padding(.horizontal, contentInset + 2)
                        .frame(height: proxy.size.height * (compact ? 0.39 : 0.40), alignment: .bottom)

                    Spacer(minLength: 0)

                    DeskBrandMark(size: compact ? 48 : 52)
                        .padding(.horizontal, contentInset)

                    // The category and the reason to pick this one, in that order. Perps
                    // alone is a claim a dozen apps make; copying alone reads as though
                    // trading yourself is not on offer, and a third of the app is exactly
                    // that. "With your face" said neither, and the ticker above already
                    // makes the passkey point four times over.
                    Text("Trade perps.\nOr copy someone\nwho's good at it.")
                        .font(.system(size: compact ? 28 : 31, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .lineSpacing(1)
                        .padding(.horizontal, contentInset)
                        .padding(.top, compact ? 22 : 28)

                    Text("Perpetuals on Monad. Face ID signs every order — no seed phrase, no wallet app.")
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
        .sheet(isPresented: $showsCreateWarning) {
            CreateAccountSheet(model: model)
                .presentationDetents([.height(390)])
                .presentationDragIndicator(.visible)
                .accountSheetGlass()
        }
        .animation(.snappy, value: model.mayOfferCreate)
    }
}

private struct CreateAccountSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "person.badge.key.fill")
                .font(.title2)
                .foregroundStyle(DeskColor.action.color)
                .padding(.bottom, 18)

            Text("Create your Desk account")
                .font(.title2.weight(.bold))

            Text("Face ID creates a new passkey and wallet on this device.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 14) {
                AccountNote(
                    symbol: "key.fill",
                    title: "No seed phrase",
                    detail: "Your passkey protects the account.")
                AccountNote(
                    symbol: "iphone.gen3",
                    title: "Already have an account?",
                    detail: "Cancel and sign in so you keep the same wallet.")
            }
            .padding(.top, 24)

            Spacer(minLength: 18)

            Button {
                dismiss()
                Task { await model.createAccount() }
            } label: {
                Text("Create account")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(DeskColor.action.color)
            .disabled(model.isWorking)

            Button("Cancel", role: .cancel) { dismiss() }
                .font(.headline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 14)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension View {
    @ViewBuilder
    func accountSheetGlass() -> some View {
        if #available(iOS 26.0, *) {
            self
                .glassEffect(.regular, in: .rect(cornerRadius: 32))
                .presentationBackground(.clear)
        } else {
            self.presentationBackground(.thinMaterial)
        }
    }
}

private struct AccountNote: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
