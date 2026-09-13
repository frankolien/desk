import DeskUI
import SwiftUI

struct SignalsScreen: View {
    enum Feed: String, CaseIterable, Identifiable { case following = "Following", smartMoney = "Smart Money"; var id: Self { self } }
    @State private var feed = Feed.following
    @State private var selectedSignal: SignalPreview?

    init() {
        if ProcessInfo.processInfo.arguments.contains("signal-detail") {
            _selectedSignal = State(initialValue: SignalPreview.following[1])
        }
    }

    private var signals: [SignalPreview] { feed == .following ? SignalPreview.following : SignalPreview.smartMoney }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 14) {
                        Spacer(minLength: 70)
                        Picker("Signal feed", selection: $feed) {
                            ForEach(Feed.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented).frame(width: 220, height: 46)
                        Button { } label: {
                            Image(systemName: "info").font(.system(size: 19, weight: .semibold)).frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain).signalGlass(interactive: true, in: Circle())
                    }
                    .padding(.bottom, 18)

                    Text("Signals").font(.system(size: 30, weight: .bold, design: .rounded)).padding(.bottom, 24)
                    Text(feed == .following ? "Recent trades from wallets you follow." : "Recent trades from consistently profitable wallets.")
                        .font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary).padding(.bottom, 19)

                    ForEach(signals) { signal in
                        Button { selectedSignal = signal } label: { SignalRow(signal: signal) }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 112)
            }
            .background(Color(.systemBackground)).toolbar(.hidden, for: .navigationBar)
            .sheet(item: $selectedSignal) { signal in
                SignalTokenDetail(signal: signal)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(38)
                    .presentationBackground(Color(.secondarySystemBackground))
            }
        }
    }
}

private struct SignalPreview: Identifiable, Hashable {
    let id: Int, trader: String, age: String
    let bought: Bool
    let amount: String, symbol: String, name: String, change: String, liquidity: String

    static let following = [
        SignalPreview(id: 1, trader: "Fqoj…Maiv", age: "8m ago", bought: false, amount: "$176.80", symbol: "urcoin", name: "ur coin", change: "−36.95%", liquidity: "$12.09K"),
        SignalPreview(id: 2, trader: "Fqoj…Maiv", age: "20m ago", bought: false, amount: "$406.66", symbol: "wtf", name: "wtf bird", change: "+43.14%", liquidity: "$6,846.54"),
        SignalPreview(id: 3, trader: "Fqoj…Maiv", age: "24m ago", bought: true, amount: "$297.67", symbol: "wtf", name: "wtf bird", change: "+43.14%", liquidity: "$6,846.54"),
        SignalPreview(id: 4, trader: "Fqoj…Maiv", age: "1h ago", bought: true, amount: "$100.00", symbol: "INDEX", name: "INDEX Launchpad", change: "−26.80%", liquidity: "$114.43K"),
        SignalPreview(id: 5, trader: "Idoj…Maiu", age: "2h ago", bought: true, amount: "$2,000.00", symbol: "INDEX", name: "INDEX Launchpad", change: "+8.64%", liquidity: "$114.43K")
    ]
    static let smartMoney = [
        SignalPreview(id: 11, trader: "7ttJ…v9iQs", age: "2m ago", bought: true, amount: "$18,420", symbol: "SOL", name: "Solana", change: "+8.42%", liquidity: "$48.0M"),
        SignalPreview(id: 12, trader: "4Be9…3ha7t", age: "6m ago", bought: false, amount: "$6,400", symbol: "HYPE", name: "Hyperliquid", change: "+7.57%", liquidity: "$212M"),
        SignalPreview(id: 13, trader: "8sHQ…p3kL", age: "18m ago", bought: true, amount: "$9,800", symbol: "BTC", name: "Bitcoin", change: "+1.28%", liquidity: "$1.4B")
    ]
}

