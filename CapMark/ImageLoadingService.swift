import AppKit

enum ImageLoadingService {
    static func readData(from url: URL) async -> Data? {
        await Task.detached(priority: .utility) {
            try? Data(contentsOf: url, options: [.mappedIfSafe])
        }.value
    }
}

enum CacheCleanupService {
    static func clear(
        directories: [URL] = [StoragePaths.thumbnails, StoragePaths.drag]
    ) throws {
        for directory in directories {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            for url in try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            ) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }
}

@MainActor
final class ThumbnailImageCache {
    static let shared = ThumbnailImageCache()
    private let cache = NSCache<NSURL, NSImage>()

    private init() {
        cache.countLimit = 250
        cache.totalCostLimit = 96 * 1_024 * 1_024
    }

    func image(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    func insert(_ image: NSImage, for url: URL) {
        let cost = max(1, Int(image.size.width * image.size.height * 4))
        cache.setObject(image, forKey: url as NSURL, cost: cost)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}
