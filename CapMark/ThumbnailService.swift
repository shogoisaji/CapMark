import ImageIO
import UniformTypeIdentifiers

enum ThumbnailService {
    static func generate(sourceURL: URL, destinationURL: URL, maxPixelSize: Int = 480) throws {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try generate(source: source, destinationURL: destinationURL, maxPixelSize: maxPixelSize)
    }

    static func generate(data: Data, destinationURL: URL, maxPixelSize: Int = 480) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try generate(source: source, destinationURL: destinationURL, maxPixelSize: maxPixelSize)
    }

    private static func generate(
        source: CGImageSource, destinationURL: URL, maxPixelSize: Int
    ) throws {
        guard
              let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                    kCGImageSourceCreateThumbnailWithTransform: true
                ] as CFDictionary
              ) else { throw CocoaError(.fileReadCorruptFile) }
        try ImageFileService.writePNG(image, to: destinationURL)
    }
}