private struct SignalRow: View {
    let signal: SignalPreview
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 9) {
                ZStack(alignment: .bottomTrailing) {
                    Circle().fill(Color(.secondarySystemFill)).frame(width: 34, height: 34)
                    Image(systemName: "person.fill").font(.system(size: 15)).foregroundStyle(.secondary)
                    Circle().fill(signal.bought ? DeskColor.rise.color : DeskColor.fall.color).frame(width: 8, height: 8)
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(signal.trader).font(.system(size: 14, weight: .semibold))
                    Text("Following").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                }
                Spacer(); Text(signal.age).font(.system(size: 12, weight: .medium)).foregroundStyle(.tertiary)
            }
            HStack(spacing: 12) {
                SignalTokenMark(symbol: signal.symbol, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(signal.bought ? "Bought" : "Sold").foregroundStyle(signal.bought ? DeskColor.rise.color : DeskColor.fall.color)
                        Text(signal.amount); Text(signal.symbol)
                    }
                    .font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(signal.name).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    Text("24H \(signal.change) · LIQ \(signal.liquidity)").font(.system(size: 12, weight: .medium)).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 5)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 14).overlay(alignment: .bottom) { Divider().padding(.leading, 5) }.contentShape(Rectangle())
    }
}

private struct SignalTokenDetail: View {
    enum Section: String, CaseIterable, Identifiable { case transactions = "Transactions", holders = "Holders", orders = "Order Book", info = "Info"; var id: Self { self } }
    let signal: SignalPreview
    @State private var section = Section.transactions
    @State private var metric = "Price"

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(.secondarySystemBackground).ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    tokenHeader.padding(.top, 30)
                    priceSummary.padding(.top, 18)
                    SignalCandleChart().frame(height: 320).padding(.top, 18)
                    rangeSelector.padding(.top, 12)
                    Picker("Token information", selection: $section) { ForEach(Section.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).padding(.top, 12)
                    sectionContent.padding(.top, 16)
                }
                .padding(.horizontal, 16).padding(.bottom, 120)
            }
            .background(Color(.secondarySystemBackground))
        }
        .safeAreaInset(edge: .bottom) { actionBar.padding(.horizontal, 28).padding(.bottom, 8) }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var tokenHeader: some View {
        HStack {
            SignalTokenMark(symbol: signal.symbol, size: 50)
            VStack(alignment: .leading, spacing: 2) {
                Text(signal.symbol).font(.system(size: 18, weight: .bold))
                Text(signal.name).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { } label: { Image(systemName: "star").font(.system(size: 20)).frame(width: 44, height: 44) }
                .buttonStyle(.plain).signalGlass(interactive: true, in: Circle())
        }
    }

    private var priceSummary: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 13) {
                Text("$0.00005644").font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                HStack(spacing: 8) {
                    Text("↓ −38.87%").font(.system(size: 14, weight: .bold)).foregroundStyle(DeskColor.fall.color)
                    Text("1H").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 6)
                        .overlay(Capsule().stroke(Color.secondary.opacity(0.35)))
                }
            }
            Spacer()
            Picker("Metric", selection: $metric) { Text("Price").tag("Price"); Text("MC").tag("MC") }
                .pickerStyle(.segmented).frame(width: 104)
        }
    }

    private var rangeSelector: some View {
        HStack(spacing: 0) {
            ForEach(["LIVE", "1m", "5m", "15m", "1H", "4H"], id: \.self) { range in
                Text(range).font(.system(size: 14, weight: .bold)).foregroundStyle(range == "1H" ? .primary : .secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(range == "1H" ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.clear), in: Capsule())
            }
        }
    }

    @ViewBuilder private var sectionContent: some View {
        switch section {
        case .transactions: TransactionsTable(symbol: signal.symbol)
        case .holders: HoldersTable(symbol: signal.symbol)
        case .orders:
            ContentUnavailableView("No active orders", systemImage: "list.bullet", description: Text("Active DCA orders for this token will appear here."))
                .frame(maxWidth: .infinity, minHeight: 300)
        case .info: TokenInfo()
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 26) {
                Button { } label: { Image(systemName: "square.and.arrow.up") }
                Button { } label: { Image(systemName: "scope") }
            }.font(.system(size: 20)).frame(height: 54).padding(.horizontal, 22).signalGlass(interactive: true, in: Capsule())
            Spacer()
            Menu {
                Button("Limit Order", systemImage: "arrow.down.circle.fill") { }
                Button("Take Profit", systemImage: "chart.line.uptrend.xyaxis.circle.fill") { }
                Button("Stop Loss", systemImage: "chart.line.downtrend.xyaxis.circle.fill") { }
            } label: { Text("Buy").font(.system(size: 17)).frame(width: 64, height: 54) }
                .signalGlass(interactive: true, in: Capsule())
            Button { } label: { Text("Sell").font(.system(size: 17)).frame(width: 64, height: 54) }
                .buttonStyle(.plain).signalGlass(interactive: true, in: Capsule())
        }.foregroundStyle(.primary)
    }
}

