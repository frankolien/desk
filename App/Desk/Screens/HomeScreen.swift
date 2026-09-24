import DeskChain
import DeskMoney
import DeskPerpl
import DeskUI
import SwiftUI

/// Profile: who this is, what it is worth, and what it holds.
///
/// Small type and plain rows. The screen is a ledger to be read, not a set of cards to
/// be admired, and every figure on it is one this phone has actually observed.
struct HomeScreen: View {
    private struct PositionContext: Identifiable {
        let held: PerplPosition
        let market: Market
        let figures: PositionFigures
        var id: String { "\(held.accountID):\(held.positionID)" }
    }

    private enum Book: String, CaseIterable { case open = "Open", closed = "Closed" }
    private enum Filter: String, CaseIterable, Identifiable {
        case all = "All", perps = "Perps", tokens = "Tokens"
        var id: String { rawValue }
    }
    private enum Range: String, CaseIterable, Identifiable {
        case day = "24h", week = "7d", all = "All"
        var id: String { rawValue }
        var seconds: TimeInterval? { switch self { case .day: 86_400; case .week: 7 * 86_400; case .all: nil } }
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
    @AppStorage("desk.firstOpened") private var firstOpened: Double = 0
    @State private var selectedPosition: PerplPosition?
    @State private var spot = SpotHoldingsModel()
    @State private var book: Book = .open
    @State private var filter: Filter = .all
    @State private var range: Range = .day
    @State private var equity: [EquityLog.Point] = []
    @State private var copiedAddress = false
    @State private var editsProfile = false

    // MARK: Figures

    private var collateralInCurrency: String {
        model.collateral.value.map { DisplayCurrency.shared.format($0) } ?? Unavailable.text
    }

    private var walletInCurrency: String {
        model.walletAUSD.value.map { DisplayCurrency.shared.format($0) } ?? Unavailable.text
    }

    /// Everything the person holds here: collateral on the desk and AUSD in the wallet.
    private var total: Money? {
        guard let collateral = model.collateral.value else { return nil }
        return collateral + (model.walletAUSD.value ?? .zero)
    }

    private var totalInCurrency: String {
        total.map { DisplayCurrency.shared.format($0) } ?? Unavailable.text
    }

    private var canWithdraw: Bool {
        !(model.collateral.value?.isZero ?? true) || !(model.walletAUSD.value?.isZero ?? true)
    }

    /// Derived here, at the point of display, so every figure in the row descends from the
    /// one mark that was current when it was drawn.
    private var positionContexts: [PositionContext] {
        model.openPositions.compactMap { held in
            guard let positionMarket = market.market(id: held.marketID),
                  let mark = market.price(for: positionMarket),
                  let figures = PositionFigures(position: held, market: positionMarket.config, mark: mark)
            else { return nil }
            return PositionContext(held: held, market: positionMarket, figures: figures)
        }
    }

    private var totalPositionPnL: Money? {
        let contexts = positionContexts
        guard !contexts.isEmpty else { return nil }
        return contexts.reduce(.zero) { $0 + $1.figures.unrealisedPnL }
    }

    private var ownName: String? {
        model.address.flatMap { IdentityDirectory.shared.name(for: $0.checksummed) }
    }

    private var followingCount: Int { UserDefaults.standard.stringArray(forKey: "desk.followedTraders")?.count ?? 0 }

    private var sinceText: String {
        guard firstOpened > 0 else { return "" }
        return "Desk since " + Date(timeIntervalSince1970: firstOpened).formatted(.dateTime.month(.abbreviated).year())
    }

    /// The log inside the chosen window; the whole log for "All".
    private var shownEquity: [EquityLog.Point] {
        guard let seconds = range.seconds else { return equity }
        let cutoff = Date.now.addingTimeInterval(-seconds)
        return equity.filter { $0.at >= cutoff }
    }

    private var chartPoints: [Double] {
        shownEquity.map { Double($0.raw) / 1_000_000 }
    }

    private var chartChange: (money: Money, percent: Double)? {
        let shown = shownEquity
        guard let first = shown.first, let last = shown.last, first.raw > 0, shown.count >= 2,
              let delta = Money(raw: last.raw - first.raw) else { return nil }
        return (delta, Double(last.raw - first.raw) / Double(first.raw) * 100)
    }

