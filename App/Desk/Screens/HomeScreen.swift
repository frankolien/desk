import DeskMoney
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
    var onSetup: () -> Void = {}
    var onWithdraw: () -> Void = {}
    var onNetwork: () -> Void = {}
    var onFollowing: () -> Void = {}
    var onActivity: () -> Void = {}
    var onSpot: () -> Void = {}
    var onSwap: () -> Void = {}
    let onAccount: () -> Void

    @AppStorage("desk.hidesBalance") private var hidesBalance = false
    @State private var selectedPosition: PerplPosition?
    @State private var spot = SpotHoldingsModel()

    private var collateralText: String {
        // Wallet AUSD and Perpl collateral are different balances. Falling back to the
        // wallet here made a still-loading exchange balance look like a real $0 balance.
        model.collateral.value?.display() ?? Unavailable.text
    }

    private var collateralInCurrency: String {
        model.collateral.value.map { DisplayCurrency.shared.format($0) } ?? Unavailable.text
    }

    private var walletInCurrency: String {
        model.walletAUSD.value.map { DisplayCurrency.shared.format($0) } ?? Unavailable.text
    }

    /// The headline is everything the person holds here: collateral on the desk and
    /// AUSD sitting in the wallet. A withdrawal moves money between the two rows and
    /// leaves this figure alone, which is the answer to "where did my money go".
    private var totalInCurrency: String {
        guard let collateral = model.collateral.value else { return Unavailable.text }
        return DisplayCurrency.shared.format(collateral + (model.walletAUSD.value ?? .zero))
    }

    /// Either balance can leave: collateral from the exchange, or AUSD already in the wallet.
    private var canWithdraw: Bool {
        !(model.collateral.value?.isZero ?? true) || !(model.walletAUSD.value?.isZero ?? true)
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
                    balance.padding(.top, 40)
                    balanceCaption.padding(.top, 6)
                    actions.padding(.top, 28)
                    summaryCards.padding(.top, 20)
                    if !model.hasTradingAccount {
                        setupCard.padding(.top, 16)
                    }
                    accountRows.padding(.top, 16)
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 116)
            }
            .refreshable { await model.refreshBalances(); await market.refreshNow(); await spot.refresh() }
        }
        // See MarketScreen: presenting on a boolean let the content be built while
        // `selectedPosition` was still nil, so the sheet came up empty.
        #if DEBUG
        .task {
            if ProcessInfo.processInfo.arguments.contains("-open-share") {
                try? await Task.sleep(for: .seconds(2))
                selectedPosition = model.openPositions.first
            }
        }
        #endif
        .sheet(item: $selectedPosition) { held in
            PositionScreen(position: held, market: market, session: model.trading, model: model)
                .presentationDetents([.large])
        }
        .task(id: model.address) { await spot.run(for: model.address) }
    }

    private var homeBackground: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            DeskAurora(height: 560)
        }
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack(spacing: 10) {
            Menu {
                Button {
                    withAnimation(.snappy) { hidesBalance.toggle() }
                } label: {
                    Label(hidesBalance ? "Show Balance" : "Hide Balance",
                          systemImage: hidesBalance ? "eye" : "eye.slash")
                }
                Button { Task { await model.lock() } } label: {
                    Label("Lock Trading Key", systemImage: "lock.shield")
                }
                Button { model.copyAddress() } label: { Label("Copy Address", systemImage: "doc.on.doc") }
            } label: {
                AddressAvatar(address: model.address?.checksummed ?? "", size: 42)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Account options")

            Button(action: onAccount) {
                HStack(spacing: 6) {
                    Text(model.addressShort)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                    if !model.network.holdsRealFunds {
                        Text("Testnet")
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .fixedSize()
                            .padding(.horizontal, 6)
                            .frame(height: 17)
                            .background(Color.white.opacity(0.14), in: Capsule())
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(DeskColor.nightMuted.color)
                }
                .foregroundStyle(DeskColor.nightText.color)
                .padding(.horizontal, 14)
                .frame(height: 40)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .homeGlass(interactive: true, in: Capsule())
            .accessibilityLabel("Your account, \(model.addressShort)")

            Spacer()

            glassCircle(symbol: "clock.arrow.circlepath", label: "Activity", action: onActivity)
            glassCircle(symbol: "globe", label: "Network, \(model.network.name)", action: onNetwork)
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
                    AmountText(totalInCurrency, size: 46)
                        .contentTransition(.numericText())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Total balance")
        .accessibilityValue(hidesBalance ? "Hidden" : totalInCurrency)
        .accessibilityHint("Double tap to \(hidesBalance ? "show" : "hide") your balance")
        .animation(.snappy, value: hidesBalance)
    }

    /// Under the total: what the open positions are doing, in money and against the
    /// total. Without positions, where the money is.
    private var balanceCaption: some View {
        Button(action: onTrade) {
            HStack(spacing: 6) {
                if let pnl = totalPositionPnL, let total = model.collateral.value {
                    let base = Double((total + (model.walletAUSD.value ?? .zero)).raw - pnl.raw)
                    let percent = base > 0 ? Double(pnl.raw) / base * 100 : 0
                    Text(hidesBalance ? "•••••" : DisplayCurrency.shared.format(pnl, signed: true) + String(format: " (%+.2f%%)", percent))
                        .foregroundStyle((pnl.isNegative ? DeskColor.fall : DeskColor.rise).color)
                    Text("Open PnL")
                        .foregroundStyle(DeskColor.nightMuted.color)
                } else {
                    Text("AUSD on \(model.network.name)")
                        .foregroundStyle(DeskColor.nightMuted.color)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
            .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var totalPositionPnL: Money? {
        let contexts = positionContexts
        guard !contexts.isEmpty else { return nil }
        return contexts.reduce(.zero) { $0 + $1.figures.unrealisedPnL }
    }

    // MARK: Setup

    /// Shown while this network has no Perpl account. The rest of Home stays usable, so a
    /// switch to mainnet lands here rather than back at onboarding.
    private var setupCard: some View {
        let mainnet = model.network.holdsRealFunds
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                DeskBrandMark(size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start trading on \(model.network.shortName.lowercased())")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                    Text(mainnet
                         ? "Send AUSD, or MON to swap, then open your Perpl account."
                         : "Get free test funds, then open your Perpl account.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button(action: onSetup) {
                HStack {
                    Text(mainnet ? "Fund and open account" : "Get test funds")
                    Spacer()
                    Image(systemName: "arrow.right")
                }
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(DeskColor.night.color)
                .padding(.horizontal, 18)
                .frame(height: 46)
                .background(DeskColor.nightText.color, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .stroke(mainnet ? DeskColor.action.color.opacity(0.35) : Color.white.opacity(0.08), lineWidth: 0.75))
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 10) {
            actionPill(symbol: "arrow.up", title: "Withdraw", isEnabled: canWithdraw, action: onWithdraw)
            actionPill(symbol: "arrow.down", title: "Add funds", action: onFund)
            actionPill(symbol: "clock.arrow.circlepath", title: "History", action: onActivity)
        }
    }

    private func actionPill(symbol: String, title: String, isEnabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 14, weight: .bold))
                Text(title).font(.system(size: 15, weight: .bold, design: .rounded))
            }
            .foregroundStyle(DeskColor.nightText.color)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .homeGlass(interactive: true, in: Capsule())
        .opacity(isEnabled ? 1 : 0.42)
        .disabled(!isEnabled)
    }

    /// The three places money is: on the desk, in the wallet, and at risk in positions.
    private var summaryCards: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                summaryCard(title: "Trading", detail: "AUSD on the desk",
                            value: hidesBalance ? "•••••" : collateralInCurrency, highlighted: true, action: onFund)
                summaryCard(title: "Wallet", detail: "AUSD, not on the desk",
                            value: hidesBalance ? "•••••" : walletInCurrency, action: onWithdraw)
                summaryCard(title: "Positions (\(positionContexts.count))", detail: positionContexts.isEmpty ? "None open" : "Open PnL",
                            value: hidesBalance ? "•••••" : totalPositionPnL.map { DisplayCurrency.shared.format($0, signed: true) } ?? "—",
                            tint: totalPositionPnL.map { $0.isNegative ? DeskColor.fall : DeskColor.rise }, action: onTrade)
            }
        }
        .scrollClipDisabled()
    }

    private func summaryCard(title: String, detail: String, value: String, highlighted: Bool = false,
                             tint: DeskRGB? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
                Text(value)
                    .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle((tint ?? DeskColor.nightText).color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(detail)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color.opacity(0.8))
                    .lineLimit(1)
            }
            .padding(14)
            .frame(width: 168, alignment: .leading)
            .background(Color.white.opacity(highlighted ? 0.09 : 0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(highlighted ? Color.white.opacity(0.35) : Color.white.opacity(0.08), lineWidth: highlighted ? 1 : 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: Rows

    private var accountRows: some View {
        // Ten. At eight the rows read as one ruled table; at fourteen they drifted
        // apart into four unrelated cards. Ten is the gap that groups them without
        // welding them together.
        VStack(spacing: 10) {
            // MON that arrived from an exchange, waiting to become collateral.
            if let spare = model.swappableMON {
                HomeAssetRow(
                    mark: { MonochromeSymbolMark(symbol: "arrow.triangle.2.circlepath") },
                    title: "MON",
                    subtitle: "Swap for AUSD",
                    value: hidesBalance ? "•••••" : spare.display(fractionDigits: 2),
                    unit: "MON",
                    change: nil,
                    tint: DeskColor.nightMuted,
                    action: onSwap)
            }

            // Profit first. A position row that leads with size answers a question
            // nobody opens the app to ask.
            if positionContexts.isEmpty {
                HomeAssetRow(
                    mark: { MonochromeSymbolMark(symbol: "chart.xyaxis.line") },
                    title: "Open positions", subtitle: "Perpl \(model.network.shortName.lowercased())",
                    value: "None", change: "Ready", tint: DeskColor.nightMuted,
                    action: onTrade)
            } else {
                ForEach(Array(positionContexts.prefix(3))) { position in
                    HomeAssetRow(
                        mark: { MarketTokenLogo(symbol: position.market.symbol, size: 44) },
                        title: "\(position.figures.side == .long ? "Long" : "Short") \(position.market.symbol) · \(position.figures.leverageHundredths / 100)×",
                        subtitle: positionSubtitle(position.figures),
                        value: hidesBalance
                            ? "•••••"
                            : (position.figures.unrealisedPnL.isNegative ? "" : "+") + position.figures.unrealisedPnL.display(),
                        unit: hidesBalance ? nil : "AUSD",
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

            // What was bought through Desk, as the chain reports it now. The rows read
            // the balance rather than the purchase, so a token moved on shows as gone.
            ForEach(spot.holdings) { holding in
                HomeAssetRow(
                    mark: { MarketTokenLogo(symbol: holding.purchase.symbol, size: 44, remoteURL: TokenArtwork.url(holding.purchase.logoURL)) },
                    title: holding.purchase.symbol,
                    subtitle: holding.balance.map { "\($0) on \(holding.purchase.chainName)" }
                        ?? "\(holding.purchase.chainName) · \(Unavailable.text)",
                    value: hidesBalance ? "•••••"
                        : holding.value.map { DisplayCurrency.shared.format($0) } ?? Unavailable.text,
                    change: holding.changeSincePaid.map { Self.percent(Int($0 * 1_000_000)) + " since buy" },
                    tint: (holding.changeSincePaid ?? 0) < 0 ? DeskColor.fall : DeskColor.rise,
                    action: onSpot)
            }

            HomeAssetRow(
                mark: { TokenLogo(asset: .bitcoin, size: 44) },
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
            return "Liq. \(Unavailable.text)"
        }
        return distance == 0
            ? "At liquidation"
            : "Liq. \(Self.percent(distance, signed: false)) away"
    }

    /// Micros to a percentage, truncated. A gain is never rounded up into one it is not.
    static func percent(_ micros: Int, signed: Bool = true) -> String {
        Percent.micros(micros, signed: signed)
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
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Face ID trading key")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
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
            .padding(.horizontal, 16)
            .frame(height: 80)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .homeGlass(interactive: true, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct HomeAssetRow<Mark: View>: View {
    @ViewBuilder let mark: () -> Mark
    let title: String
    let subtitle: String
    let value: String
    /// Drawn small after the number, so "AUSD" never pushes the figure onto two lines.
    var unit: String? = nil
    let change: String?
    let tint: DeskRGB
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                mark()
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(value)
                            .font(.system(size: 16, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(DeskColor.nightText.color)
                        if let unit {
                            Text(unit)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(DeskColor.nightMuted.color)
                        }
                    }
                    .lineLimit(1)
                    if let change {
                        Text(change)
                            .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(tint.color)
                            .lineLimit(1)
                    }
                }
                .layoutPriority(1)
            }
            .padding(.horizontal, 16)
            .frame(height: 80)
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
            .frame(width: 44, height: 44)
        .accessibilityHidden(true)
    }
}

private struct MonochromeSymbolMark: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 23, weight: .semibold))
            .foregroundStyle(DeskColor.nightText.color)
        .frame(width: 44, height: 44)
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
