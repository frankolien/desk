import DeskUI
import SwiftUI

/// The way in.
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
            let contentInset: CGFloat = compact ? 22 : 30

            ZStack {
                WelcomeLivingBackground()

                VStack(alignment: .leading, spacing: 0) {
                    WelcomeFeatureRail(items: features)
                        .frame(height: proxy.size.height * (compact ? 0.40 : 0.42), alignment: .bottom)

                    Spacer(minLength: 0)

                    DeskBrandMark(size: compact ? 48 : 52)
                        .padding(.horizontal, contentInset)

                    Text("Trade perps")
                        .font(.system(size: compact ? 39 : 44, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .lineSpacing(1)
                        .padding(.horizontal, contentInset)
                        .padding(.top, compact ? 18 : 24)

                    Text("Perpetuals on Monad. Face ID signs every order — no seed phrase, no wallet app.")
                        .font(.system(size: compact ? 15 : 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, contentInset)
                        .padding(.top, compact ? 14 : 18)

                    if let problem = model.signInProblem {
                        Text(problem)
                            .font(DeskType.caption)
                            .foregroundStyle(DeskColor.fall.color)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, contentInset)
                            .padding(.top, 12)
                            .transition(.opacity)
                    }

                    Button {
                        Task { await model.signIn() }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "faceid")
                                .font(.system(size: 20, weight: .semibold))
                            Text(model.isWorking ? "Deriving your keys…" : "Continue with Face ID")
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(DeskColor.night.color)
                        .frame(maxWidth: .infinity)
                        .frame(height: compact ? 58 : 62)
                        .background(DeskColor.action.color.opacity(model.isWorking ? 0.4 : 1), in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 0.7))
                        .shadow(color: DeskColor.action.color.opacity(0.2), radius: 22, y: 9)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isWorking)
                    .padding(.horizontal, contentInset)
                    .padding(.top, compact ? 20 : 24)

                    // Present on a device with no account and absent once one exists.
                    // Secondary to Face ID on purpose: a device without its own passkey
                    // most often has one synced from another, and sign-in is the right
                    // first attempt. Creating is behind a confirmation because it makes a
                    // wallet — the version of this screen that reached creation by
                    // dismissing a sheet could strand somebody's funds.
                    if model.mayOfferCreate {
                        Button("New here? Create an account") { showsCreateWarning = true }
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(DeskColor.action.color)
                            .frame(maxWidth: .infinity)
                            .padding(.top, compact ? 12 : 16)
                            .transition(.opacity)
                    }

                    Button("What is a perpetual?") { showsExplainer = true }
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.60))
                        .frame(maxWidth: .infinity)
                        .padding(.top, compact ? 16 : 20)

                    Spacer(minLength: 0)
                        .frame(height: max(proxy.safeAreaInsets.bottom, 14) + 4)
                }
                .padding(.top, max(proxy.safeAreaInsets.top, 18))
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

/// A slow lighting pass, not moving content. Core Animation interpolates two blurred
/// fields for the whole eighteen-second cycle, and Reduce Motion freezes them in place.
private struct WelcomeLivingBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drifting = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                DeskBackground()

                Ellipse()
                    .fill(Color(red: 0.02, green: 0.22, blue: 0.12).opacity(0.48))
                    .frame(width: proxy.size.width * 1.15, height: proxy.size.height * 0.48)
                    .blur(radius: 92)
                    .offset(x: drifting ? proxy.size.width * 0.24 : -proxy.size.width * 0.22,
                            y: drifting ? -proxy.size.height * 0.20 : -proxy.size.height * 0.34)
                    .scaleEffect(drifting ? 1.12 : 0.92)

                Ellipse()
                    .fill(DeskColor.action.color.opacity(0.20))
                    .frame(width: proxy.size.width * 0.95, height: proxy.size.height * 0.34)
                    .blur(radius: 86)
                    .offset(x: drifting ? -proxy.size.width * 0.20 : proxy.size.width * 0.22,
                            y: drifting ? proxy.size.height * 0.39 : proxy.size.height * 0.31)
                    .scaleEffect(drifting ? 0.94 : 1.10)

                LinearGradient(
                    colors: [.black.opacity(0.08), .clear, .black.opacity(0.18)],
                    startPoint: .top, endPoint: .bottom)
            }
            .ignoresSafeArea()
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 18).repeatForever(autoreverses: true)) {
                    drifting = true
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The existing feature ticker, redesigned as a connected security sequence. One row is
/// active at a time; the rail keeps all four feeling like one story rather than loose text.
private struct WelcomeFeatureRail: View {
    let items: [(symbol: String, title: String)]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var active = 1

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                featureRow(item, index: index)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            guard !reduceMotion, items.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.65))
                withAnimation(.smooth(duration: 0.55)) {
                    active = (active + 1) % items.count
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func featureRow(_ item: (symbol: String, title: String), index: Int) -> some View {
        let isActive = index == active
        return HStack(spacing: 12) {
            ZStack {
                if index < items.count - 1 {
                    Rectangle()
                        .fill(DeskColor.action.color.opacity(0.38))
                        .frame(width: 1, height: 62)
                        .offset(y: 31)
                }
                Circle()
                    .fill(isActive ? DeskColor.action.color : DeskColor.night.color)
                    .frame(width: isActive ? 14 : 11, height: isActive ? 14 : 11)
                    .overlay(Circle().stroke(DeskColor.action.color.opacity(isActive ? 1 : 0.65), lineWidth: 1.2))
                    .shadow(color: isActive ? DeskColor.action.color.opacity(0.55) : .clear, radius: 8)
            }
            .frame(width: 20)

            HStack(spacing: 11) {
                if isActive {
                    Image(systemName: item.symbol)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(DeskColor.action.color)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
                Text(item.title)
                    .font(.system(size: isActive ? 20 : 17, weight: .bold, design: .rounded))
                    .foregroundStyle(isActive ? DeskColor.nightText.color : DeskColor.nightText.color.opacity(0.34))
            }
            .padding(.horizontal, isActive ? 18 : 8)
            .frame(maxWidth: isActive ? 300 : .infinity, alignment: .leading)
            .frame(height: 54)
            .background {
                if isActive {
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .overlay(Capsule().fill(DeskColor.action.color.opacity(0.07)))
                        .overlay(Capsule().stroke(DeskColor.action.color.opacity(0.45), lineWidth: 0.7))
                }
            }
        }
        .padding(.horizontal, 28)
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
