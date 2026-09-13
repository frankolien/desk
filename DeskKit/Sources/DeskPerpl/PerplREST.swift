import DeskAuth
import DeskNet
import Foundation

/// Perpl's REST surface: the public reads, and the signed reads the API key authorises.
///
/// Orders do not come through here. They go over the trading websocket, which is why
/// nothing in this file retries a write.
public actor PerplREST {
    public struct Configuration: Sendable {
        public let baseURL: URL
        public let chainID: UInt64
        public let retry: RetryPolicy

        /// `baseURL` carries the `/api` prefix; `PerplEndpoint.path` does not. The
        /// gateway signs only what follows the prefix, and getting that backwards
        /// produces a signature that verifies against a string nobody built.
        public init(baseURL: URL, chainID: UInt64, retry: RetryPolicy = .default) throws {
            guard baseURL.scheme?.lowercased() == "https" else {
                throw Failure.baseURLMustBeHTTPS(scheme: baseURL.scheme)
            }
            guard baseURL.query == nil, baseURL.fragment == nil else {
                throw Failure.baseURLHasQueryOrFragment
            }
            // A trailing slash makes every target `//v1/…` on the wire while `/v1/…` was
            // signed. The gateway rebuilds the canonical string from what it received, so
            // every signed call 401s and nothing says why.
            // `URL.path` strips a trailing slash, and `absoluteString` is what the
            // target is concatenated onto, so that is what has to be checked.
            guard !baseURL.absoluteString.hasSuffix("/") else { throw Failure.baseURLHasTrailingSlash }
            self.baseURL = baseURL
            self.chainID = chainID
            self.retry = retry
        }

        public static func testnet(retry: RetryPolicy = .default) throws -> Configuration {
            try Configuration(
                baseURL: URL(string: "https://testnet.perpl.xyz/api")!, chainID: 10143, retry: retry)
        }

        public static func mainnet(retry: RetryPolicy = .default) throws -> Configuration {
            try Configuration(
                baseURL: URL(string: "https://app.perpl.xyz/api")!, chainID: 143, retry: retry)
        }
    }

    /// Reads only. A signed request cannot be replayed — the nonce is single use at the
    /// gateway — so every attempt is stamped and signed afresh rather than resent.
    public struct RetryPolicy: Sendable, Hashable {
        public let maximumAttempts: Int
        public let delay: Duration

        public init(maximumAttempts: Int, delay: Duration) {
            self.maximumAttempts = max(1, maximumAttempts)
            self.delay = delay
        }

        public static let `default` = RetryPolicy(maximumAttempts: 3, delay: .milliseconds(250))
        public static let none = RetryPolicy(maximumAttempts: 1, delay: .zero)
    }

    public enum Failure: Error, Sendable, Equatable {
        case baseURLMustBeHTTPS(scheme: String?)
        case baseURLHasQueryOrFragment
        case baseURLHasTrailingSlash
        case targetNotRepresentable(String)
        case notSignedIn
        case redirectRefused(status: Int)
        case clockSkew(offByMilliseconds: Int64)
        case unauthorized(status: Int, detail: String?)
        case rateLimited(retryAfterSeconds: Int?)
        case rejected(status: Int, detail: String?)
        case malformedResponse(String)
    }

    public typealias Credentials = PerplCredentials

    /// A measured clock difference this large alongside a rejected signature means the
    /// phone's clock, not the key. The gateway's own window is not published; this is the
    /// threshold at which we are willing to blame the clock in a sentence to the user,
    /// set well above the `Date` header's one-second resolution plus a round trip.
    public static let clockSkewToleranceMilliseconds: Int64 = 5_000

    private let configuration: Configuration
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date
    private var credentials: Credentials?
    private var observedSkewMilliseconds: Int64?

    public init(
        configuration: Configuration,
        transport: any HTTPTransport = URLSessionTransport(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.transport = transport
        self.now = now
    }

    public var isSignedIn: Bool { credentials != nil }

    /// The last measured difference between this device's clock and the gateway's.
    public var clockSkewMilliseconds: Int64? { observedSkewMilliseconds }

    public func adopt(_ credentials: Credentials) { self.credentials = credentials }

    /// Ends the signing session. The next signed call fails with `.notSignedIn` rather
    /// than reaching for a stored key, because there is none.
    public func endSession() {
        credentials = nil
        observedSkewMilliseconds = nil
    }

    // MARK: - Calls

    public func publicData(_ endpoint: PerplEndpoint) async throws -> Data {
        try await perform(endpoint, signed: false)
    }

    public func signedData(_ endpoint: PerplEndpoint) async throws -> Data {
        try await perform(endpoint, signed: true)
    }

    public func publicJSON<T: Decodable>(_ endpoint: PerplEndpoint, as type: T.Type) async throws -> T {
        try decode(type, from: try await publicData(endpoint))
    }

    public func signedJSON<T: Decodable>(_ endpoint: PerplEndpoint, as type: T.Type) async throws -> T {
        try decode(type, from: try await signedData(endpoint))
    }

    public func context() async throws -> PerplContext {
        let endpoint = try PerplEndpoint(method: .get, path: "/v1/pub/context")
        return try await publicJSON(endpoint, as: PerplContext.self).validated()
    }

    // MARK: - Machinery

    private func perform(_ endpoint: PerplEndpoint, signed: Bool) async throws -> Data {
        let attempts = endpoint.method == .get ? configuration.retry.maximumAttempts : 1
        var lastError: any Error = Failure.malformedResponse("no attempt ran")

        for attempt in 1...attempts {
            do {
                let response = try await transport.send(try await request(for: endpoint, signed: signed))
                let skew = recordSkew(from: response)
                if response.isSuccess { return response.body }
                let failure = failure(for: response, skew: skew)
                guard attempt < attempts, isWorthRetrying(failure) else { throw failure }
                lastError = failure
            } catch let error as Failure {
                throw error
            } catch {
                guard attempt < attempts else { throw error }
                lastError = error
            }
            try await Task.sleep(for: configuration.retry.delay)
        }
        throw lastError
    }

    private func isWorthRetrying(_ failure: Failure) -> Bool {
        if case .rejected(let status, _) = failure { return status >= 500 }
        return false
    }

    func request(for endpoint: PerplEndpoint, signed: Bool) async throws -> URLRequest {
        let text = configuration.baseURL.absoluteString + endpoint.target
        // `URL(string:)` parses without normalising, so a URL that survives this is one
        // whose path and query are the bytes that were signed. The equality check is what
        // makes that a guarantee rather than a belief.
        guard let url = URL(string: text), url.absoluteString == text else {
            throw Failure.targetNotRepresentable(endpoint.target)
        }

        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if endpoint.method != .get {
            request.httpBody = endpoint.body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        guard signed else { return request }
        guard let credentials else { throw Failure.notSignedIn }

        let stamp = RequestStamp.generate(now: now())
        let canonical = PerplCanonical.rest(
            chainID: configuration.chainID,
            method: endpoint.method.rawValue,
            target: endpoint.target,
            body: endpoint.body,
            stamp: stamp)
        let signature = try await credentials.sign(canonical)
        credentials.apiKey.withValue { request.setValue($0, forHTTPHeaderField: PerplHeaders.apiKey) }
        request.setValue(stamp.timestampText, forHTTPHeaderField: PerplHeaders.timestamp)
        request.setValue(stamp.nonce, forHTTPHeaderField: PerplHeaders.nonce)
        request.setValue(signature, forHTTPHeaderField: PerplHeaders.signature)
        return request
    }

    private func failure(for response: HTTPResponse, skew: Int64?) -> Failure {
        if response.isRedirect { return .redirectRefused(status: response.status) }
        let detail = Self.detail(from: response.body)
        switch response.status {
        case 401, 403:
            // Only on evidence from this very response. A skew remembered from an earlier
            // call would throw away the gateway's own reason for refusing this one.
            if let skew, skew.magnitude > UInt64(Self.clockSkewToleranceMilliseconds) {
                return .clockSkew(offByMilliseconds: skew)
            }
            return .unauthorized(status: response.status, detail: detail)
        case 429:
            return .rateLimited(retryAfterSeconds: response.headers["retry-after"].flatMap(Int.init))
        default:
            return .rejected(status: response.status, detail: detail)
        }
    }

    @discardableResult
    private func recordSkew(from response: HTTPResponse) -> Int64? {
        guard let header = response.headers["date"],
              let served = Self.httpDateFormatter.date(from: header) else { return nil }
        let local = now().timeIntervalSince1970
        let skew = Int64((local - served.timeIntervalSince1970) * 1000)
        observedSkewMilliseconds = skew
        return skew
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw Failure.malformedResponse(String(describing: type))
        }
    }

    /// Server text, capped. The gateway's own wording is what the user should read, but
    /// an unbounded string from the network has no business reaching a log line.
    static func detail(from body: Data) -> String? {
        guard !body.isEmpty else { return nil }
        let text: String
        if let wire = try? JSONDecoder().decode(WireError.self, from: body),
           let message = wire.message ?? wire.error ?? wire.detail {
            text = message
        } else if let raw = String(data: body, encoding: .utf8) {
            text = raw
        } else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count <= 200 ? trimmed : String(trimmed.prefix(200)) + "…"
    }

    private struct WireError: Decodable {
        let error: String?
        let message: String?
        let detail: String?
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()
}
