import CryptoKit
import DeskUI
import Observation
import SwiftUI

/// One message in a market's room.
struct ChatMessage: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let at: Int64
    /// A stable hash of the phone that posted. It draws the avatar when no address was given.
    let who: String
    let address: String?
    let name: String?
    let text: String

    var date: Date { Date(timeIntervalSince1970: Double(at) / 1000) }
}

/// The room for one market, polled while it is on screen.
@MainActor
@Observable
final class MarketChatModel {
    private struct Room: Decodable { let here: Int; let messages: [ChatMessage] }
    private struct Posted: Decodable { let message: ChatMessage }
    private struct ServerError: Decodable { let error: String }

    private(set) var messages: [ChatMessage] = []
    private(set) var here = 0
    private(set) var symbol = ""
    private(set) var problem: String?
    private(set) var isSending = false
    private var pending: [ChatMessage] = []

    private static let endpoint = "https://web-lovat-nine-49.vercel.app/api/activity"

    var latest: ChatMessage? { messages.last }
    var mine: String? { InstallSecret.value().map(Self.who) }

    func run(symbol: String, every seconds: Double = 4) async {
        if self.symbol != symbol {
            self.symbol = symbol
            messages = []
            here = 0
        }
        while !Task.isCancelled {
            await load()
            try? await Task.sleep(for: .seconds(seconds))
        }
    }

    func load() async {
        guard !symbol.isEmpty, let install = InstallSecret.value() else { return }
        var components = URLComponents(string: Self.endpoint)!
        components.queryItems = [
            URLQueryItem(name: "view", value: "chat"),
            URLQueryItem(name: "market", value: symbol),
            URLQueryItem(name: "install", value: install),
        ]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let room = try? JSONDecoder().decode(Room.self, from: data) else { return }
        here = room.here
        let known = Set(room.messages.map(\.id))
        pending.removeAll { known.contains($0.id) }
        messages = room.messages + pending
    }

    /// Sends, and shows the message at once; the next poll confirms it or the failure says why.
    func send(_ text: String, address: String?, name: String?) async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !isSending, let install = InstallSecret.value() else { return }
        isSending = true
        problem = nil
        defer { isSending = false }
        var request = URLRequest(url: URL(string: "\(Self.endpoint)?view=chat")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: String] = ["market": symbol, "install": install, "text": body]
        if let address { payload["address"] = address }
        if let name { payload["name"] = name }
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            problem = "Couldn't reach the room. Check your connection."
            return
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let posted = try? JSONDecoder().decode(Posted.self, from: data) else {
            problem = (try? JSONDecoder().decode(ServerError.self, from: data))?.error ?? "That didn't send. Try again."
            return
        }
        pending.append(posted.message)
        messages.append(posted.message)
    }

    /// The same derivation the server uses, so this phone can recognise its own messages.
    private static func who(_ install: String) -> String {
        let digest = SHA256.hash(data: Data("chat:\(install)".utf8)).map { String(format: "%02x", $0) }.joined()
        return String(digest.prefix(16))
    }
}

/// The room, full screen: who is here, what they are saying, and a line to say something.
struct MarketChatSheet: View {
    let chat: MarketChatModel
    let market: MarketModel
    let holders: MarketHoldersModel
    let model: AppModel
    let onClose: () -> Void

    @State private var draft = ""
    @FocusState private var composing: Bool

