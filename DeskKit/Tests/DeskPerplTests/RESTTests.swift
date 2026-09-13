import DeskAuth
import DeskNet
import Foundation
import Testing

@testable import DeskPerpl

private final class RecordingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [HTTPResponse]
    private var seen: [URLRequest] = []

    init(_ responses: [HTTPResponse]) { queued = responses }

    var requests: [URLRequest] { lock.withLock { seen } }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        lock.withLock {
            seen.append(request)
            return queued.isEmpty ? HTTPResponse(status: 200, body: Data("{}".utf8)) : queued.removeFirst()
        }
    }
}

private func signer() -> PerplSigner { PerplSigner(seed: SecureBytes(Data(repeating: 7, count: 32))) }

private func client(
    _ transport: RecordingTransport,
    retry: PerplREST.RetryPolicy = .none,
    now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_757_700_000) }
) throws -> PerplREST {
    PerplREST(configuration: try .testnet(retry: retry), transport: transport, now: now)
}

@Suite("REST targets")
struct EndpointTests {
    @Test("The query is encoded once, by us, and never handed to a normaliser")
    func queryEncodedOnce() throws {
        let endpoint = try PerplEndpoint(
            method: .get, path: "/v1/trading/orders",
            query: [(name: "market", value: "BTC PERP"), (name: "cursor", value: "a+b/c=")])
        #expect(endpoint.target == "/v1/trading/orders?market=BTC%20PERP&cursor=a%2Bb%2Fc%3D")
    }

    @Test("Non-ASCII is encoded per UTF-8 byte, not per grapheme cluster")
    func nonASCII() throws {
        // Four bytes, and the emoji is one Character. A per-Character encoder emits one
        // escape here and produces a target the gateway cannot rebuild.
        #expect(PerplEndpoint.percentEncoded("🚀") == "%F0%9F%9A%80")
        #expect(PerplEndpoint.percentEncoded("é") == "%C3%A9")
    }

    @Test("A path that would need encoding is refused rather than quietly rewritten")
    func unsafePath() {
        #expect(throws: PerplEndpoint.Failure.pathHasUnsafeCharacters("/v1/a b")) {
            try PerplEndpoint(method: .get, path: "/v1/a b")
        }
        #expect(throws: PerplEndpoint.Failure.pathMustBeAbsolute("v1/x")) {
            try PerplEndpoint(method: .get, path: "v1/x")
        }
    }

    @Test("A GET may not carry a body, because its hash would be signed and never sent")
    func bodyOnGet() {
        #expect(throws: PerplEndpoint.Failure.bodyOnGet) {
            try PerplEndpoint(method: .get, path: "/v1/x", body: Data("{}".utf8))
        }
    }
}

@Suite("REST security")
struct RESTSecurityTests {
    @Test("A non-HTTPS base URL is refused at construction")
    func httpsOnly() {
        #expect(throws: PerplREST.Failure.baseURLMustBeHTTPS(scheme: "http")) {
            try PerplREST.Configuration(baseURL: URL(string: "http://testnet.perpl.xyz/api")!, chainID: 10143)
        }
    }

    @Test("A redirect is reported, never followed")
    func redirectRefused() async throws {
        let transport = RecordingTransport([
            HTTPResponse(status: 302, body: Data(), headers: ["Location": "https://evil.example/api"])
        ])
        let rest = try client(transport)
        await rest.adopt(.init(apiKey: APIKey("pk_test"), signer: signer()))
        await #expect(throws: PerplREST.Failure.redirectRefused(status: 302)) {
            try await rest.signedData(try PerplEndpoint(method: .get, path: "/v1/trading/account-history"))
        }
        #expect(transport.requests.count == 1)
    }

    @Test("A public call carries no credential of any kind")
    func publicCallIsAnonymous() async throws {
        let transport = RecordingTransport([])
        let rest = try client(transport)
        await rest.adopt(.init(apiKey: APIKey("pk_test"), signer: signer()))
        _ = try await rest.publicData(try PerplEndpoint(method: .get, path: "/v1/pub/context"))

        let headers = try #require(transport.requests.first?.allHTTPHeaderFields)
        for name in [PerplHeaders.apiKey, PerplHeaders.signature, PerplHeaders.nonce, PerplHeaders.timestamp] {
            #expect(headers[name] == nil)
        }
    }

    @Test("An API key cannot be interpolated into a string")
    func keyDoesNotLeak() {
        let key = APIKey("pk_live_9f3a2b1c")
        #expect("\(key)" == "APIKey(hidden)")
        #expect(String(reflecting: key) == "APIKey(hidden)")
        #expect(!"\(key)".contains("9f3a2b1c"))
        #expect(key.withValue { $0 } == "pk_live_9f3a2b1c")
    }

    @Test("Ending the session leaves nothing to sign with")
    func endSession() async throws {
        let rest = try client(RecordingTransport([]))
        await rest.adopt(.init(apiKey: APIKey("pk_test"), signer: signer()))
        #expect(await rest.isSignedIn)
        await rest.endSession()
        #expect(await rest.isSignedIn == false)
        await #expect(throws: PerplREST.Failure.notSignedIn) {
            try await rest.signedData(try PerplEndpoint(method: .get, path: "/v1/trading/account-history"))
        }
    }

    @Test("Server text in an error is capped")
    func detailCapped() throws {
        let long = String(repeating: "x", count: 5_000)
        let detail = try #require(PerplREST.detail(from: Data(#"{"error":"\#(long)"}"#.utf8)))
        #expect(detail.count == 201)
        #expect(PerplREST.detail(from: Data()) == nil)
        #expect(PerplREST.detail(from: Data(#"{"message":"bad nonce"}"#.utf8)) == "bad nonce")
    }
}