private struct SignalCandleChart: View {
    private let candles: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(0.62,0.57,0.66,0.53),(0.58,0.61,0.65,0.55),(0.61,0.55,0.63,0.51),(0.55,0.50,0.59,0.47),(0.50,0.56,0.60,0.47),(0.56,0.48,0.62,0.45),(0.48,0.52,0.56,0.46),(0.52,0.67,0.70,0.48),(0.67,0.72,0.76,0.62),(0.72,0.64,0.75,0.60),(0.64,0.57,0.67,0.54),(0.57,0.48,0.60,0.45),(0.48,0.42,0.52,0.38),(0.42,0.36,0.47,0.32),(0.36,0.42,0.48,0.31),(0.42,0.39,0.46,0.35),(0.39,0.52,0.56,0.34),(0.52,0.46,0.55,0.43),(0.46,0.36,0.49,0.33),(0.36,0.31,0.39,0.28)]
    var body: some View {
        Canvas { context, size in
            let width = size.width - 52
            for i in 0...4 { let y = size.height * CGFloat(i) / 4; var p = Path(); p.move(to: .init(x: 0, y: y)); p.addLine(to: .init(x: width, y: y)); context.stroke(p, with: .color(Color.secondary.opacity(0.16)), style: .init(lineWidth: 1, dash: [2,4])) }
            for i in 0...5 { let x = width * CGFloat(i) / 5; var p = Path(); p.move(to: .init(x: x, y: 0)); p.addLine(to: .init(x: x, y: size.height)); context.stroke(p, with: .color(Color.secondary.opacity(0.13)), style: .init(lineWidth: 1, dash: [2,4])) }
            let step = width / CGFloat(candles.count)
            for (i, c) in candles.enumerated() {
                let color = c.1 < c.0 ? DeskColor.rise.color : DeskColor.fall.color
                let x = CGFloat(i) * step + step / 2; func y(_ v: CGFloat) -> CGFloat { size.height * v }
                var wick = Path(); wick.move(to: .init(x: x, y: y(c.2))); wick.addLine(to: .init(x: x, y: y(c.3))); context.stroke(wick, with: .color(color), lineWidth: 1.2)
                context.fill(Path(roundedRect: CGRect(x: x-step*0.3, y: min(y(c.0),y(c.1)), width: step*0.6, height: max(4,abs(y(c.1)-y(c.0)))), cornerRadius: 2), with: .color(color))
            }
        }
        .overlay(alignment: .topTrailing) { Text("0.0000430").font(.caption2).foregroundStyle(.secondary) }
        .overlay(alignment: .trailing) { Text("0.0000289").font(.caption2).foregroundStyle(.secondary) }
        .overlay(alignment: .bottomTrailing) { Text("0.0000065").font(.caption2).foregroundStyle(.secondary) }
        .accessibilityLabel("One hour token price candlestick chart")
    }
}

