import CryptoKit
import Foundation
import Network
import Observation


actor ResponseCache {
    static let shared = ResponseCache()

    private let directory: URL
    private var memory: [String: (Data, Date)] = [:]

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = base.appending(path: "responses", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// What was last stored for this URL, if it is younger than `maxAge`.
    func cached(_ url: URL, maxAge: TimeInterval = 86_400) -> Data? {
        let key = Self.key(url)
        if let (data, at) = memory[key] {
            return Date.now.timeIntervalSince(at) <= maxAge ? data : nil
        }
        let file = directory.appending(path: key)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path()),
              let modified = attributes[.modificationDate] as? Date,
              Date.now.timeIntervalSince(modified) <= maxAge,
              let data = try? Data(contentsOf: file)
        else { return nil }
        memory[key] = (data, modified)
        return data
    }

    func store(_ data: Data, for url: URL) {
        let key = Self.key(url)
        memory[key] = (data, .now)
        try? data.write(to: directory.appending(path: key), options: .atomic)
    }

    /// Fetches, stores on success, and on failure returns what was last stored — so a
    /// screen that has ever loaded keeps showing something while the network is away.
    /// The flag says which it was, for callers that show "as of" when it matters.
    func data(from url: URL, maxStale: TimeInterval = 86_400) async throws -> (Data, isStale: Bool) {
        do {
            let data = try await Self.fetch(url)
            store(data, for: url)
            return (data, false)
        } catch {
            if let data = cached(url, maxAge: maxStale) { return (data, true) }
            throw error
        }
    }

    /// A timeout, a dropped connection, a 429 or a 5xx gets two more tries with a pause;
    /// no network at all does not, because the stale copy is the better answer right now.
    private static func fetch(_ url: URL) async throws -> Data {
        var pause: Duration = .milliseconds(500)
        var lastError: Error = URLError(.unknown)
        for attempt in 0..<3 {
            if attempt > 0 {
                try await Task.sleep(for: pause)
                pause *= 3
            }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                if http.statusCode == 200 { return data }
                lastError = URLError(.badServerResponse)
                if http.statusCode != 429, http.statusCode < 500 { throw lastError }
            } catch let error as URLError {
                lastError = error
                switch error.code {
                case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .badServerResponse: continue
                default: throw error
                }
            }
        }
        throw lastError
    }

    private static func key(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
@Observable
final class Connectivity {
    static let shared = Connectivity()

    private(set) var isOnline = true
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.isOnline = online }
        }
        monitor.start(queue: DispatchQueue(label: "desk.connectivity", qos: .utility))
    }
}
