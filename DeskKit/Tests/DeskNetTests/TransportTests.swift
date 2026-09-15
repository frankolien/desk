import Foundation
import Testing

@testable import DeskNet

@Suite("HTTP responses")
struct HTTPResponseTests {
    @Test("Header names are matched without regard to how the server capitalised them")
    func headersAreCaseInsensitive() {
        // `Date`, `date` and `DATE` are the same header, and clock-skew detection reads
        // it by name.
        let response = HTTPResponse(
            status: 200, body: Data(), headers: ["Date": "now", "Retry-After": "30", "X-MiXeD": "1"])
        #expect(response.headers["date"] == "now")
        #expect(response.headers["retry-after"] == "30")
        #expect(response.headers["x-mixed"] == "1")
    }

    @Test("Status ranges are classified the way the callers branch on them")
    func statusRanges() {
        #expect(HTTPResponse(status: 200, body: Data()).isSuccess)
        #expect(HTTPResponse(status: 204, body: Data()).isSuccess)
        #expect(HTTPResponse(status: 299, body: Data()).isSuccess)
        #expect(HTTPResponse(status: 300, body: Data()).isSuccess == false)
        #expect(HTTPResponse(status: 301, body: Data()).isRedirect)
        #expect(HTTPResponse(status: 399, body: Data()).isRedirect)
        #expect(HTTPResponse(status: 400, body: Data()).isRedirect == false)
    }
}

@Suite("Websocket channel")
struct WebSocketChannelTests {
    @Test("Only wss is accepted")
    func secureOnly() {
        // A ws:// socket would carry the sign-in frame, and with it the API key, in clear.
        #expect(throws: URLSessionWebSocket.Failure.mustBeWSS(scheme: "ws")) {
            try URLSessionWebSocket(url: URL(string: "ws://testnet.perpl.xyz/ws/v1/trading")!)
        }
        #expect(throws: URLSessionWebSocket.Failure.mustBeWSS(scheme: "https")) {
            try URLSessionWebSocket(url: URL(string: "https://testnet.perpl.xyz/ws/v1/trading")!)
        }
    }

    @Test("A close carries its code and reason")
    func closeCarriesCause() {
        // The thrown error says only `NSPOSIXErrorDomain 57`; the code is what separates
        // a refused key from a dropped network.
        let closed = SocketClosed(code: 3401, reason: "unauthorized")
        #expect(closed.code == 3401)
        #expect(closed.reason == "unauthorized")
        #expect(closed != SocketClosed(code: 1008, reason: "idle timeout"))
    }

    @Test("A duplicate URLSession completion cannot resume a ping twice")
    func duplicatePingCompletionIsIgnored() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let oneShot = OneShotVoidContinuation(continuation)
            oneShot.resume(with: .success(()))
            oneShot.resume(with: .failure(URLError(.cancelled)))
        }
    }
}
