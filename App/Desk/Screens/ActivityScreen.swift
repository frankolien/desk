import DeskFlow
import DeskUI
import SwiftUI

struct ActivityScreen: View {
    let model: AppModel

    private enum Filter: String, CaseIterable, Identifiable {
        case all = "All", received = "Received", sent = "Sent", perpl = "Perpl"
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var entries: [ActivityEntry] = []
    @State private var state: LoadState = .loading
    @State private var filter: Filter = .all

    private enum LoadState: Equatable { case loading, loaded, unavailable(String) }

    private var shown: [ActivityEntry] {
        switch filter {
        case .all: entries
        case .received: entries.filter { $0.direction == "received" }
        case .sent: entries.filter { $0.direction == "sent" }
        case .perpl: entries.filter { $0.label == "perpl" }
        }
    }

    private var sections: [(title: String, entries: [ActivityEntry])] {
        var order: [String] = []
        var grouped: [String: [ActivityEntry]] = [:]
        for entry in shown {
            let title = Self.sectionTitle(for: entry.date)
            if grouped[title] == nil { order.append(title) }
            grouped[title, default: []].append(entry)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(Color(red: 0.11, green: 0.11, blue: 0.12).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task { await load() }
    }

    private var header: some View {
        ZStack {
            Text("Activity")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            HStack {
                circleButton("xmark") { dismiss() }
                Spacer()
                Menu {
                    Picker("Show", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    Image(systemName: filter == .all
                          ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .deskGlass(interactive: true, in: Circle())
                .accessibilityLabel("Filter activity")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 6)
    }

    private func circleButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .deskGlass(interactive: true, in: Circle())
        .accessibilityLabel("Close")
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading where entries.isEmpty:
            Spacer()
            ProgressView().controlSize(.large)
            Spacer()
        case .unavailable(let sentence) where entries.isEmpty:
            message(sentence, symbol: "exclamationmark.triangle")
        default:
            if shown.isEmpty {
                message(filter == .all ? "No activity on \(model.network.name) yet."
                                       : "Nothing \(filter.rawValue.lowercased()) yet.",
                        symbol: "clock")
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                        ForEach(sections, id: \.title) { section in
                            Text(section.title)
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 20)
                                .padding(.top, 22)
                                .padding(.bottom, 4)
                            ForEach(section.entries) { entry in
                                Button { openURL(model.network.explorer.appending(path: "tx/\(entry.hash)")) } label: {
                                    ActivityRow(entry: entry, network: model.network.holdsRealFunds ? "Monad" : "Monad testnet")
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.bottom, 40)
                }
                .refreshable { await load() }
            }
        }
    }

    private func message(_ text: String, symbol: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.4))
            Text(text)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.6))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
    }

    private func load() async {
        guard let address = model.address else { return }
        var components = URLComponents(string: "https://web-lovat-nine-49.vercel.app/api/activity")!
        components.queryItems = [
            URLQueryItem(name: "address", value: address.checksummed),
            URLQueryItem(name: "network", value: model.network.rawValue),
        ]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url) else {
            state = .unavailable("Activity couldn't be reached. Pull to try again.")
            return
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try? JSONDecoder().decode(ActivityResponse.self, from: data) else {
            state = .unavailable("Activity isn't available right now.")
            return
        }
        entries = body.entries
        state = .loaded
    }

    static func sectionTitle(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let sameYear = calendar.isDate(date, equalTo: .now, toGranularity: .year)
        return date.formatted(sameYear ? .dateTime.month(.wide) : .dateTime.month(.wide).year())
    }
}

struct ActivityEntry: Decodable, Identifiable, Sendable {
    let hash: String
    let time: Double
    let direction: String
    let counterparty: String
    let label: String?
    let symbol: String
    let amount: String

    var id: String { "\(hash)-\(symbol)-\(direction)" }
    var date: Date { Date(timeIntervalSince1970: time / 1000) }
    var isReceived: Bool { direction == "received" }
}

private struct ActivityResponse: Decodable { let entries: [ActivityEntry] }

private struct ActivityRow: View {
    let entry: ActivityEntry
    let network: String

    private var kind: String {
        switch (entry.label, entry.isReceived) {
        case ("perpl", false): "Deposited"
        case ("perpl", true): "Withdrawn"
        case ("faucet", true): "Faucet"
        case ("relay", false): "Spot buy"
        case (_, true): "Received"
        default: "Sent"
        }
    }

    private var party: String {
        let short = entry.counterparty.count > 12
            ? "\(entry.counterparty.prefix(6))…\(entry.counterparty.suffix(4))" : entry.counterparty
        switch entry.label {
        case "perpl": return entry.isReceived ? "From Perpl" : "To Perpl"
        case "faucet": return "From Agora faucet"
        case "relay": return "Via Relay"
        default: return entry.isReceived ? "From \(short)" : "To \(short)"
        }
    }

    private var amount: String {
        let sign = entry.isReceived ? "+" : "\u{2212}"
        guard let value = Double(entry.amount) else { return "\(sign)\(entry.amount) \(entry.symbol)" }
        let body: String = switch value {
        case ..<0.01: "<0.01"
        case 1_000_000...: String(format: "%.1fM", value / 1_000_000)
        case 1_000...: String(format: "%.1fK", value / 1_000)
        default: value.formatted(.number.precision(.fractionLength(0...2)))
        }
        return "\(sign)\(body) \(entry.symbol)"
    }

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if entry.symbol.uppercased() == "AUSD" {
                    TokenLogo(asset: .ausd, size: 48)
                } else {
                    MarketTokenLogo(symbol: entry.symbol, size: 48)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: entry.isReceived ? "arrow.down.left" : "arrow.up.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(entry.isReceived ? DeskColor.rise.color : Color.white.opacity(0.55))
                    Text(kind)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.55))
                }
                Text(party)
                    .font(.system(size: 16, weight: .regular, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(amount)
                    .font(.system(size: 15, weight: .regular, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.75))
                    .lineLimit(1)
                Text(network)
                    .font(.system(size: 15, weight: .regular, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.4))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}
