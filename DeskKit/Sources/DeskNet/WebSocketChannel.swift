import Foundation

public struct SocketClosed: Error, Sendable, Hashable {
    public let code: Int
    public let reason: String?

    public init(code: Int, reason: String?) {
        self.code = code
        self.reason = reason
    }
}

public protocol WebSocketChannel: Sendable {
    func send(_ text: String) async throws
    func receive() async throws -> String
    func ping() async throws
    func close()
}

/// Cancellation can race a pending ping and deliver a second URLSession completion, which
/// would trap a checked continuation; this enforces the one-shot rule itself.
final class OneShotVoidContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?

    init(_ continuation: CheckedContinuation<Void, any Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<Void, any Error>) {
        let pending = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(with: result)
    }
}

public final class URLSessionWebSocket: WebSocketChannel, @unchecked Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case mustBeWSS(scheme: String?)
        case unknownFrameKind
    }

    private let session: URLSession
    private let task: URLSessionWebSocketTask

    public init(url: URL, timeout: TimeInterval = 15) throws {
        guard url.scheme?.lowercased() == "wss" else { throw Failure.mustBeWSS(scheme: url.scheme) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = timeout
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        session = URLSession(configuration: configuration)
        task = session.webSocketTask(with: url)
           
        task.resume()
    }

    public func send(_ text: String) async throws {
        do { try await task.send(.string(text)) } catch { throw closure(or: error) }
    }

    public func receive() async throws -> String {
        do {
            switch try await task.receive() {
            case .string(let text): return text
            case .data(let data): return String(decoding: data, as: UTF8.self)
            @unknown default: throw Failure.unknownFrameKind
            }
        } catch {
            throw closure(or: error)
        }
    }

    public func ping() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let oneShot = OneShotVoidContinuation(continuation)
            task.sendPing { error in
                if let error { oneShot.resume(with: .failure(error)) }
                else { oneShot.resume(with: .success(())) }
            }
        }
    }

    public func close() {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

    /// A refused sign-in throws the same POSIX 57 as a dropped network; only the task's
    /// close code, readable after the failure, tells them apart.
    private func closure(or error: any Error) -> any Error {
        let code = task.closeCode.rawValue
        guard code != 0 else { return error }
        return SocketClosed(code: code, reason: task.closeReason.flatMap { String(data: $0, encoding: .utf8) })
    }
}
