import DeskUI
import Foundation
import Observation
import SwiftUI

struct TokenSignal: Decodable, Identifiable, Sendable {
    struct Buyer: Decodable, Sendable { let address: String }
    let token: String
    let symbol: String
    let chainIndex: String
    let score: Int
    let strong: Bool
    let summary: String
    let buyers: [Buyer]
    let distinct: Int
    let netUsd: Double
    let warning: String?
    let price: Double?
    var id: String { token }
}

@MainActor
@Observable
final class SignalsModel {
    static let windows = ["1h", "6h", "24h"]
    var window = "6h" { didSet { if window != oldValue { Task { await load() } } } }
    private(set) var signals: [TokenSignal] = []
    private(set) var loaded = false
    private(set) var problem: String?

    private struct Response: Decodable { let signals: [TokenSignal] }

    func run() async {
        while !Task.isCancelled {
            await load()
            try? await Task.sleep(for: .seconds(60))
        }
    }

    func load() async {
        var components = URLComponents(string: "https://web-lovat-nine-49.vercel.app/api/traders")!
        components.queryItems = [URLQueryItem(name: "view", value: "signals"), URLQueryItem(name: "window", value: window)]
        guard let url = components.url else { return }
        do {
            let (data, _) = try await ResponseCache.shared.data(from: url, maxStale: 600)
            signals = try JSONDecoder().decode(Response.self, from: data).signals
            problem = nil
        } catch {
            problem = "Signals could not be read right now."
        }
        loaded = true
    }
}

struct SmartMoneyFeed: View {
    let model: SignalsModel
    let onOpen: (TokenSignal) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Smart money")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
                Spacer()
                windowPicker
            }

            if !model.loaded {
                ForEach(0..<4, id: \.self) { index in
                    SignalRow(signal: TokenSignal(token: "0x\(index)", symbol: "TOKEN", chainIndex: "143", score: 60, strong: false,
                                                  summary: "3 top traders bought TOKEN in the last hour · +$4.2K net",
                                                  buyers: [], distinct: 3, netUsd: 4200, warning: nil, price: 0.01), isLast: index == 3)
                        .redacted(reason: .placeholder)
                }
                .padding(.top, 6)
            } else if let problem = model.problem, model.signals.isEmpty {
                Label(problem, systemImage: "exclamationmark.circle.fill")
                    .font(DeskType.caption)
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .padding(.top, 14)
            } else if model.signals.isEmpty {
                Text("Nothing passes the bar in the last \(model.window): two or more qualified wallets buying, real net inflow, and fresh.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.signals.enumerated()), id: \.element.id) { index, signal in
                        Button { onOpen(signal) } label: {
                            SignalRow(signal: signal, isLast: index == model.signals.count - 1)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 6)
            }

            Text("Counted from wallets with a record: top Perpl traders, wallets people here track, and wallets that win more than they lose. Score is buyers, net inflow, first buys and freshness, minus concentration.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(DeskColor.nightMuted.color.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 18)
        }
    }

    private var windowPicker: some View {
        HStack(spacing: 2) {
            ForEach(SignalsModel.windows, id: \.self) { window in
                Button { withAnimation(.easeOut(duration: 0.18)) { model.window = window } } label: {
                    Text(window)
                        .font(.system(size: 12, weight: model.window == window ? .bold : .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(model.window == window ? Color.white.opacity(0.22) : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.1), in: Capsule())
    }
}

private struct SignalRow: View {
    let signal: TokenSignal
    let isLast: Bool

    var body: some View {
        HStack(spacing: 14) {
            MarketTokenLogo(symbol: signal.symbol, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(signal.symbol)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                        .lineLimit(1)
                    if let warning = signal.warning {
                        Text(warning)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(DeskColor.action.color)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(DeskColor.action.color.opacity(0.14), in: Capsule())
                            .lineLimit(1)
                    }
                }
                Text(signal.summary)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text("\(signal.score)")
                    .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(signal.strong ? DeskColor.onAction.color : DeskColor.nightText.color)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(signal.strong ? DeskColor.rise.color : Color.white.opacity(0.12), in: Capsule())
                Text(signal.netUsd >= 0 ? "+\(Self.compact(signal.netUsd))" : "−\(Self.compact(-signal.netUsd))")
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(signal.netUsd >= 0 ? DeskColor.rise.color : DeskColor.fall.color)
            }
        }
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) {
            if !isLast { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5).padding(.leading, 58) }
        }
        .contentShape(Rectangle())
    }

    private static func compact(_ value: Double) -> String {
        if value >= 1_000_000 { return String(format: "$%.1fM", value / 1_000_000) }
        if value >= 1_000 { return String(format: "$%.1fK", value / 1_000) }
        return String(format: "$%.0f", value)
    }
}