@Suite("REST signing")
struct RESTSigningTests {
    /// Rebuilds the canonical string from what was actually sent and verifies the
    /// signature against it. This is the only test that proves the signed bytes and the
    /// sent bytes are the same bytes.
    private func verifyRoundTrip(_ request: URLRequest, body: Data, chainID: UInt64) throws {
        let headers = try #require(request.allHTTPHeaderFields)
        let url = try #require(request.url)
        let target = url.path + (url.query.map { "?" + $0 } ?? "")
        let timestampText = try #require(headers[PerplHeaders.timestamp])
        let timestamp = try #require(Int64(timestampText))
        let nonce = try #require(headers[PerplHeaders.nonce])
        let stamp = RequestStamp(timestampMilliseconds: timestamp, nonce: nonce)
        let method = try #require(request.httpMethod)
        let canonical = PerplCanonical.rest(
            chainID: chainID,
            method: method,
            target: String(target.dropFirst("/api".count)),
            body: body,
            stamp: stamp)
        let signature = try #require(headers[PerplHeaders.signature])
        #expect(try signer().verify(signature, over: canonical))
    }

    @Test("The signed target excludes the base URL's /api prefix")
    func apiPrefixIsNotSigned() async throws {
        let transport = RecordingTransport([])
        let rest = try client(transport)
        await rest.adopt(.init(apiKey: APIKey("pk_test"), signer: signer()))
        _ = try await rest.signedData(try PerplEndpoint(method: .get, path: "/v1/trading/account-history"))

        let request = try #require(transport.requests.first)
        #expect(request.url?.path == "/api/v1/trading/account-history")
        try verifyRoundTrip(request, body: Data(), chainID: 10143)
    }

