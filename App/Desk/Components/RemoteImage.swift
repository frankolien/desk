import SwiftUI
import UIKit

/// One copy of every picture for the whole app. A load that fails is tried again with a
/// growing pause, and a CDN that says the picture is gone is believed.
actor ImageStore {
    static let shared = ImageStore()
    private let images = NSCache<NSURL, UIImage>()
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    init() { images.countLimit = 600 }

    func image(for url: URL) async -> UIImage? {
        if let image = images.object(forKey: url as NSURL) { return image }
        if let task = inFlight[url] { return await task.value }
        let task = Task<UIImage?, Never> { await Self.fetch(url) }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { images.setObject(image, forKey: url as NSURL) }
        return image
    }

    private static func fetch(_ url: URL) async -> UIImage? {
        if let data = await ResponseCache.shared.cached(url, maxAge: 7 * 86_400), let image = UIImage(data: data) { return image }
        var pause: Duration = .milliseconds(600)
        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(for: pause)
                pause *= 3
            }
            if Task.isCancelled { return nil }
            guard let (data, response) = try? await URLSession.shared.data(from: url) else { continue }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200, let image = UIImage(data: data) {
                await ResponseCache.shared.store(data, for: url)
                return image
            }
            if (400..<500).contains(status), status != 429 { return nil }
        }
        return nil
    }
}

struct RemoteImage<Placeholder: View>: View {
    let url: URL?
    var fill = false
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var image: UIImage?
    @State private var round = 0

    private let rounds = 6

    var body: some View {
        ZStack {
            if let image {
                if fill { Image(uiImage: image).resizable().scaledToFill() } else { Image(uiImage: image).resizable().scaledToFit() }
            } else {
                placeholder()
            }
        }
        .task(id: "\(url?.absoluteString ?? "")#\(round)") { await load() }
        .onChange(of: Connectivity.shared.isOnline) { _, online in
            if online, image == nil, url != nil { round += 1 }
        }
    }

    private func load() async {
        guard let url else { image = nil; return }
        if let found = await ImageStore.shared.image(for: url) {
            withAnimation(.easeOut(duration: 0.2)) { image = found }
            return
        }
        // Still on screen and still without a picture: another round in a while.
        guard round < rounds else { return }
        try? await Task.sleep(for: .seconds(15 * (round + 1)))
        if !Task.isCancelled, image == nil { round += 1 }
    }
}
