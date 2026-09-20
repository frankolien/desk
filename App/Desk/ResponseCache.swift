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
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            store(data, for: url)
            return (data, false)
        } catch {
            if let data = cached(url, maxAge: maxStale) { return (data, true) }
            throw error
        }
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
