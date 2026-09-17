import DeskFlow
import DeskUI
import SwiftUI

/// Every transfer in and out of this wallet on the current network, newest first.
///
/// Read from the chain through Desk's server, which holds the explorer key. Transfers to
/// Perpl, Agora's faucet and Relay are named as deposits, faucet claims and spot buys,
/// because that is what they were to the person who made them.
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
        NavigationStack {
            content
                .navigationTitle("Activity")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Picker("Show", selection: $filter) {
                                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                            }
                        } label: {
                            Image(systemName: filter == .all
                                  ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                        }
                        .accessibilityLabel("Filter activity")
                    }
                }
        }
        .preferredColorScheme(.dark)
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading where entries.isEmpty:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { DeskBackground() }
        case .unavailable(let sentence) where entries.isEmpty:
            ContentUnavailableView("Activity Unavailable", systemImage: "exclamationmark.triangle", description: Text(sentence))
                .background { DeskBackground() }
        default:
            if shown.isEmpty {
                ContentUnavailableView(
                    filter == .all ? "No Activity Yet" : "Nothing \(filter.rawValue)",
                    systemImage: "clock",
                    description: Text(filter == .all ? "Transfers on \(model.network.name) will appear here." : "Try another filter."))
                    .background { DeskBackground() }
            } else {
                GlassPage {
                    ForEach(sections, id: \.title) { section in
                        GlassSection(section.title) {
                            ForEach(section.entries) { entry in
                                Button { openURL(model.network.explorer.appending(path: "tx/\(entry.hash)")) } label: {
                                    ActivityRow(entry: entry)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .refreshable { await load() }
            }
        }
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
        HStack(spacing: 11) {
            Group {
                if entry.symbol.uppercased() == "AUSD" {
                    TokenLogo(asset: .ausd, size: 32)
                } else {
                    MarketTokenLogo(symbol: entry.symbol, size: 32)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: entry.isReceived ? "arrow.down.left" : "arrow.up.right")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(entry.isReceived ? DeskColor.rise.color : .white)
                    .frame(width: 15, height: 15)
                    .background(Color.black, in: Circle())
                    .offset(x: 3, y: 3)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(kind)
                    .fontWeight(.medium)
                Text(party)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(amount)
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .foregroundStyle(entry.isReceived ? DeskColor.rise.color : .primary)
                    .lineLimit(1)
                Text(Calendar.current.isDateInToday(entry.date) || Calendar.current.isDateInYesterday(entry.date)
                     ? entry.date.formatted(date: .omitted, time: .shortened)
                     : entry.date.formatted(.dateTime.day().month(.abbreviated)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}
