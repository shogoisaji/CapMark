import Foundation

enum ImageMaterializationService {
    static func materializeLatestPNG(
        for item: CaptureItem,
        in directory: URL = StoragePaths.drag,
        suffix: String,
        data suppliedData: Data? = nil
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let destination = directory.appendingPathComponent(
            "CapMark-\(item.id.uuidString)-\(suffix).png"
        )
        let data = try suppliedData ?? ImageRenderer.latestPNG(for: item)
        try ImageFileService.writePrivate(data, to: destination)
        return destination
    }
}
