import DeskFlow
import DeskMoney
import DeskPerpl
import DeskUI
import SwiftUI

/// A trade someone wants to mirror: whose it is, and its market, side and leverage.
struct CopyIntent: Identifiable, Hashable {
    let trader: String
    let market: String
    let side: Direction
    let leverage: Int
    var entry: String?
    var pnlPercent: Double?

    var id: String { "\(trader)-\(market)-\(side.rawValue)-\(leverage)" }
}

/// Their trade, then yours underneath it: same market, same side, their leverage as a
/// starting point, your own amount. One hold signs it.
struct CopyTradeSheet: View {
    let intent: CopyIntent
    let name: String
    let model: AppModel
    let market: MarketModel
    let session: TradingSession
    let onFilled: (Direction, String) -> Void
    let onDismiss: () -> Void

    @State private var amount = ""
    @State private var leverage: Int
    @State private var revealed = false
    @State private var handledFill = false
    @FocusState private var typing: Bool

    private static let quickAmounts = [25, 50, 100]

    init(intent: CopyIntent, name: String, model: AppModel, market: MarketModel, session: TradingSession,
         onFilled: @escaping (Direction, String) -> Void, onDismiss: @escaping () -> Void) {
        self.intent = intent
        self.name = name
        self.model = model
        self.market = market
        self.session = session
        self.onFilled = onFilled
        self.onDismiss = onDismiss
        _leverage = State(initialValue: max(1, intent.leverage))
    }

    private var listed: Market? { market.market }
    private var maxLeverage: Int { max(1, Int(listed?.config.maxLeverage ?? 1)) }
    private var tint: DeskRGB { intent.side.color }
    private var free: Money? { session.account.value?.free }
    private var settled: Bool { session.order.outcome == .settled }

    private var quote: OrderQuote? {
        guard let listed, let mark = market.mark.value, let margin = Money(text: amount.isEmpty ? "0" : amount),
              margin.raw > 0,
              let notionalRaw = Int64(exactly: Int128(margin.raw) * Int128(leverage)),
              let notional = Money(raw: notionalRaw),
              let size = Self.size(for: notional, mark: mark, market: listed)
        else { return nil }
        return try? OrderQuote.forMarket(
            listed, side: intent.side == .up ? .long : .short, size: size, price: mark,
            leverageHundredths: leverage * 100)
    }

    private var shortfall: Money? {
        guard let quote, let free, !quote.isAffordable(freeCollateral: free) else { return nil }
        return Money(raw: quote.total.raw - free.raw)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Copy trade").font(.system(size: 22, weight: .heavy, design: .rounded))
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill").font(.title2).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(session.isBusy)
            }

            theirs
            link
            if settled { done } else { mine }