    @Test("A POST body is signed as the exact bytes that are sent")
    func postBodySigned() async throws {
        let body = Data(#"{"scope_mask":3,"label":"desk"}"#.utf8)
        let transport = RecordingTransport([])
        let rest = try client(transport)
        await rest.adopt(.init(apiKey: APIKey("pk_test"), signer: signer()))
        _ = try await rest.signedData(try PerplEndpoint(method: .post, path: "/v1/api-key/enroll", body: body))

        let request = try #require(transport.requests.first)
        #expect(request.httpBody == body)
        try verifyRoundTrip(request, body: body, chainID: 10143)
    }

    @Test("An encoded query survives to the wire unchanged and is what was signed")
    func encodedQuerySurvives() async throws {
        let transport = RecordingTransport([])
        let rest = try client(transport)
        await rest.adopt(.init(apiKey: APIKey("pk_test"), signer: signer()))
        let endpoint = try PerplEndpoint(
            method: .get, path: "/v1/trading/orders", query: [(name: "cursor", value: "a+b c")])
        _ = try await rest.signedData(endpoint)

        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://testnet.perpl.xyz/api" + endpoint.target)
        try verifyRoundTrip(request, body: Data(), chainID: 10143)
    }
}

@Suite("REST retries")
struct RESTRetryTests {
    @Test("A read retries a 500, and each attempt is signed afresh")
    func readRetries() async throws {
        let transport = RecordingTransport([
            HTTPResponse(status: 500, body: Data("upstream".utf8)),
            HTTPResponse(status: 500, body: Data("upstream".utf8)),
            HTTPResponse(status: 200, body: Data(#"{"ok":true}"#.utf8)),
        ])
        let rest = try client(transport, retry: .init(maximumAttempts: 3, delay: .zero))
        await rest.adopt(.init(apiKey: APIKey("pk_test"), signer: signer()))
        _ = try await rest.signedData(try PerplEndpoint(method: .get, path: "/v1/trading/account-history"))

        #expect(transport.requests.count == 3)
        // The gateway burns a nonce on every attempt it sees, so a resend of the same
        // bytes would be rejected as a replay even when the first attempt never landed.
        let nonces = Set(transport.requests.compactMap { $0.allHTTPHeaderFields?[PerplHeaders.nonce] })
        #expect(nonces.count == 3)
    }

    @Test("A write is never retried")
    func writeDoesNotRetry() async throws {
        let transport = RecordingTransport([
            HTTPResponse(status: 500, body: Data()),
            HTTPResponse(status: 200, body: Data("{}".utf8)),
        ])
        let rest = try client(transport, retry: .init(maximumAttempts: 3, delay: .zero))
        await rest.adopt(.init(apiKey: APIKey("pk_test"), signer: signer()))
        await #expect(throws: PerplREST.Failure.rejected(status: 500, detail: nil)) {
            try await rest.signedData(try PerplEndpoint(method: .post, path: "/v1/api-key/enroll", body: Data("{}".utf8)))
        }
        #expect(transport.requests.count == 1)
    }

    @Test("A 401 is not retried")
    func unauthorizedDoesNotRetry() async throws {
        let transport = RecordingTransport([HTTPResponse(status: 401, body: Data(#"{"error":"bad signature"}"#.utf8))])
        let rest = try client(transport, retry: .init(maximumAttempts: 3, delay: .zero))
        await rest.adopt(.init(apiKey: APIKey("pk_test"), signer: signer()))
        await #expect(throws: PerplREST.Failure.unauthorized(status: 401, detail: "bad signature")) {
            try await rest.signedData(try PerplEndpoint(method: .get, path: "/v1/trading/account-history"))
        }
        #expect(transport.requests.count == 1)
    }
}

@Suite("REST clock")
struct RESTClockTests {
    private static let gatewayNoon = "Sun, 13 Sep 2026 12:00:00 GMT"
    private static let noon = 1_789_300_800.0

    @Test("A rejected signature under a wrong clock blames the clock")
    func skewIsDiagnosed() async throws {
        let transport = RecordingTransport([
            HTTPResponse(status: 401, body: Data(), headers: ["Date": Self.gatewayNoon])
        ])
        // The device believes it is five minutes later than the gateway does.
        let rest = try client(transport, now: { Date(timeIntervalSince1970: Self.noon + 300) })
        await rest.adopt(.init(apiKey: APIKey("pk_test"), signer: signer()))
        await #expect(throws: PerplREST.Failure.clockSkew(offByMilliseconds: 300_000)) {
            try await rest.signedData(try PerplEndpoint(method: .get, path: "/v1/trading/account-history"))
        }
    }

    @Test("A right clock leaves a 401 as a 401")
    func smallSkewIsNotBlamed() async throws {
        let transport = RecordingTransport([
            HTTPResponse(status: 401, body: Data(), headers: ["Date": Self.gatewayNoon])
        ])
        let rest = try client(transport, now: { Date(timeIntervalSince1970: Self.noon + 0.4) })
        await rest.adopt(.init(apiKey: APIKey("pk_test"), signer: signer()))
        await #expect(throws: PerplREST.Failure.unauthorized(status: 401, detail: nil)) {
            try await rest.signedData(try PerplEndpoint(method: .get, path: "/v1/trading/account-history"))
        }
        #expect(await rest.clockSkewMilliseconds == 400)
    }
}
