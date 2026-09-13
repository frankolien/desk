import Foundation

public struct HTTPResponse: Sendable, Hashable {
    public let status: Int
    public let body: Data
    /// Lowercased names. `Date` is read for clock skew; nothing else is trusted.
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

/// Refuses every redirect by returning no follow-up request.
///
/// This is the one that matters. URLSession follows redirects by default and replays the
/// original headers at the new location, so a gateway answering 302 to an attacker's
/// host would be handed `X-API-Key` by the system, with no code of ours involved. The
/// task instead completes with the 3xx itself, which `PerplREST` rejects.
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

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        // Per-task delegate, so no session-wide delegate has to be retained and no
        // retain cycle exists to break.
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

// Deliberately absent: certificate pinning. Perpl's certificate is theirs to rotate and
// a pin that outlives it bricks the app in the field with no way to ship a fix inside a
// review cycle. Refusing redirects and requiring TLS is what is defensible here; pinning
// belongs with a remote kill switch, which this app does not have.
