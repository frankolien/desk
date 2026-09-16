import Foundation

/// The peer went away, and why.
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

/// URLSession callbacks are documented as one-shot, but cancellation can race a pending
/// WebSocket ping and deliver more than one completion on the delegate queue. A checked
/// continuation deliberately traps on the second resume, so the callback boundary must
/// enforce the one-shot rule itself.
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

    // Both stored properties are set once in `init` and never written again; URLSession
    // and its tasks are documented as safe to use from any thread.
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

    /// The thrown error carries no close code — a refused sign-in surfaces as
    /// `NSPOSIXErrorDomain 57, "Socket is not connected"`, which is the same thing a
    /// dropped network produces. The code lives on the task and is only readable after
    /// the failure, and it is the whole difference between "your key was refused" and
    /// "you went through a tunnel".
    private func closure(or error: any Error) -> any Error {
        let code = task.closeCode.rawValue
        guard code != 0 else { return error }
        return SocketClosed(code: code, reason: task.closeReason.flatMap { String(data: $0, encoding: .utf8) })
    }
}
