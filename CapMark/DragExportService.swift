import AppKit
import UniformTypeIdentifiers

/// Tracks temporary drag files that should be deleted if generation is abandoned
/// before the file is handed off (e.g. cancelled async work).
final class DragTemporaryFileLease: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: Set<URL> = []
    private var isFinished = false

    func register(_ url: URL) {
        let removesImmediately = lock.withLock {
            if isFinished { return true }
            urls.insert(url)
            return false
        }
        if removesImmediately {
            Self.remove([url])
        }
    }

    func finish() {
        let pending = lock.withLock {
            guard !isFinished else { return Set<URL>() }
            isFinished = true
            defer { urls.removeAll() }
            return urls
        }
        Self.remove(pending)
    }

    private static func remove(_ urls: Set<URL>) {
        guard !urls.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

enum DragExportService {
    /// Builds a drag item provider. Materializes the export file **before**
    /// returning so path-based drop targets (Terminal, path fields, …) see a
    /// real `public.file-url` at drag start. Finder / image apps still receive
    /// the image UTI. Generated files stay in `Cache/drag` for path validity
    /// after drop and are cleaned by the existing 24h / delete / exit policy.
    @MainActor
    static func itemProvider(for item: CaptureItem, model: AppModel) -> NSItemProvider {
        let format = model.settings.dragImageFormat
        let contentType = format == .png ? UTType.png : UTType.jpeg
        let stamp = ISO8601DateFormatter().string(from: item.createdAt)
            .replacingOccurrences(of: ":", with: "-")
        let suggestedName = "CapMark-\(stamp).\(format.fileExtension)"
        let settings = model.settings

        do {
            let url = try DispatchQueue.global(qos: .userInitiated).sync {
                try materialize(for: item, settings: settings)
            }
            return makeProvider(
                fileURL: url,
                suggestedName: suggestedName,
                contentType: contentType
            )
        } catch {
            Task {
                await LogService.shared.record(
                    .exportFailed,
                    code: .errorType(String(describing: type(of: error)))
                )
            }
            let provider = NSItemProvider()
            provider.suggestedName = suggestedName
            return provider
        }
    }

    /// Writes the drag export into `Cache/drag` and returns its URL.
    /// Safe to call off the main actor.
    nonisolated static func materialize(
        for item: CaptureItem,
        settings: AppSettings
    ) throws -> URL {
        let format = settings.dragImageFormat
        let destination = StoragePaths.drag.appendingPathComponent(
            "CapMark-\(item.id.uuidString).\(format.fileExtension)"
        )
        var exportSettings = settings
        exportSettings.exportFormat = format == .png ? .png : .jpeg
        try FileExportService.export(
            item, to: destination, settings: exportSettings
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: destination.path
        )
        return destination
    }

    nonisolated static func makeProvider(
        fileURL: URL,
        suggestedName: String,
        contentType: UTType
    ) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = suggestedName

        // Path-based drop targets (Terminal, path text fields, many tools).
        provider.registerObject(fileURL as NSURL, visibility: .all)

        // Explicit file-url representation for consumers that query this UTI.
        // openInPlace keeps the Cache/drag path stable for path insertion.
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.fileURL.identifier,
            fileOptions: [.openInPlace],
            visibility: .all
        ) { completion in
            completion(fileURL, false, nil)
            return nil
        }

        // Image/file drop targets (Finder, Slack, browsers, …).
        provider.registerFileRepresentation(
            forTypeIdentifier: contentType.identifier,
            fileOptions: [.openInPlace],
            visibility: .all
        ) { completion in
            completion(fileURL, false, nil)
            return nil
        }

        return provider
    }
}
