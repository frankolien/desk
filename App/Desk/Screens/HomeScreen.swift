import DeskPerpl
import DeskUI
import SwiftUI

/// The signed-in landing page: balance, actions, then the account's live instruments.
struct HomeScreen: View {
    private struct PositionContext: Identifiable {
        let held: PerplPosition
        let market: Market
        let figures: PositionFigures
        var id: String { "\(held.accountID):\(held.positionID)" }
    }

    let model: AppModel
    let market: MarketModel
    let onTrade: () -> Void
    let onFund: () -> Void
    let onAccount: () -> Void

    @AppStorage("desk.hidesBalance") private var hidesBalance = false
    @State private var showsMore = false
    @State private var selectedPosition: PerplPosition?

    private var collateralText: String {
        // Wallet AUSD and Perpl collateral are different balances. Falling back to the
        // wallet here made a still-loading exchange balance look like a real $0 balance.
        model.collateral.value?.display() ?? Unavailable.text
    }

    private var isEmpty: Bool {
        model.collateral.value.map(\.isZero) ?? true
    }

    /// Derived here, at the point of display, so every figure in the row descends from the
    /// one mark that was current when it was drawn. Held on the model instead, PnL and
    /// mark could come from two ticks a frame apart and disagree on screen.
    private var positionContexts: [PositionContext] {
        model.openPositions.compactMap { held in
            guard let positionMarket = market.market(id: held.marketID),
                  let mark = market.price(for: positionMarket),
                  let figures = PositionFigures(
                    position: held, market: positionMarket.config, mark: mark)
            else { return nil }
            return PositionContext(held: held, market: positionMarket, figures: figures)
        }
    }

    var body: some View {
        ZStack {
            homeBackground

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    topBar
                    balance.padding(.top, 54)
                    actions.padding(.top, 42)
                    accountRows.padding(.top, 24)
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 116)
            }
        }
        .confirmationDialog("More", isPresented: $showsMore, titleVisibility: .hidden) {
            Button("Copy address") { model.copyAddress() }
            Button("Account and session") { onAccount() }
            Button("Lock now") { Task { await model.lock() } }
            Button("Sign out", role: .destructive) { Task { await model.endSession() } }
        }
        // See MarketScreen: presenting on a boolean let the content be built while
        // `selectedPosition` was still nil, so the sheet came up empty.
        .sheet(item: $selectedPosition) { held in
            PositionScreen(position: held, market: market, session: model.trading, model: model)
                .presentationDetents([.large])
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
                .contentShape(Capsule())
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
                .contentShape(Circle())
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
            .contentShape(Rectangle())
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

    // MARK: Rows

    private var accountRows: some View {
        VStack(spacing: 8) {
            HomeAssetRow(
                mark: { TokenLogo(asset: .ausd, size: 38) },
                title: "AUSD collateral",
                subtitle: "Available to trade",
                value: hidesBalance ? "•••••" : "$" + collateralText,
                change: nil,
                tint: DeskColor.action,
                action: onFund)

            // Profit first. A position row that leads with size answers a question
            // nobody opens the app to ask.
            if positionContexts.isEmpty {
                HomeAssetRow(
                    mark: { MonochromeSymbolMark(symbol: "chart.xyaxis.line") },
                    title: "Open positions", subtitle: "Perpl testnet",
                    value: "None", change: "Ready", tint: DeskColor.nightMuted,
                    action: onTrade)
            } else {
                ForEach(Array(positionContexts.prefix(3))) { position in
                    HomeAssetRow(
                        mark: { MarketTokenLogo(symbol: position.market.symbol, size: 38) },
                        title: "\(position.figures.side == .long ? "Long" : "Short") \(position.market.symbol) · \(position.figures.leverageHundredths / 100)×",
                        subtitle: positionSubtitle(position.figures),
                        value: hidesBalance
                            ? "•••••"
                            : (position.figures.unrealisedPnL.isNegative ? "" : "+")
                                + position.figures.unrealisedPnL.display() + " AUSD",
                        change: Self.percent(position.figures.returnOnMarginMicros) + " on margin",
                        tint: position.figures.isProfit ? DeskColor.rise : DeskColor.fall,
                        action: {
                            market.select(position.market)
                            selectedPosition = position.held
                            Task { await model.trading.selectMarket(position.market) }
                        })
                }
                if positionContexts.count > 3 {
                    Button("View \(positionContexts.count - 3) more positions", action: onTrade)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                }
            }

            HomeAssetRow(
                mark: { TokenLogo(asset: .bitcoin, size: 38) },
                title: "Bitcoin perpetual",
                subtitle: "\(market.symbol)-PERP",
                value: market.markText == "—" ? "—" : "$" + market.markText,
                change: market.changePercentText,
                tint: market.trend,
                action: onTrade)

            sessionRow
        }
    }

    /// Liquidation distance rather than size, because distance is the figure that
    /// changes and the one that can end the position. `--` when the price is not yet
    /// known: a distance computed from no mark would be a claim.
    private func positionSubtitle(_ position: PositionFigures) -> String {
        guard let distance = position.liquidationDistanceMicros else {
            return "Liquidation \(Unavailable.text)"
        }
        return distance == 0
            ? "At liquidation"
            : "Liquidation \(Self.percent(distance, signed: false)) away"
    }

    /// Micros to a percentage, truncated. A gain is never rounded up into one it is not.
    static func percent(_ micros: Int, signed: Bool = true) -> String {
        let sign = micros < 0 ? Direction.minus : (signed ? "+" : "")
        let magnitude = abs(micros)
        return "\(sign)\(magnitude / 10_000).\(String(format: "%02d", (magnitude % 10_000) / 100))%"
    }

    /// The key's state rather than a countdown — there is no timer to show. Unlocked goes
    /// through to Account; locked goes straight to Face ID, because that is the only thing
    /// a person tapping a locked key wants.
    private var sessionRow: some View {
        Button {
            if model.isKeyUnlocked { onAccount() } else { Task { await model.unlock() } }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: model.isKeyUnlocked ? "faceid" : "lock.fill")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(DeskColor.nightText.color)
                    .contentTransition(.symbolEffect(.replace))
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Face ID trading key")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                    Text(model.isKeyUnlocked ? "Held in memory while Desk is open" : "Locked · never stored")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                }

                Spacer()

                Text(model.isKeyUnlocked ? "Unlocked" : "Unlock")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle((model.isKeyUnlocked ? DeskColor.nightText : DeskColor.identity).color)
            }
            .padding(.horizontal, 14)
            .frame(height: 66)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
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
            // Without this the tile is tappable only where its glyph and label are
            // drawn: the padding and the glass behind it are not part of the button.
            .contentShape(Rectangle())
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
            .contentShape(Rectangle())
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
