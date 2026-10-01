import DeskNet
import Foundation

/// The gateway sends no error frames: a refused sign-in, malformed JSON and an order sent
/// before authentication are all answered by closing, so the close code is the only diagnosis.
public actor PerplSocket {
    public enum Failure: Error, Sendable, Equatable {
        case signInRefused(reason: String?)
        case idleTimeout
        case closed(code: Int, reason: String?)
        case notConnected
        case notAuthenticated
        case alreadyConnected
        case handshakeTimedOut
        case malformedWalletSnapshot
        case framesAlreadyStarted
    }

    public static let signInRefusedCode = 3401
    public static let idleTimeoutCode = 1008

    /// An unauthenticated socket is closed after this long (code 1008). Face ID can outlast
    /// it, so the key is derived before opening and sign-in is the first frame written.
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
    /// Lets a handshake that finishes after its socket was torn down decline to revive it.
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

    public static func mainnet(makeChannel: @escaping ChannelFactory = { try URLSessionWebSocket(url: $0) }) -> PerplSocket {
        PerplSocket(
            url: URL(string: "wss://app.perpl.xyz/ws/v1/trading")!,
            chainID: 143,
            makeChannel: makeChannel)
    }

    public nonisolated var chainIdentifier: UInt64 { chainID }

    /// True only after the wallet snapshot: an open but unauthenticated socket answers an
    /// order by closing 3401, which would read as a refused key.
    public var isConnected: Bool { channel != nil && isAuthenticated }

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
                    // The read's own error must escape; under the frame's `try?` a closed
                    // socket would spin on `receive()` forever.
                    let text = try await channel.receive()
                    guard let frame = try? InboundFrame(payload: Data(text.utf8)) else { continue }
                    if frame.kind == .walletSnapshot {
                        guard let snapshot = try? frame.decode(WalletSnapshot.self) else {
                            throw Failure.malformedWalletSnapshot
                        }
                        return snapshot
                    }
                }
            }
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

    /// One reader, once: two readers on one socket would take alternate frames.
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