    private var ownName: String? {
        guard let address = model.address?.checksummed else { return nil }
        return IdentityDirectory.shared.name(for: address)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if chat.messages.isEmpty {
                            Text("Nobody has said anything about \(market.symbol) yet.")
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundStyle(DeskColor.nightMuted.color)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 60)
                        }
                        ForEach(chat.messages) { message in
                            ChatMessageRow(message: message, isMine: message.who == chat.mine, position: position(for: message))
                                .id(message.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: chat.messages.last?.id) { _, id in
                    guard let id else { return }
                    withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(id, anchor: .bottom) }
                }
                .onAppear { if let id = chat.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
            }
            composer
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DeskColor.nightText.color)
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .deskGlass(interactive: true, in: Circle())
            .accessibilityLabel("Close")
            MarketTokenLogo(symbol: market.symbol, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(market.symbol)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
                HStack(spacing: 5) {
                    Circle().fill(DeskColor.rise.color).frame(width: 6, height: 6)
                    Text("\(chat.here) here")
                        .font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(DeskColor.nightMuted.color)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(market.markText == "—" ? "—" : "$" + market.markText)
                    .font(.system(size: 17, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(DeskColor.nightText.color)
                    .contentTransition(.numericText())
                if let change = market.market.flatMap(market.changePercent(for:)) {
                    Text(String(format: "%+.2f%%", change))
                        .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(change >= 0 ? DeskColor.rise.color : DeskColor.fall.color)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if let problem = chat.problem {
                Text(problem)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(DeskColor.fall.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            HStack(spacing: 10) {
                TextField("Say something about \(market.symbol)", text: $draft, axis: .vertical)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
                    .lineLimit(1...4)
                    .focused($composing)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 46)
                    .deskGlass(in: RoundedRectangle(cornerRadius: 23, style: .continuous))
                Button(action: send) {
                    Group {
                        if chat.isSending { ProgressView().controlSize(.small).tint(DeskColor.night.color) }
                        else { Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold)) }
                    }
                    .foregroundStyle(DeskColor.night.color)
                    .frame(width: 46, height: 46)
                    .background(canSend ? DeskColor.nightText.color : Color.white.opacity(0.14), in: Circle())
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !chat.isSending }

    private func send() {
        guard canSend else { return }
        let text = draft
        draft = ""
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task { await chat.send(text, address: model.address?.checksummed, name: ownName) }
    }

    /// The poster's own position in this market, when the holders list has one for the
    /// address they gave. Unverified, like the address, and shown as a plain chip.
    private func position(for message: ChatMessage) -> MarketHolder? {
        guard let address = message.address else { return nil }
        return holders.holders.first { $0.address?.caseInsensitiveCompare(address) == .orderedSame }
    }
}

private struct ChatMessageRow: View {
    let message: ChatMessage
    let isMine: Bool
    let position: MarketHolder?

    private var displayName: String {
        if let name = message.name, !name.isEmpty { return name }
        if let address = message.address {
            return IdentityDirectory.shared.name(for: address) ?? TraderSnapshot.short(address)
        }
        return "Anon"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TraderAvatar(address: message.address ?? message.who, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(isMine ? "You" : displayName)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                        .lineLimit(1)
                    if let position {
                        Text(position.sideText)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle((position.isLong ? DeskColor.rise : DeskColor.fall).color)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background((position.isLong ? DeskColor.rise : DeskColor.fall).color.opacity(0.14), in: Capsule())
                    }
                    Text(message.date, style: .relative)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color.opacity(0.7))
                        .lineLimit(1)
                }
                Text(message.text)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
    }
}

/// The room's door on the market screen: who is in and the last thing said.
struct MarketChatPreview: View {
    let chat: MarketChatModel
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text("Live Chat")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(DeskColor.nightMuted.color)
                    Spacer()
                    Circle().fill(DeskColor.rise.color).frame(width: 6, height: 6)
                    Text("\(chat.here) here")
                        .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(DeskColor.rise.color)
                }
                HStack(spacing: 12) {
                    if let latest = chat.latest {
                        TraderAvatar(address: latest.address ?? latest.who, size: 30)
                        Text(latest.text)
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundStyle(DeskColor.nightText.color)
                            .lineLimit(1)
                    } else {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(DeskColor.nightMuted.color)
                            .frame(width: 30, height: 30)
                        Text("Be the first to say something")
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundStyle(DeskColor.nightMuted.color)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .frame(height: 58)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
