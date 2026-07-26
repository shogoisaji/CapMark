import AppKit

enum ClipboardService {
    @MainActor
    static func copy(_ item: CaptureItem) async throws -> Bool {
        let prepared = try await Task.detached(priority: .userInitiated) {
            let data = try ImageRenderer.latestPNG(for: item)
            let fileURL = try ImageMaterializationService.materializeLatestPNG(
                for: item, suffix: "clipboard", data: data
            )
            return (data, fileURL)
        }.value
        let (data, fileURL) = prepared
        return writeImageData(data, fileURL: fileURL)
    }

    @MainActor
    static func copyOriginal(_ item: CaptureItem) async throws -> Bool {
        let data = try await Task.detached(priority: .userInitiated) {
            try Data(contentsOf: item.originalURL, options: [.mappedIfSafe])
        }.value
        return writeImageData(data, fileURL: item.originalURL)
    }

    @MainActor
    static func copyImageData(_ item: CaptureItem) async throws -> Bool {
        let data = try await Task.detached(priority: .userInitiated) {
            try ImageRenderer.latestPNG(for: item)
        }.value
        return writeImageData(data, fileURL: nil)
    }

    @MainActor
    static func copyFile(_ item: CaptureItem) async throws -> Bool {
        let fileURL = try await Task.detached(priority: .userInitiated) {
            try ImageMaterializationService.materializeLatestPNG(
                for: item, suffix: "clipboard-file"
            )
        }.value
        let board = NSPasteboard.general
        board.clearContents()
        return board.writeObjects([fileURL as NSURL])
    }

    @MainActor
    private static func writeImageData(_ data: Data, fileURL: URL?) -> Bool {
        guard let image = NSImage(data: data) else { return false }
        let board = NSPasteboard.general
        board.clearContents()
        var objects: [NSPasteboardWriting] = [image]
        if let fileURL { objects.append(fileURL as NSURL) }
        let wroteObjects = board.writeObjects(objects)
        board.setData(data, forType: .png)
        if let tiff = image.tiffRepresentation {
            board.setData(tiff, forType: .tiff)
        }
        return wroteObjects && board.data(forType: .png) != nil
    }

}