private struct TransactionsTable: View {
    let symbol: String
    private let rows = [("7s","SELL","149K","$0.95","CCC2r…mhSn1"),("10s","SELL","287K","$1.83","GPA1g…2YfU3"),("12s","BUY","2M","$9.74","2tgUb…SJoVY"),("28s","BUY","96K","$0.61","BkYvp…B6fSG")]
    var body: some View { VStack(spacing: 0) {
        HStack { Text("TX"); Spacer(); Text("Amount"); Spacer(); Text("Wallet") }.tableHeader()
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in HStack {
            Text(row.0).foregroundStyle(.secondary).frame(width: 38, alignment: .leading)
            Text(row.1).fontWeight(.bold).foregroundStyle(row.1 == "BUY" ? DeskColor.rise.color : DeskColor.fall.color).frame(width: 52)
            Spacer(); VStack(alignment: .trailing) { Text("\(row.2) \(symbol)"); Text(row.3).foregroundStyle(.secondary) }
            Spacer(); Text(row.4).foregroundStyle(.secondary).underline()
        }.font(.system(size: 12, weight: .medium)).padding(.vertical, 15).overlay(alignment: .bottom) { Divider() } }
    } }
}

private struct HoldersTable: View {
    let symbol: String
    private let rows = [("👽","BKvyp…B6fSG","530.95M","$3,422.31","55.17%"),("🐸","zzzzzzzz4444","35.99M","$231.98","3.74%"),("💸","TURIK","29.88M","$192.59","3.1%"),("🤖","BiVhq…9ZcRp","27.8M","$179.17","2.89%"),("🥷","4AGN9…J5ee9","20.57M","$132.59","2.14%")]
    var body: some View { VStack(spacing: 0) {
        HStack { Text("#   Wallet"); Spacer(); Text(symbol); Text("Value").frame(width: 78); Text("%").frame(width: 45, alignment: .trailing) }.tableHeader()
        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in HStack(spacing: 7) {
            Text("\(index+1)").foregroundStyle(.secondary).frame(width: 18, alignment: .leading); Text(row.0); Text(row.1).underline().lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(row.2).frame(width: 66, alignment: .trailing); Text(row.3).foregroundStyle(.secondary).frame(width: 76, alignment: .trailing); Text(row.4).foregroundStyle(.secondary).frame(width: 45, alignment: .trailing)
        }.font(.system(size: 11, weight: .semibold)).padding(.vertical, 17).overlay(alignment: .bottom) { Divider() } }
    } }
}

private struct TokenInfo: View {
    private let rows = [("number","Contract Address","3KsTy7…pump"),("person.circle.fill","Developer","H9TMtT…U1Th"),("chart.pie.fill","Market Cap","$6,203.49"),("chart.bar.fill","24h Volume","$255.82K"),("drop.fill","Liquidity","$6,844.62"),("person.2.fill","Holders","383"),("arrow.triangle.2.circlepath","Max Supply","962.43M"),("clock.fill","Age","30m"),("person.3.fill","Top Holders","22%")]
    var body: some View { VStack(spacing: 0) { ForEach(rows, id: \.1) { row in
        HStack { Image(systemName: row.0).frame(width: 24); Text(row.1).foregroundStyle(.secondary); Spacer(); Text(row.2).fontWeight(.semibold) }
            .font(.system(size: 14)).padding(.horizontal, 16).frame(height: 52).background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 16)).padding(.bottom, 8)
    } } }
}

private struct SignalTokenMark: View {
    let symbol: String; let size: CGFloat
    var body: some View { Group {
        if symbol == "BTC" { AssetMark.bitcoin(size: size) }
        else if symbol == "SOL" { AssetMark(glyph: "S", tint: Color(red: 0.42, green: 0.84, blue: 0.72), size: size) }
        else { ZStack { Circle().fill(Color(.secondarySystemFill)); Text(String(symbol.prefix(5)).uppercased()).font(.system(size: size*0.25, weight: .bold, design: .rounded)) }.frame(width: size, height: size) }
    } }
}

private extension View {
    func tableHeader() -> some View { font(.system(size: 11, weight: .bold)).foregroundStyle(.tertiary).padding(.vertical, 10) }
    @ViewBuilder func signalGlass<S: Shape>(interactive: Bool = false, in shape: S) -> some View {
        if #available(iOS 26.0, *) { glassEffect(.regular.interactive(interactive), in: shape) }
        else { background(.ultraThinMaterial, in: shape) }
    }
}