            if let sentence = statusLine {
                Text(sentence)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(session.hasFailed || shortfall != nil ? DeskColor.fall.color : DeskColor.nightMuted.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !settled {
                HoldToConfirm(
                    title: session.isBusy ? "Copying…" : "Hold to copy \(name)",
                    tint: tint,
                    isEnabled: quote != nil && shortfall == nil && !session.isBusy && listed != nil
                ) {
                    typing = false
                    Task { await submit() }
                }
            }
        }
        .padding(24)
        .foregroundStyle(DeskColor.nightText.color)
        .preferredColorScheme(.dark)
        .fittedSheet()
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(session.isBusy)
        .onAppear {
            withAnimation(.spring(duration: 0.6, bounce: 0.28).delay(0.18)) { revealed = true }
        }
        .onChange(of: session.order.outcome) { _, outcome in
            guard outcome == .settled, !handledFill else { return }
            handledFill = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(900))
                onFilled(intent.side, intent.market)
            }
        }
    }

    // MARK: Cards

    private var theirs: some View {
        HStack(spacing: 12) {
            TraderAvatar(address: intent.trader, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.system(size: 15, weight: .bold, design: .rounded)).lineLimit(1)
                sideChip("\(intent.side.word()) \(intent.market) · \(intent.leverage)×")
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                if let entry = intent.entry {
                    Text(TraderFormat.dollars(entry, signed: false))
                        .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    Text("entry").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(DeskColor.nightMuted.color)
                }
                if let percent = intent.pnlPercent {
                    Text(String(format: "%@%.1f%%", percent < 0 ? Direction.minus : "+", abs(percent)))
                        .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle((percent < 0 ? DeskColor.fall : DeskColor.rise).color)
                }
            }
        }
        .padding(14)
        .deskGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// Three chevrons that light up one after another, top to bottom: the trade being handed down.
    private var link: some View {
        VStack(spacing: -4) {
            ForEach(0..<3, id: \.self) { index in
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(tint.color)
                    .opacity(revealed ? 1 - Double(index) * 0.28 : 0)
                    .offset(y: revealed ? 0 : -6)
                    .animation(.spring(duration: 0.45, bounce: 0.2).delay(0.1 + Double(index) * 0.09), value: revealed)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 30)
    }

    private var mine: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                TraderAvatar(address: model.address?.checksummed ?? "", size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("You").font(.system(size: 15, weight: .bold, design: .rounded))
                    sideChip("\(intent.side.word()) \(intent.market) · \(leverage)×")
                }
                Spacer(minLength: 8)
                leverageStepper
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TextField("0", text: $amount)
                    .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                    .keyboardType(.decimalPad)
                    .focused($typing)
                    .frame(maxWidth: .infinity)
                Text("AUSD")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
            }

            HStack(spacing: 8) {
                ForEach(Self.quickAmounts, id: \.self) { value in
                    chip("\(value)", selected: amount == "\(value)") { amount = "\(value)" }
                }
                if let free, free.raw > 0 {
                    chip("Max", selected: amount == free.display()) { amount = free.display() }
                }
                Spacer(minLength: 0)
            }

            figures
        }
        .padding(14)
        .deskGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .opacity(revealed ? 1 : 0)
        .scaleEffect(revealed ? 1 : 0.96, anchor: .top)
        .offset(y: revealed ? 0 : -28)
    }

    private var done: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(DeskColor.rise.color)
                .symbolEffect(.bounce, value: settled)
            VStack(alignment: .leading, spacing: 2) {
                Text("Copied").font(.system(size: 17, weight: .bold, design: .rounded))
                Text("\(intent.side.word()) \(intent.market) at \(leverage)× is open on your desk.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .deskGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .transition(.scale(scale: 0.96).combined(with: .opacity))
    }

    // MARK: Pieces

    private func sideChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(tint.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.color.opacity(0.14), in: Capsule())
    }

    private var leverageStepper: some View {
        HStack(spacing: 0) {
            stepButton("minus", enabled: leverage > 1) { leverage -= 1 }
            Text("\(leverage)×")
                .font(.system(size: 14, weight: .bold, design: .rounded).monospacedDigit())
                .frame(minWidth: 40)
                .contentTransition(.numericText())
            stepButton("plus", enabled: leverage < maxLeverage) { leverage += 1 }
        }
        .animation(.snappy(duration: 0.2), value: leverage)
        .deskGlass(in: Capsule())
    }

    private func stepButton(_ symbol: String, enabled: Bool, perform: @escaping () -> Void) -> some View {
        Button {
            perform()
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 34, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? DeskColor.nightText.color : DeskColor.nightMuted.color.opacity(0.5))
        .disabled(!enabled)
    }

    private func chip(_ text: String, selected: Bool, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(text)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(selected ? DeskColor.night.color : DeskColor.nightText.color)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(selected ? DeskColor.nightText.color : Color.white.opacity(0.1), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var figures: some View {
        HStack(spacing: 14) {
            figure("Size", quote.map { "\($0.size.display(fractionDigits: $0.size.decimals)) \(intent.market)" } ?? "—")
            figure("Liq. away", quote.map { Percent.micros($0.liquidationDistanceMicros, signed: false) } ?? "—")
            figure("Fee", quote.map { "\($0.fee.display()) AUSD" } ?? "—")
            Spacer(minLength: 0)
        }
        .redacted(reason: quote == nil && !amount.isEmpty ? .placeholder : [])
    }

    private func figure(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(DeskColor.nightMuted.color)
            Text(value).font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit()).lineLimit(1)
        }
    }

    private var statusLine: String? {
        if let shortfall, let quote {
            return "This costs \(quote.total.display()) AUSD with its fee, \(shortfall.display()) more than your free collateral."
        }
        if let text = session.statusText, session.isBusy || session.hasFailed { return text }
        if let free, amount.isEmpty { return "\(free.display()) AUSD free to trade." }
        return nil
    }

    // MARK: Order

    private static func size(for notional: Money, mark: Price, market: Market) -> Size? {
        let exponent = Int(market.config.sizeDecimals) + Int(market.config.priceDecimals)
        guard exponent >= 0, exponent <= 38 else { return nil }
        var scale = Int128(1)
        for _ in 0..<exponent { scale *= 10 }
        let raw = Int128(notional.raw) * scale / (Int128(mark.raw) * 1_000_000)
        return Int64(exactly: raw).flatMap { market.size($0) }
    }

    private func submit() async {
        guard let listed, let quote else { return }
        let draft = OrderDesk.Draft(
            side: intent.side == .up ? .long : .short,
            size: quote.size,
            leverageHundredths: leverage * 100,
            slippageBps: min(50, listed.maxMarketSlippageBps),
            protection: nil)
        await session.place(draft)
    }
}
