//
//  AvatarImageCache.swift
//  Hackysack
//

import CryptoKit
import UIKit

/// Memory and disk cache for avatar images, keyed only by URL.
///
/// That is safe because avatar URLs are immutable: the server gives every
/// upload a fresh `avatars/<userId>/<uuid>.jpg` key, so the bytes at a URL
/// never change and a new avatar always arrives with a new URL. A cached image
/// is therefore never revalidated — it is downloaded once per URL, ever.
final class AvatarImageCache {
    static let shared = AvatarImageCache()

    private let memoryCache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 200
        return cache
    }()

    /// Loads already underway, so the same user appearing in several rows at
    /// once shares one download rather than starting one per row.
    private var inFlightLoads: [URL: Task<UIImage, Error>] = [:]

    /// Synchronous, so AvatarView can draw a cached image on its first frame
    /// instead of flashing the loading placeholder.
    func cachedImage(for url: URL) -> UIImage? {
        memoryCache.object(forKey: url as NSURL)
    }

    func image(for url: URL) async throws -> UIImage {
        if let cached = cachedImage(for: url) {
            return cached
        }
        if let existingLoad = inFlightLoads[url] {
            return try await existingLoad.value
        }

        // Unstructured, so it doesn't inherit the caller's cancellation: an
        // avatar that scrolls off screen mid-download still finishes and lands
        // in both caches, ready for the next time that row appears. It inherits
        // the main actor, so its body (and the defer) can't run until this
        // function suspends below — after the task is stored in inFlightLoads.
        let load = Task {
            defer { inFlightLoads[url] = nil }
            let image = try await AvatarImageLoader.loadImage(from: url)
            memoryCache.setObject(image, forKey: url as NSURL)
            return image
        }
        inFlightLoads[url] = load
        return try await load.value
    }
}

/// The off-main-actor half of the cache: file I/O, networking and decoding.
private nonisolated enum AvatarImageLoader {
    /// Caches rather than Application Support, so iOS can purge it under
    /// storage pressure and it stays out of backups — everything in it can be
    /// downloaded again.
    private static let directory = URL.cachesDirectory.appending(path: "Avatars", directoryHint: .isDirectory)

    @concurrent
    static func loadImage(from url: URL) async throws -> UIImage {
        let fileURL = fileURL(for: url)

        if let data = try? Data(contentsOf: fileURL), let image = await decode(data) {
            return image
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard let image = await decode(data) else {
            throw URLError(.cannotDecodeContentData)
        }

        // A failed write only costs a re-download next launch, so it is not
        // worth failing a load that already has its image.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)

        return image
    }

    /// Hashed so the filename is fixed-length and free of URL punctuation.
    private static func fileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let fileName = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(fileName).jpg", directoryHint: .notDirectory)
    }

    /// Decodes up front so the first draw on the main thread doesn't have to.
    private static func decode(_ data: Data) async -> UIImage? {
        await UIImage(data: data)?.byPreparingForDisplay()
    }
}