struct TrackWalletSheet: View {
    /// Nil starts a new one.
    let existing: TrackedWallet?
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var name = ""
    @State private var minUsd: Double = 250
    @State private var firstBuysOnly = false
    @State private var problem: String?

    private static let minimums: [Double] = [50, 250, 1_000, 5_000]

    init(existing: TrackedWallet?) {
        self.existing = existing
        _address = State(initialValue: existing?.address ?? "")
        _name = State(initialValue: existing?.name ?? "")
        _minUsd = State(initialValue: existing?.minUsd ?? 250)
        _firstBuysOnly = State(initialValue: existing?.firstBuysOnly ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(existing == nil ? "Track a wallet" : "Tracked wallet")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(DeskColor.nightText.color)

            VStack(alignment: .leading, spacing: 8) {
                Text("Address").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(DeskColor.nightMuted.color)
                HStack {
                    TextField("0x…", text: $address)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(existing != nil)
                    if existing == nil {
                        Button {
                            if let pasted = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) { address = pasted }
                        } label: {
                            Image(systemName: "doc.on.clipboard").font(.system(size: 14, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(DeskColor.nightText.color)
                    }
                }
                .padding(12)
                .background(DeskColor.nightChip.color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Name").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(DeskColor.nightMuted.color)
                TextField("Optional", text: $name)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .padding(12)
                    .background(DeskColor.nightChip.color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Tell me about trades over").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(DeskColor.nightMuted.color)
                HStack(spacing: 6) {
                    ForEach(Self.minimums, id: \.self) { value in
                        Button { minUsd = value } label: {
                            Text(value >= 1_000 ? "$\(Int(value / 1_000))K" : "$\(Int(value))")
                                .font(.system(size: 13, weight: minUsd == value ? .bold : .medium, design: .rounded))
                                .foregroundStyle(DeskColor.nightText.color)
                                .frame(maxWidth: .infinity).frame(height: 36)
                                .background(minUsd == value ? Color.white.opacity(0.22) : Color.white.opacity(0.08), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Toggle(isOn: $firstBuysOnly) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Only first buys and closes").font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(DeskColor.nightText.color)
                    Text("Skips adds and partial sells.").font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(DeskColor.nightMuted.color)
                }
            }
            .tint(DeskColor.rise.color)

            if let problem {
                Text(problem).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(DeskColor.fall.color)
            }

            HStack(spacing: 10) {
                if existing != nil {
                    Button(role: .destructive) {
                        TrackedWallets.shared.untrack(address)
                        dismiss()
                    } label: {
                        Text("Stop tracking").frame(maxWidth: .infinity).frame(height: 50)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DeskColor.fall.color)
                    .background(DeskColor.fall.color.opacity(0.12), in: Capsule())
                }
                Button(action: save) {
                    Text(existing == nil ? "Track" : "Save").frame(maxWidth: .infinity).frame(height: 50)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DeskColor.onAction.color)
                .background(DeskColor.action.color, in: Capsule())
            }
            .font(.system(size: 15, weight: .bold, design: .rounded))

            Text("Pushed within a couple of minutes of the trade landing on Monad. Twenty an hour at most, then a digest.")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(DeskColor.nightMuted.color.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .background(DeskColor.night.color)
    }

    private func save() {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing {
            TrackedWallets.shared.update(TrackedWallet(address: existing.address, name: String(name.prefix(24)), minUsd: minUsd, firstBuysOnly: firstBuysOnly))
            dismiss()
            return
        }
        guard TrackedWallets.isValid(trimmed) else { problem = "That is not a wallet address."; return }
        guard !TrackedWallets.shared.isTracking(trimmed) else { problem = "Already tracked."; return }
        guard !TrackedWallets.shared.isFull else { problem = "You can track \(TrackedWallets.limit) wallets."; return }
        TrackedWallets.shared.track(trimmed, name: name)
        TrackedWallets.shared.update(TrackedWallet(address: trimmed, name: String(name.prefix(24)), minUsd: minUsd, firstBuysOnly: firstBuysOnly))
        Task { await IdentityDirectory.shared.resolve([trimmed]) }
        dismiss()
    }
}
