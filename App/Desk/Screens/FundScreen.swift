import DeskUI
import SwiftUI

/// Turns a newly-created passkey into a funded trading account.
/// Completed and upcoming work collapse into small glass rows; the current step expands.
struct FundScreen: View {
    let model: AppModel
    @State private var didCopy = false
    @State private var step = Step.mon

    enum Step: Int, CaseIterable {
        case passkey, mon, ausd, desk

        var title: String {
            switch self {
            case .passkey: "Passkey secured"
            case .mon: "Fund network fees"
            case .ausd: "Claim test dollars"
            case .desk: "Open your desk"
            }
        }

        var shortDetail: String {
            switch self {
            case .passkey: "Face ID is ready"
            case .mon: "Get MON"
            case .ausd: "Get 10,000 AUSD"
            case .desk: "Create your trading account"
            }
        }

        var detail: String {
            switch self {
            case .passkey: "Your trading identity is protected by your passkey."
            case .mon: "MON covers the three one-time setup transactions. Your orders remain gasless after setup."
            case .ausd: "Claim 10,000 AUSD from the testnet faucet to use as trading collateral."
            case .desk: "Approve collateral, create the account, enable gasless orders, and register your key with one Face ID confirmation."
            }
        }

        var action: String {
            switch self {
            case .passkey: "Done"
            case .mon: "Open MON faucet"
            case .ausd: "Claim 10,000 AUSD"
            case .desk: "Open my desk"
            }
        }

        var symbol: String {
            switch self {
            case .passkey: "faceid"
            case .mon: "fuelpump.fill"
            case .ausd: "dollarsign.circle.fill"
            case .desk: "chart.xyaxis.line"
            }
        }
    }

    var body: some View {
        ZStack {
            setupBackground

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    topBar
                    hero

                    VStack(spacing: 12) {
                        ForEach(Step.allCases, id: \.rawValue) { entry in
                            SetupStepCard(
                                step: entry,
                                number: entry.rawValue + 1,
                                state: state(of: entry),
                                isWorking: model.isWorking && entry == step
                            ) {
                                advance(from: entry)
                            }
                        }
                    }
                    .padding(.top, 30)

                    Text("Testnet only · No real funds")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color.opacity(0.7))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                        .padding(.bottom, 32)
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
            }
        }
        .animation(.snappy(duration: 0.38), value: step)
    }

    private var setupBackground: some View {
        ZStack {
            DeskColor.night.color
            RadialGradient(
                colors: [DeskColor.action.color.opacity(0.16), .clear],
                center: UnitPoint(x: 0.92, y: 0.08), startRadius: 0, endRadius: 390)
            RadialGradient(
                colors: [DeskColor.ledger.color.opacity(0.20), .clear],
                center: UnitPoint(x: 0.06, y: 0.55), startRadius: 0, endRadius: 430)
        }
        .ignoresSafeArea()
    }

    private var topBar: some View {
        HStack {
            Label("Setup", systemImage: "sparkles")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .padding(.horizontal, 15)
                .frame(height: 48)
                .nativeGlass(in: Capsule())

            Spacer()

            Button {
                UIPasteboard.general.string = model.address?.checksummed
                didCopy = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    Text(didCopy ? "Copied" : model.addressShort).monospaced()
                }
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .padding(.horizontal, 15)
                .frame(height: 48)
            }
            .buttonStyle(.plain)
            .nativeGlass(interactive: true, in: Capsule())
            .accessibilityLabel("Copy your wallet address")
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("FINISH SETUP")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .tracking(1.5)
                .foregroundStyle(DeskColor.action.color)

            Text("Your desk is\nalmost ready.")
                .font(.system(size: 43, weight: .heavy, design: .rounded))
                .foregroundStyle(DeskColor.nightText.color)
                .lineSpacing(-2)
                .padding(.top, 10)

            HStack(spacing: 10) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.10))
                        Capsule().fill(DeskColor.action.color)
                            .frame(width: geometry.size.width * progress)
                    }
                }
                .frame(height: 7)

                Text("\(stepsDone)/\(Step.allCases.count)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .monospacedDigit()
            }
            .padding(.top, 24)

            HStack(spacing: 7) {
                Circle().fill(DeskColor.rise.color).frame(width: 7, height: 7)
                Text("10,000 AUSD ready")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
            .padding(.top, 14)
        }
        .padding(.horizontal, 8)
        .padding(.top, 46)
    }

    private var stepsDone: Int { step.rawValue }
    private var progress: CGFloat { CGFloat(stepsDone) / CGFloat(Step.allCases.count) }

    private func state(of entry: Step) -> SetupStepCard.State {
        if entry.rawValue < step.rawValue { return .done }
        return entry == step ? .active : .waiting
    }

    private func advance(from entry: Step) {
        switch entry {
        case .passkey: break
        case .mon, .ausd: step = Step(rawValue: entry.rawValue + 1) ?? .desk
        case .desk: Task { await model.openDesk() }
        }
    }
}

private struct SetupStepCard: View {
    enum State { case done, active, waiting }

    let step: FundScreen.Step
    let number: Int
    let state: State
    let isWorking: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 13) {
                marker
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title)
                        .font(.system(size: state == .active ? 20 : 17, weight: .bold, design: .rounded))
                        .foregroundStyle(titleColor)
                    if state != .active {
                        Text(step.shortDetail)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(DeskColor.nightMuted.color.opacity(state == .waiting ? 0.55 : 0.9))
                    }
                }
                Spacer(minLength: 8)
                if state == .done {
                    Text("DONE")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(DeskColor.rise.color)
                } else if state == .waiting {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(DeskColor.nightMuted.color.opacity(0.45))
                }
            }

            if state == .active {
                Text(step.detail)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
                    .padding(.top, 17)

                Button(action: action) {
                    HStack {
                        Text(isWorking ? "Working…" : step.action)
                        Spacer()
                        Image(systemName: isWorking ? "ellipsis" : "arrow.up.right")
                    }
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.onAction.color)
                    .padding(.horizontal, 21)
                    .frame(maxWidth: .infinity, minHeight: 58)
                    .background(DeskColor.action.color.opacity(isWorking ? 0.45 : 1), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isWorking)
                .padding(.top, 22)
            }
        }
        .padding(state == .active ? 22 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nativeGlass(
            tint: state == .active ? DeskColor.action.color.opacity(0.10) : nil,
            interactive: state == .active,
            in: RoundedRectangle(cornerRadius: state == .active ? 30 : 24, style: .continuous)
        )
        .opacity(state == .waiting ? 0.64 : 1)
    }

    private var titleColor: Color {
        state == .waiting ? DeskColor.nightMuted.color : DeskColor.nightText.color
    }

    private var marker: some View {
        ZStack {
            Circle().fill(markerFill).frame(width: 42, height: 42)
            if state == .done {
                Image(systemName: "checkmark")
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundStyle(DeskColor.night.color)
            } else if state == .active {
                Image(systemName: step.symbol)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(DeskColor.action.color)
            } else {
                Text("\(number)")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
        }
    }

    private var markerFill: Color {
        switch state {
        case .done: DeskColor.rise.color
        case .active: DeskColor.action.color.opacity(0.14)
        case .waiting: Color.white.opacity(0.06)
        }
    }
}

private extension View {
    @ViewBuilder
    func nativeGlass<S: Shape>(
        tint: Color? = nil,
        interactive: Bool = false,
        in shape: S
    ) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 0.6))
        }
    }
}
