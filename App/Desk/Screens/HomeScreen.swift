import DeskUI
import SwiftUI

/// The signed-in landing page: balance, actions, then the account's live instruments.
struct HomeScreen: View {
    let model: AppModel
    let market: MarketModel
    let onTrade: () -> Void
    let onFund: () -> Void
    let onAccount: () -> Void

    @AppStorage("desk.hidesBalance") private var hidesBalance = false
    @State private var showsMore = false

    private var collateralText: String {
        model.collateral.value?.display() ?? Unavailable.text
    }

    private var isEmpty: Bool {
        model.collateral.value.map(\.isZero) ?? true
    }

    var body: some View {
        ZStack {
            homeBackground

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    topBar
                    balance.padding(.top, 54)
                    actions.padding(.top, 42)
                    filterPill.padding(.top, 22)
                    accountRows.padding(.top, 16)
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 116)
            }
        }
        .confirmationDialog("More", isPresented: $showsMore, titleVisibility: .hidden) {
            Button("Copy address") { model.copyAddress() }
            Button("Account and session") { onAccount() }
            Button("End session", role: .destructive) { Task { await model.endSession() } }
        }
    }

    private var homeBackground: some View {
        Color.black.ignoresSafeArea()
    }

    // MARK: Chrome

    private var topBar: some View {
        ZStack {
            HStack {
                glassCircle(symbol: "gearshape.fill", label: "Account", action: onAccount)
                Spacer()
                glassCircle(symbol: "clock.fill", label: "Trading session", action: onAccount)
            }

            Button(action: onAccount) {
                HStack(spacing: 8) {
                    AddressAvatar(address: model.address?.checksummed ?? "", size: 21)
                        .grayscale(1)
                    Text(model.addressShort)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
                .foregroundStyle(DeskColor.nightText.color)
                .padding(.horizontal, 14)
                .frame(height: 42)
            }
            .buttonStyle(.plain)
            .homeGlass(interactive: true, in: Capsule())
            .accessibilityLabel("Your account, \(model.addressShort)")
        }
    }

    private func glassCircle(
        symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(DeskColor.nightText.color)
                .frame(width: 42, height: 42)
        }
        .buttonStyle(.plain)
        .homeGlass(interactive: true, in: Circle())
        .accessibilityLabel(label)
    }

    // MARK: Balance

    private var balance: some View {
        Button {
            hidesBalance.toggle()
        } label: {
            Group {
                if hidesBalance {
                    HStack(spacing: 10) {
                        ForEach(0..<5, id: \.self) { _ in
                            Circle().fill(Color.white).frame(width: 14, height: 14)
                        }
                    }
                    .frame(height: 48)
                } else {
                    AmountText("$" + collateralText, size: 46)
                        .contentTransition(.numericText())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Collateral balance")
        .accessibilityValue(hidesBalance ? "Hidden" : "\(collateralText) AUSD")
        .accessibilityHint("Double tap to \(hidesBalance ? "show" : "hide") your balance")
        .animation(.snappy, value: hidesBalance)
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 8) {
            HomeActionTile(symbol: "tray.and.arrow.down", title: "Add funds", action: onFund)
            HomeActionTile(symbol: "arrow.up.right", title: "Withdraw", isEnabled: !isEmpty, action: onAccount)
            HomeActionTile(symbol: "arrow.left.arrow.right", title: "Trade",
                           isEnabled: !isEmpty, action: onTrade)
            HomeActionTile(symbol: "ellipsis", title: "More") { showsMore = true }
        }
    }

    private var filterPill: some View {
        Button { } label: {
            HStack(spacing: 7) {
                Image(systemName: "globe")
                Text("Desk assets")
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(DeskColor.nightText.color)
            .padding(.horizontal, 12)
            .frame(height: 34)
        }
        .buttonStyle(.plain)
        .homeGlass(interactive: true, in: Capsule())
        .accessibilityLabel("Desk assets")
    }

    // MARK: Rows

    private var accountRows: some View {
        VStack(spacing: 8) {
            HomeAssetRow(
                mark: { MonochromeAssetMark(glyph: "A") },
                title: "AUSD collateral",
                subtitle: "Available to trade",
                value: hidesBalance ? "•••••" : "$" + collateralText,
                change: nil,
                tint: DeskColor.action,
                action: onFund)

            HomeAssetRow(
                mark: { MonochromeSymbolMark(symbol: "chart.xyaxis.line") },
                title: "Open positions",
                subtitle: "Perpl testnet",
                value: "None",
                change: "Ready",
                tint: DeskColor.nightMuted,
                action: onTrade)

            HomeAssetRow(
                mark: { AssetMark.bitcoin(size: 38) },
                title: "Bitcoin perpetual",
                subtitle: "\(market.symbol)-PERP",
                value: market.markText == "—" ? "—" : "$" + market.markText,
                change: market.changePercentText,
                tint: market.trend,
                action: onTrade)

            sessionRow
        }
    }

    private var sessionRow: some View {
        Button(action: onAccount) {
            HStack(spacing: 12) {
                Image(systemName: "faceid")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(DeskColor.nightText.color)
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Face ID trading key")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                    Text("Never stored")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                }

                Spacer()

                Text(model.sessionRemaining == .zero ? "Sign in" : model.sessionRemaining.clockText)
                    .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(DeskColor.nightText.color)
            }
            .padding(.horizontal, 14)
            .frame(height: 66)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .homeGlass(interactive: true, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct HomeActionTile: View {
    let symbol: String
    let title: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                Spacer(minLength: 0)
                Text(title)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .foregroundStyle(DeskColor.nightText.color)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 76)
        }
        .buttonStyle(.plain)
        .homeGlass(interactive: true,
                   in: RoundedRectangle(cornerRadius: 19, style: .continuous))
        .opacity(isEnabled ? 1 : 0.42)
        .disabled(!isEnabled)
        .accessibilityLabel(title)
    }
}

private struct HomeAssetRow<Mark: View>: View {
    @ViewBuilder let mark: () -> Mark
    let title: String
    let subtitle: String
    let value: String
    let change: String?
    let tint: DeskRGB
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                mark()
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(value)
                        .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(DeskColor.nightText.color)
                    if let change {
                        Text(change)
                            .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(tint.color)
                    }
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 66)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .homeGlass(interactive: true, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct MonochromeAssetMark: View {
    let glyph: String

    var body: some View {
        Text(glyph)
            .font(.system(size: 26, weight: .heavy, design: .rounded))
            .foregroundStyle(DeskColor.nightText.color)
            .frame(width: 38, height: 38)
        .accessibilityHidden(true)
    }
}

private struct MonochromeSymbolMark: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 23, weight: .semibold))
            .foregroundStyle(DeskColor.nightText.color)
        .frame(width: 38, height: 38)
        .accessibilityHidden(true)
    }
}

private extension View {
    @ViewBuilder
    func homeGlass<S: Shape>(
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
