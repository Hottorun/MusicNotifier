//
//  CachedAsyncImage.swift
//  MusicNotifier
//
//  AsyncImage refetches every time the host view re-instantiates (tab switch,
//  list re-render) and decodes lazily on first draw — which causes a frame of
//  grey-disc flash on every scroll. This wrapper:
//
//  • Checks the in-memory cache synchronously in `init`, so cached images
//    render in the very first frame with zero placeholder flash.
//  • Decodes downloaded data off the main thread via
//    `UIImage.preparingForDisplay()`, so the first paint is also flash-free
//    on a cache miss (no main-thread decode hitch).
//  • Routes downloads through `URLSession.shared` which uses `URLCache.shared`
//    for disk caching — so a cold launch picks up artwork instantly from disk
//    instead of refetching.
//  • Exposes `CachedAsyncImage.prefetch(urls:)` so screens can warm the cache
//    for off-screen artwork before the user gets there.
//

import SwiftUI
import UIKit

final class ImageCache {
    static let shared = ImageCache()

    private let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        // Cost-based eviction (bytes of decoded RGBA) is much safer than a
        // raw `countLimit`: an @3x cover at 600×600 is ~1.4 MB, and 800 of
        // those would push 1 GB on devices like the iPhone 11 — the OS
        // would terminate us under memory pressure long before. Cap at
        // ~100 MB of decoded artwork.
        cache.totalCostLimit = 100 * 1024 * 1024
        return cache
    }()

    func image(for url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }
    func store(_ image: UIImage, for url: URL) {
        // Approximate decoded byte cost: width × height × 4 bytes (RGBA).
        let scale = image.scale
        let pixelWidth = image.size.width * scale
        let pixelHeight = image.size.height * scale
        let cost = Int(pixelWidth * pixelHeight * 4)
        cache.setObject(image, forKey: url as NSURL, cost: max(cost, 1))
    }
}

// NB: a 256 MB on-disk URLCache is installed in `MusicNotifierApp.init()` so
// cold launches paint cached covers from disk instead of re-downloading.

/// Tracks in-flight downloads so concurrent prefetches/views for the same URL
/// don't trigger duplicate network calls. The first caller fetches; everyone
/// else awaits the same task.
private actor ImageLoader {
    static let shared = ImageLoader()

    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    func load(_ url: URL) async -> UIImage? {
        if let cached = ImageCache.shared.image(for: url) { return cached }
        if let existing = inFlight[url] { return await existing.value }

        let task = Task<UIImage?, Never> {
            do {
                let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
                let (data, _) = try await URLSession.shared.data(for: request)
                guard let raw = UIImage(data: data) else { return nil }
                // preparingForDisplay decodes and rasterizes off the main thread.
                // Without this the first draw triggers a main-thread decode which
                // is the classic SwiftUI scroll hitch.
                let decoded = raw.preparingForDisplay() ?? raw
                ImageCache.shared.store(decoded, for: url)
                return decoded
            } catch {
                return nil
            }
        }
        inFlight[url] = task
        let result = await task.value
        inFlight[url] = nil
        return result
    }
}

struct CachedAsyncImage<Placeholder: View>: View {
    let url: URL?
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var loaded: UIImage?

    init(url: URL?, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.placeholder = placeholder
        // Synchronous cache check so the first frame already shows the cached
        // image — no placeholder flash on re-render.
        if let url, let cached = ImageCache.shared.image(for: url) {
            _loaded = State(initialValue: cached)
        } else {
            _loaded = State(initialValue: nil)
        }
    }

    var body: some View {
        Group {
            if let loaded {
                Image(uiImage: loaded)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else { loaded = nil; return }
            // If the cache was populated between init and task firing
            // (e.g. by a prefetch), pick it up without going through the loader.
            if let cached = ImageCache.shared.image(for: url) {
                if loaded !== cached { loaded = cached }
                return
            }
            let image = await ImageLoader.shared.load(url)
            if !Task.isCancelled, let image { loaded = image }
        }
    }

}

/// Non-generic namespace for the prefetch API — generic static methods on
/// `CachedAsyncImage<Placeholder>` can't infer `Placeholder` at the call site.
enum ImagePrefetcher {
    /// Fire-and-forget cache warmer. Safe to call with any number of URLs —
    /// already-cached and in-flight URLs are no-ops.
    static func prefetch(_ urls: [URL?]) {
        let unique = Array(Set(urls.compactMap { $0 })).filter {
            ImageCache.shared.image(for: $0) == nil
        }
        guard !unique.isEmpty else { return }
        Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                for url in unique {
                    group.addTask { _ = await ImageLoader.shared.load(url) }
                }
            }
        }
    }
}
