import CoreGraphics
import Darwin
import ImageIO
import UniformTypeIdentifiers

struct PrivateFileSnapshot: Sendable {
    let url: URL
    let data: Data?
}

enum ImageFileService {
    static func writePNG(_ image: CGImage, to url: URL) throws {
        let output = CFDataCreateMutable(nil, 0)!
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        ) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try writePrivate(output as Data, to: url)
    }

    static func writePrivate(_ data: Data, to url: URL) throws {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let stagingURL = directory.appendingPathComponent(
            ".capmark-private-\(UUID().uuidString).tmp"
        )
        defer { try? fileManager.removeItem(at: stagingURL) }
        guard fileManager.createFile(
            atPath: stagingURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: stagingURL)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        let renameResult = stagingURL.path.withCString { sourcePath in
            url.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard renameResult == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: url.path]
            )
        }
    }

    static func snapshot(_ urls: [URL]) throws -> [PrivateFileSnapshot] {
        try urls.map { url in
            let data = FileManager.default.fileExists(atPath: url.path)
                ? try Data(contentsOf: url, options: [.mappedIfSafe])
                : nil
            return PrivateFileSnapshot(url: url, data: data)
        }
    }

    static func restore(_ snapshots: [PrivateFileSnapshot]) throws {
        var firstError: Error?
        for snapshot in snapshots {
            do {
                if let data = snapshot.data {
                    try writePrivate(data, to: snapshot.url)
                } else if FileManager.default.fileExists(
                    atPath: snapshot.url.path
                ) {
                    try FileManager.default.removeItem(at: snapshot.url)
                }
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }
}
