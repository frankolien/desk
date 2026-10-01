import Foundation

public struct HTTPResponse: Sendable, Hashable {
    public let status: Int
    public let body: Data
    public let headers: [String: String]

    public init(status: Int, body: Data, headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.headers = headers.reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }
    }

    public var isRedirect: Bool { (300..<400).contains(status) }
    public var isSuccess: Bool { (200..<300).contains(status) }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

/// Refuses every redirect: URLSession replays the original headers at the new location, which
/// would hand `X-API-Key` to another host. The 3xx itself reaches `PerplREST`, which rejects it.
private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

public struct URLSessionTransport: HTTPTransport {
    public enum Failure: Error, Equatable, Sendable {
        case notHTTP
    }

    private let session: URLSession

    public init(timeout: TimeInterval = 15) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        configuration.httpAdditionalHeaders = [:]
        session = URLSession(configuration: configuration)
    }

    /// A `URLSession` retains itself until invalidated, and SwiftUI's `State(initialValue:)` builds
    /// and drops one on every body pass, so this one invalidates itself.
    public func finish() {
        session.invalidateAndCancel()
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request, delegate: RefuseRedirects())
        guard let http = response as? HTTPURLResponse else { throw Failure.notHTTP }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String {
                headers[name] = value
            }
        }
        return HTTPResponse(status: http.statusCode, body: data, headers: headers)
    }
}

// Deliberately no certificate pinning: Perpl rotates its certificate, and a stale pin would
// brick the app in the field with no remote kill switch to recover.
