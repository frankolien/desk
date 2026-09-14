import DeskNet
import Foundation

/// The trading websocket: sign in, receive the wallet snapshot, send orders.
///
/// Everything here follows from what the live gateway does rather than from a document.
/// It sends no error frames at all: a refused sign-in, malformed JSON and an order sent
/// before authentication are answered identically, by closing. So the only diagnosis
/// available is the close code, and the only way to avoid a bad one is to get the
/// handshake right the first time.
public actor PerplSocket {
    public enum Failure: Error, Sendable, Equatable {
        case signInRefused(reason: String?)
        case idleTimeout
        case closed(code: Int, reason: String?)
        case notConnected
        case notAuthenticated
        case alreadyConnected
        case handshakeTimedOut
        case framesAlreadyStarted
    }

    public static let signInRefusedCode = 3401
    public static let idleTimeoutCode = 1008

    /// Measured against testnet on 13 September: an unauthenticated socket is closed
    /// after 10.2 seconds with code 1008. A Face ID prompt can outlast that, so the key
    /// is derived before the socket is opened and the sign-in frame is the first thing
    /// written to it. Opening first and prompting after is the bug this number exists to
    /// forbid.
    public static let preSignInIdleSeconds = 10.2

    public typealias ChannelFactory = @Sendable (URL) throws -> any WebSocketChannel

    private let url: URL
    private let chainID: UInt64
    private let makeChannel: ChannelFactory
    private let heartbeatInterval: Duration
    private let now: @Sendable () -> Date
    private var channel: (any WebSocketChannel)?
    private var heartbeat: Task<Void, Never>?
    private var isAuthenticated = false
    private var framesStarted = false
    /// Bumped by every connect and disconnect. A handshake that finishes after its own
    /// socket was torn down compares this and declines to revive it.
    private var generation = 0

    public init(
        url: URL,
        chainID: UInt64,
        makeChannel: @escaping ChannelFactory = { try URLSessionWebSocket(url: $0) },
        heartbeatInterval: Duration = .seconds(5),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.url = url
        self.chainID = chainID
        self.makeChannel = makeChannel
        self.heartbeatInterval = heartbeatInterval
        self.now = now
    }

    public static func testnet(makeChannel: @escaping ChannelFactory = { try URLSessionWebSocket(url: $0) }) -> PerplSocket {
        PerplSocket(
            url: URL(string: "wss://testnet.perpl.xyz/ws/v1/trading")!,
            chainID: 10143,
            makeChannel: makeChannel)
    }

    /// True only after the wallet snapshot. A socket that is open but unauthenticated
    /// will answer an order by closing 3401, which the app would then report as a
    /// refused key rather than its own mistake.
    public var isConnected: Bool { channel != nil && isAuthenticated }

    /// Opens, signs in, and reads until the wallet snapshot. Returning one is the only
    /// evidence the gateway accepts the key; there is no acknowledgement frame.
    @discardableResult
    public func connect(
        credentials: PerplCredentials,
        handshakeTimeout: Duration = .seconds(8)
    ) async throws -> WalletSnapshot {
        guard channel == nil else { throw Failure.alreadyConnected }
        let channel = try makeChannel(url)
        generation += 1
        let opened = generation
        self.channel = channel
        isAuthenticated = false
        framesStarted = false

        do {
            let stamp = RequestStamp.generate(now: now())
            let signature = try await credentials.sign(PerplCanonical.signIn(chainID: chainID, stamp: stamp))
            let frame = credentials.apiKey.withValue { key in
                SignInFrame(
                    chainID: chainID, apiKey: key,
                    timestamp: stamp.timestampText, nonce: stamp.nonce, signature: signature)
            }
            try await channel.send(String(decoding: try JSONEncoder().encode(frame), as: UTF8.self))

            let snapshot = try await Self.withTimeout(handshakeTimeout, closing: channel) {
                while true {
                    // The read's own error must escape. Wrapping it in the same `try?`
                    // that tolerates an unparseable frame turns a closed socket into a
                    // loop that calls `receive()` forever at full tilt.
                    let text = try await channel.receive()
                    // An unmodelled or unparseable frame is read past, never fatal: the
                    // catalogue is larger than what this app has seen on the wire.
                    guard let frame = try? InboundFrame(payload: Data(text.utf8)) else { continue }
                    if frame.kind == .walletSnapshot, let snapshot = try? frame.decode(WalletSnapshot.self) {
                        return snapshot
                    }
                }
            }
            // A disconnect during the handshake must not be undone by its own completion.
            guard generation == opened else {
                channel.close()
                throw Failure.notConnected
            }
            isAuthenticated = true
            startHeartbeat(channel)
            return snapshot
        } catch {
            disconnect()
            throw Self.map(error)
        }
    }

    public func send(_ order: OrderRequest) async throws {
        guard let channel else { throw Failure.notConnected }
        guard isAuthenticated else { throw Failure.notAuthenticated }
        do {
            try await channel.send(String(decoding: try JSONEncoder().encode(order), as: UTF8.self))
        } catch {
            throw Self.map(error)
        }
    }

    /// One reader, once. A second call would start an independent reader on the same
    /// socket and the two would take alternate frames, so each consumer would silently
    /// miss half of its own order statuses.
    public func frames() throws -> AsyncThrowingStream<InboundFrame, any Error> {
        guard let channel, isAuthenticated else { throw Failure.notConnected }
        guard !framesStarted else { throw Failure.framesAlreadyStarted }
        framesStarted = true
        return AsyncThrowingStream { continuation in
            let reader = Task {
                do {
                    while !Task.isCancelled {
                        let text = try await channel.receive()
                        guard let frame = try? InboundFrame(payload: Data(text.utf8)) else { continue }
                        continuation.yield(frame)
                    }
                    continuation.finish()
                } catch {
                    let mapped = Self.map(error)
                    // A finished reader means this connection is unusable. Keeping the
                    // dead channel installed made the next order's reconnect fail with
                    // `alreadyConnected`, even though the UI correctly knew it was
                    // offline. Tear it down here so the same desk can reconnect cleanly.
                    self.disconnect()
                    continuation.finish(throwing: mapped)
                }
            }
            continuation.onTermination = { _ in reader.cancel() }
        }
    }

    public func disconnect() {
        generation += 1
        isAuthenticated = false
        framesStarted = false
        heartbeat?.cancel()
        heartbeat = nil
        channel?.close()
        channel = nil
    }

    /// Whether the gateway's idle timer keeps running once a socket is authenticated is
    /// not something the unauthenticated probe could answer, so the socket is kept warm
    /// rather than assumed safe.
    private func startHeartbeat(_ channel: any WebSocketChannel) {
        heartbeat = Task { [heartbeatInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: heartbeatInterval)
                guard !Task.isCancelled else { return }
                try? await channel.ping()
            }
        }
    }

    private enum Race<Value: Sendable>: Sendable {
        case finished(Value)
        case timedOut
    }

    static func map(_ error: any Error) -> any Error {
        guard let closed = error as? SocketClosed else { return error }
        switch closed.code {
        case signInRefusedCode: return Failure.signInRefused(reason: closed.reason)
        case idleTimeoutCode: return Failure.idleTimeout
        default: return Failure.closed(code: closed.code, reason: closed.reason)
        }
    }

    /// Cancelling the losing child is only a request, and a `receive()` blocked on a
    /// live socket does not honour it — the group then waits for it at scope exit, so
    /// the timeout bounds when the error is *thrown* and not when the call *returns*.
    /// Measured at two seconds against a fifty-millisecond timeout. Closing the channel
    /// is what actually unblocks the read, so that is what the timeout does.
    private static func withTimeout<T: Sendable>(
        _ duration: Duration,
        closing channel: any WebSocketChannel,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: Race<T>.self) { group in
            group.addTask { .finished(try await body()) }
            group.addTask {
                try await Task.sleep(for: duration)
                return .timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw Failure.handshakeTimedOut }
            if case .finished(let value) = first { return value }
            // Closing is the part that matters: cancelling a read blocked on a live
            // socket is only a request, and the group awaits that child on the way out.
            channel.close()
            throw Failure.handshakeTimedOut
        }
    }
}