    var body: some View {
        ZStack {
            homeBackground

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    topBar
                    identity.padding(.top, 34)
                    hairline.padding(.top, 22)
                    portfolio.padding(.top, 20)
                    cashRow.padding(.top, 22)
                    if let spare = model.swappableMON { monRow(spare).padding(.top, 4) }
                    if !model.hasTradingAccount { setupCard.padding(.top, 16) }
                    ledger.padding(.top, 30)
                    sessionRow.padding(.top, 26)
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 116)
            }
            .refreshable { await model.refreshBalances(); await market.refreshNow(); await spot.refresh() }
        }
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
        .sheet(isPresented: $editsProfile) {
            ProfileEditorSheet(model: model) { editsProfile = false }
        }
        #if DEBUG
        .task { if ProcessInfo.processInfo.arguments.contains("-open-profile-editor") { editsProfile = true } }
        #endif
        .task(id: model.address) { await spot.run(for: model.address) }
        .task(id: model.address) {
            if let address = model.address { await IdentityDirectory.shared.resolve([address.checksummed]) }
        }
        .onAppear { if firstOpened == 0 { firstOpened = Date.now.timeIntervalSince1970 } }
        .task(id: "\(model.address?.checksummed ?? "")|\(total?.raw ?? -1)") {
            guard let address = model.address, let total else { return }
            EquityLog.record(total, network: model.network.rawValue, address: address.checksummed)
            equity = EquityLog.points(network: model.network.rawValue, address: address.checksummed)
        }
    }

    private var homeBackground: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            DeskAurora()
        }
    }

    private var hairline: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)
    }

    // MARK: Chrome

    private var topBar: some View {
        ZStack {
            HStack {
                glassCircle(symbol: "gearshape.fill", label: "Account", action: onAccount)
                Spacer()
                glassCircle(symbol: "clock.fill", label: "Activity", action: onActivity)
            }

            Button(action: onAccount) {
                HStack(spacing: 8) {
                    AddressAvatar(address: model.address?.checksummed ?? "", size: 21)
                        .grayscale(1)
                    Text(model.addressShort)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    // Mainnet is the normal state and carries no label; only testnet is marked.
                    if !model.network.holdsRealFunds {
                        Text("Testnet")
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .foregroundStyle(DeskColor.nightText.color)
                            .padding(.horizontal, 7)
                            .frame(height: 18)
                            .background(Color.white.opacity(0.14), in: Capsule())
                    }
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

    private func glassCircle(symbol: String, label: String, action: @escaping () -> Void) -> some View {
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

    // MARK: Identity

    /// Who this is, in the terms the rest of Desk uses for other traders: a name when one
    /// is known on chain, the address otherwise, and the record so far.
    private var identity: some View {
        HStack(alignment: .top, spacing: 14) {
            Menu {
                Button { editsProfile = true } label: { Label("Edit Profile", systemImage: "person.crop.circle.badge.plus") }
                Button {
                    withAnimation(.snappy) { hidesBalance.toggle() }
                } label: {
                    Label(hidesBalance ? "Show Balance" : "Hide Balance", systemImage: hidesBalance ? "eye" : "eye.slash")
                }
                Button { Task { await model.lock() } } label: { Label("Lock Trading Key", systemImage: "lock.shield") }
                Button { model.copyAddress() } label: { Label("Copy Address", systemImage: "doc.on.doc") }
            } label: {
                // The trader avatar, not the generated one: a Farcaster, ENS, nad or SNS
                // picture set elsewhere shows here the way it shows on every other trader.
                TraderAvatar(address: model.address?.checksummed ?? "", size: 58)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(DeskColor.night.color)
                            .frame(width: 18, height: 18)
                            .background(DeskColor.nightText.color, in: Circle())
                            .overlay(Circle().stroke(Color.black, lineWidth: 2))
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Account options")

            VStack(alignment: .leading, spacing: 5) {
                Text(ownName ?? model.addressShort)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
                    .lineLimit(1)
                // The address line is the copy button. Tapping an address and having it
                // copied is what every wallet has taught people to expect.
                Button {
                    model.copyAddress()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.snappy(duration: 0.2)) { copiedAddress = true }
                    Task { try? await Task.sleep(for: .seconds(1.4)); withAnimation { copiedAddress = false } }
                } label: {
                    HStack(spacing: 5) {
                        Text(copiedAddress ? "Address copied" : (ownName != nil ? model.addressShort : "\(model.addressShort) · \(model.network.shortName)"))
                        Image(systemName: copiedAddress ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(copiedAddress ? DeskColor.rise.color : DeskColor.nightMuted.color)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy address")
                HStack(spacing: 12) {
                    Button(action: onFollowing) {
                        (Text("\(followingCount) ").bold() + Text("Following"))
                    }
                    .buttonStyle(.plain)
                    (Text("\(model.closedTrades.count) ").bold() + Text(model.closedTrades.count == 1 ? "trade" : "trades"))
                    if !sinceText.isEmpty { Text(sinceText) }
                }
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(DeskColor.nightMuted.color)
                .lineLimit(1)
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Portfolio

    private var portfolio: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Button { withAnimation(.snappy) { hidesBalance.toggle() } } label: {
                        if hidesBalance {
                            HStack(spacing: 8) { ForEach(0..<5, id: \.self) { _ in Circle().fill(Color.white).frame(width: 11, height: 11) } }
                                .frame(height: 40)
                        } else {
                            AmountText(totalInCurrency, size: 36).contentTransition(.numericText())
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Total balance")
                    portfolioCaption
                }
                Spacer(minLength: 8)
                HStack(spacing: 2) {
                    ForEach(Range.allCases) { item in
                        Button { withAnimation(.snappy(duration: 0.2)) { range = item } } label: {
                            Text(item.rawValue)
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(range == item ? DeskColor.nightText.color : DeskColor.nightMuted.color)
                                .padding(.horizontal, 9)
                                .frame(height: 26)
                                .background(range == item ? Color.white.opacity(0.14) : .clear, in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            equityChart.padding(.top, 14)
        }
    }

    /// The change over the chosen window when the log has it; the open PnL otherwise.
    private var portfolioCaption: some View {
        HStack(spacing: 6) {
            if hidesBalance {
                Text("Hidden").foregroundStyle(DeskColor.nightMuted.color)
            } else if let change = chartChange {
                Text(DisplayCurrency.shared.format(change.money, signed: true) + String(format: " (%+.2f%%)", change.percent))
                    .foregroundStyle((change.money.isNegative ? DeskColor.fall : DeskColor.rise).color)
                Text(range.rawValue).foregroundStyle(DeskColor.nightMuted.color)
            } else if let pnl = totalPositionPnL {
                Text(DisplayCurrency.shared.format(pnl, signed: true))
                    .foregroundStyle((pnl.isNegative ? DeskColor.fall : DeskColor.rise).color)
                Text("open PnL").foregroundStyle(DeskColor.nightMuted.color)
            } else {
                Text("AUSD · \(model.network.name)").foregroundStyle(DeskColor.nightMuted.color)
            }
        }
        .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
    }

    /// Worth over time, as this phone has seen it. A single reading is a level line: the
    /// chart starts flat and earns its shape.
    private var equityChart: some View {
        let points = chartPoints
        let up = (points.last ?? 0) >= (points.first ?? 0)
        return ZStack {
            if points.count >= 2, points.contains(where: { $0 != points[0] }) {
                Sparkline(values: points, tint: up ? DeskColor.rise : DeskColor.fall)
            } else {
                Rectangle()
                    .fill(Color.white.opacity(0.10))
                    .frame(height: 0.5)
                Text(points.isEmpty ? "Draws itself as Desk is used" : "Level so far")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color.opacity(0.75))
                    .padding(.horizontal, 8)
                    .background(Color.black.opacity(0.6), in: Capsule())
            }
        }
        .frame(height: 84)
        .frame(maxWidth: .infinity)
    }

    // MARK: Cash

    /// The one row that answers "what can I trade with", with the two things to do about it.
    private var cashRow: some View {
        HStack(spacing: 12) {
            TokenLogo(asset: .ausd, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text("Available to trade")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
                Text(hidesBalance ? "•••••" : "\(model.collateral.value?.display() ?? Unavailable.text) desk · \(model.walletAUSD.value?.display() ?? Unavailable.text) wallet")
                    .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 8)
            squareButton(symbol: "plus", label: "Add funds", action: onFund)
            squareButton(symbol: "arrow.up", label: "Withdraw", isEnabled: canWithdraw, action: onWithdraw)
        }
        .frame(height: 52)
    }

    private func monRow(_ spare: NativeAmount) -> some View {
        Button(action: onSwap) {
            HStack(spacing: 12) {
                MonochromeSymbolMark(symbol: "arrow.triangle.2.circlepath", size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("MON")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                    Text(hidesBalance ? "•••••" : "\(spare.display(fractionDigits: 2)) MON · swap for AUSD")
                        .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(DeskColor.nightMuted.color)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func squareButton(symbol: String, label: String, isEnabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(DeskColor.nightText.color)
                .frame(width: 44, height: 44)
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .homeGlass(interactive: true, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .opacity(isEnabled ? 1 : 0.42)
        .disabled(!isEnabled)
        .accessibilityLabel(label)
    }

    // MARK: Setup

    /// Shown while this network has no Perpl account. The rest of Profile stays usable, so
    /// a switch to mainnet lands here rather than back at onboarding.
    private var setupCard: some View {
        let mainnet = model.network.holdsRealFunds
        return Button(action: onSetup) {
            HStack(spacing: 12) {
                DeskBrandMark(size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start trading on \(model.network.shortName.lowercased())")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                    Text(mainnet ? "Send AUSD, or MON to swap, then open your Perpl account."
                                 : "Get free test funds, then open your Perpl account.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DeskColor.nightText.color)
            }
            .padding(14)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(mainnet ? DeskColor.action.color.opacity(0.35) : Color.white.opacity(0.08), lineWidth: 0.75))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: Positions

    private var ledger: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(book == .open ? "Positions (\(positionContexts.count + spot.holdings.count))" : "Closed (\(model.closedTrades.count))")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
                Spacer()
                HStack(spacing: 2) {
                    ForEach(Book.allCases, id: \.self) { item in
                        Button { withAnimation(.snappy(duration: 0.2)) { book = item } } label: {
                            Text(item.rawValue)
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(book == item ? DeskColor.nightText.color : DeskColor.nightMuted.color)
                                .padding(.horizontal, 11)
                                .frame(height: 28)
                                .background(book == item ? Color.white.opacity(0.16) : .clear, in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(Color.white.opacity(0.07), in: Capsule())
            }
            if book == .open {
                HStack(spacing: 8) {
                    ForEach(Filter.allCases) { item in
                        Button { withAnimation(.snappy(duration: 0.2)) { filter = item } } label: {
                            Text(item.rawValue)
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(filter == item ? DeskColor.night.color : DeskColor.nightText.color)
                                .padding(.horizontal, 12)
                                .frame(height: 28)
                                .background(filter == item ? DeskColor.nightText.color : Color.white.opacity(0.08), in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            VStack(spacing: 0) {
                switch book {
                case .open: openRows
                case .closed: closedRows
                }
            }
        }
    }

    @ViewBuilder
    private var openRows: some View {
        let perps = filter == .tokens ? [] : positionContexts
        let tokens = filter == .perps ? [] : spot.holdings
        if perps.isEmpty && tokens.isEmpty {
            emptyLine(filter == .tokens ? "No tokens bought through Desk yet" : "No open positions", action: onTrade)
        } else {
            ForEach(perps) { position in
                ledgerRow(
                    mark: { MarketTokenLogo(symbol: position.market.symbol, size: 40) },
                    title: "\(position.figures.side == .long ? "Long" : "Short") \(position.market.symbol) · \(position.figures.leverageHundredths / 100)×",
                    subtitle: positionSubtitle(position.figures),
                    value: hidesBalance ? "•••••" : (position.figures.unrealisedPnL.isNegative ? "" : "+") + position.figures.unrealisedPnL.display() + " AUSD",
                    detail: Self.percent(position.figures.returnOnMarginMicros) + " on margin",
                    tint: position.figures.isProfit ? DeskColor.rise : DeskColor.fall) {
                        market.select(position.market)
                        selectedPosition = position.held
                        Task { await model.trading.selectMarket(position.market) }
                    }
            }
            ForEach(tokens) { holding in
                ledgerRow(
                    mark: { MarketTokenLogo(symbol: holding.purchase.symbol, size: 40, remoteURL: TokenArtwork.url(holding.purchase.logoURL)) },
                    title: holding.purchase.symbol,
                    subtitle: holding.balance.map { "\($0) on \(holding.purchase.chainName)" } ?? holding.purchase.chainName,
                    value: hidesBalance ? "•••••" : holding.value.map { DisplayCurrency.shared.format($0) } ?? Unavailable.text,
                    detail: holding.changeSincePaid.map { Self.percent(Int($0 * 1_000_000)) + " since buy" },
                    tint: (holding.changeSincePaid ?? 0) < 0 ? DeskColor.fall : DeskColor.rise,
                    action: onSpot)
            }
        }
    }

    @ViewBuilder
    private var closedRows: some View {
        let trades = model.closedTrades
        if trades.isEmpty {
            emptyLine("Nothing closed on \(model.network.shortName.lowercased()) yet", action: onTrade)
        } else {
            ForEach(trades.prefix(12)) { trade in
                let symbol = market.market(id: trade.marketID)?.symbol ?? "#\(trade.marketID)"
                let pnl = trade.realisedPnLRaw.flatMap { Money(raw: $0) }
                ledgerRow(
                    mark: { MarketTokenLogo(symbol: symbol, size: 40) },
                    title: "\(trade.isLong ? "Long" : "Short") \(symbol) · \(trade.leverageHundredths / 100)×",
                    subtitle: "Closed " + trade.closedAt.formatted(.dateTime.day().month(.abbreviated)),
                    value: hidesBalance ? "•••••" : pnl.map { ($0.isNegative ? "" : "+") + $0.display() + " AUSD" } ?? Unavailable.text,
                    detail: nil,
                    tint: (pnl?.isNegative ?? false) ? DeskColor.fall : DeskColor.rise,
                    action: onActivity)
            }
        }
    }

    private func emptyLine(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(text)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// One line of the ledger: no container, a hairline under it, figures on the right.
    private func ledgerRow<Mark: View>(
        @ViewBuilder mark: @escaping () -> Mark, title: String, subtitle: String,
        value: String, detail: String?, tint: DeskRGB, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                mark()
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(value)
                        .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(tint.color)
                        .lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                            .foregroundStyle(DeskColor.nightMuted.color)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.vertical, 11)
            .overlay(alignment: .bottom) { hairline.padding(.leading, 52) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Liquidation distance rather than size, because distance is the figure that
    /// changes and the one that can end the position.
    private func positionSubtitle(_ position: PositionFigures) -> String {
        guard let distance = position.liquidationDistanceMicros else { return "Liq. \(Unavailable.text)" }
        return distance == 0 ? "At liquidation" : "Liq. \(Self.percent(distance, signed: false)) away"
    }

    /// Micros to a percentage, truncated. A gain is never rounded up into one it is not.
    static func percent(_ micros: Int, signed: Bool = true) -> String {
        Percent.micros(micros, signed: signed)
    }

    /// The key's state rather than a countdown. Unlocked goes through to Account; locked
    /// goes straight to Face ID, because that is the only thing a person tapping a locked
    /// key wants.
    private var sessionRow: some View {
        Button {
            if model.isKeyUnlocked { onAccount() } else { Task { await model.unlock() } }
        } label: {
            HStack(spacing: 12) {
                MonochromeSymbolMark(symbol: model.isKeyUnlocked ? "faceid" : "lock.fill", size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Face ID trading key")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
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
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct MonochromeSymbolMark: View {
    let symbol: String
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(DeskColor.nightText.color)
            .frame(width: size, height: size)
            .contentTransition(.symbolEffect(.replace))
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
