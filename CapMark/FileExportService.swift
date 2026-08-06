import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@MainActor
private final class ExportOptions: ObservableObject {
    @Published var format: ExportFormat
    @Published var jpegQuality: Double
    @Published var exportsOriginal = false
    @Published var preservesMetadata: Bool

    init(settings: AppSettings) {
        format = settings.exportFormat
        jpegQuality = settings.jpegQuality
        preservesMetadata = settings.preserveExportMetadata
    }
}

private struct ExportAccessoryView: View {
    @ObservedObject var options: ExportOptions

    var body: some View {
        Form {
            Picker(L10n.t("Format", "形式"), selection: $options.format) {
                ForEach(ExportFormat.allCases) { Text($0.rawValue).tag($0) }
            }
            if options.format == .jpeg {
                HStack {
                    Slider(value: $options.jpegQuality, in: 0.1...1)
                        .accessibilityLabel(L10n.t("JPEG quality", "JPEG品質"))
                        .accessibilityValue(L10n.tf("%d percent", "%dパーセント", Int(options.jpegQuality * 100)))
                    Text("\(Int(options.jpegQuality * 100))%")
                        .monospacedDigit().frame(width: 45)
                }
            }
            Picker(L10n.t("Image", "画像"), selection: $options.exportsOriginal) {
                Text(L10n.t("Annotated image", "注釈済み画像")).tag(false)
                Text(L10n.t("Original image", "元画像")).tag(true)
            }
            Toggle(L10n.t("Preserve metadata", "メタデータを保持"), isOn: $options.preservesMetadata)
        }
        .padding(12)
        .frame(width: 330)
        .observesLanguage()
    }
}

private struct ExportRequest: Sendable {
    let item: CaptureItem
    let destination: URL
}

enum FileCollisionResolution: Equatable {
    case use(URL)
    case confirm(URL)
    case cancel
}

enum FileCollisionResolver {
    static func resolve(
        _ proposed: URL,
        policy: FileCollisionPolicy,
        occupied: Set<URL> = [],
        fileExists: (URL) -> Bool = {
            FileManager.default.fileExists(atPath: $0.path)
        }
    ) -> FileCollisionResolution {
        let collides = occupied.contains(proposed) || fileExists(proposed)
        guard collides else { return .use(proposed) }
        switch policy {
        case .addCounter:
            let directory = proposed.deletingLastPathComponent()
            let stem = proposed.deletingPathExtension().lastPathComponent
            let ext = proposed.pathExtension
            var counter = 2
            while true {
                let name = ext.isEmpty
                    ? "\(stem)-\(counter)"
                    : "\(stem)-\(counter).\(ext)"
                let candidate = directory.appendingPathComponent(name)
                if !occupied.contains(candidate), !fileExists(candidate) {
                    return .use(candidate)
                }
                counter += 1
            }
        case .confirmOverwrite:
            return .confirm(proposed)
        case .alwaysOverwrite:
            return .use(proposed)
        case .cancel:
            return .cancel
        }
    }
}

enum FilenameSanitizer {
    static func base(
        _ value: String,
        maximumUTF8Bytes: Int = 200
    ) -> String {
        let forbidden = CharacterSet(
            charactersIn: "/\\:"
        ).union(.controlCharacters)
        let replaced = String(value.map { character in
            character.unicodeScalars.contains(where: forbidden.contains)
                ? Character("-") : character
        })
        let edgeCharacters = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "."))
        let trimmed = replaced.trimmingCharacters(in: edgeCharacters)
        let source = trimmed.isEmpty ? "CapMark" : trimmed
        var result = ""
        for character in source {
            let candidate = result + String(character)
            if candidate.utf8.count > maximumUTF8Bytes { break }
            result = candidate
        }
        return result.isEmpty ? "CapMark" : result
    }
}

enum FileExportService {
    @MainActor
    static func save(
        _ item: CaptureItem, settings: AppSettings,
        onFinished: @escaping (Set<UUID>) -> Void = { _ in }
    ) {
        let options = ExportOptions(settings: settings)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = filename(for: item, settings: settings)
        panel.accessoryView = NSHostingView(rootView: ExportAccessoryView(options: options))
        guard panel.runModal() == .OK, let destination = panel.url else {
            onFinished([])
            return
        }
        var effectiveSettings = settings
        effectiveSettings.exportFormat = options.format
        effectiveSettings.jpegQuality = options.jpegQuality
        effectiveSettings.preserveExportMetadata = options.preservesMetadata
        let resolvedDestination = destination
            .deletingPathExtension()
            .appendingPathExtension(options.format.fileExtension)
        let exportsOriginal = options.exportsOriginal
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    [item, resolvedDestination, effectiveSettings, exportsOriginal] in
                    try export(
                        item, to: resolvedDestination,
                        settings: effectiveSettings,
                        useOriginal: exportsOriginal
                    )
                }.value
                onFinished([item.id])
                await LogService.shared.record(.exportSucceeded)
            } catch {
                onFinished([])
                guard !ErrorPresentation.isUserCancellation(error) else {
                    return
                }
                await LogService.shared.record(
                    .exportFailed,
                    code: .errorType(String(describing: type(of: error)))
                )
                let alert = NSAlert()
                alert.messageText = L10n.t("Could not save the image", "画像を保存できませんでした")
                alert.informativeText = ErrorPresentation.message(for: error)
                alert.runModal()
            }
        }
    }

    @MainActor
    static func save(
        _ items: [CaptureItem], settings: AppSettings,
        onFinished: @escaping (Set<UUID>) -> Void = { _ in }
    ) {
        guard !items.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L10n.t("Save Here", "ここに保存")
        guard panel.runModal() == .OK, let directory = panel.url else {
            onFinished([])
            return
        }
        var occupied: Set<URL> = []
        var requests: [ExportRequest] = []
        for item in items {
            let proposed = directory.appendingPathComponent(
                filename(for: item, settings: settings)
            )
            let resolution = FileCollisionResolver.resolve(
                proposed,
                policy: settings.fileCollisionPolicy,
                occupied: occupied
            )
            let destination: URL
            switch resolution {
            case let .use(url):
                destination = url
            case let .confirm(url):
                let alert = NSAlert()
                alert.messageText = L10n.t("A file with the same name exists", "同名のファイルがあります")
                alert.informativeText =
                    L10n.tf("Overwrite %@?", "%@を上書きしますか？", url.lastPathComponent)
                alert.addButton(withTitle: L10n.t("Overwrite", "上書き"))
                alert.addButton(withTitle: L10n.t("Skip This Item", "この項目を保存しない"))
                guard alert.runModal() == .alertFirstButtonReturn else {
                    continue
                }
                destination = url
            case .cancel:
                continue
            }
            occupied.insert(destination)
            requests.append(ExportRequest(item: item, destination: destination))
        }
        guard !requests.isEmpty else {
            onFinished([])
            return
        }
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                [requests, settings] in
                var savedIDs: Set<UUID> = []
                var failureCodes: [String] = []
                var encounteredOutOfDiskSpace = false
                for request in requests {
                    do {
                        try export(
                            request.item,
                            to: request.destination,
                            settings: settings
                        )
                        savedIDs.insert(request.item.id)
                    } catch {
                        failureCodes.append(
                            String(describing: type(of: error))
                        )
                        encounteredOutOfDiskSpace =
                            encounteredOutOfDiskSpace
                            || ErrorPresentation.isOutOfDiskSpace(error)
                    }
                }
                return (savedIDs, failureCodes, encounteredOutOfDiskSpace)
            }.value
            for _ in outcome.0 {
                await LogService.shared.record(.exportSucceeded)
            }
            for code in outcome.1 {
                await LogService.shared.record(
                    .exportFailed, code: .errorType(code)
                )
            }
            onFinished(outcome.0)
            if !outcome.1.isEmpty {
                let alert = NSAlert()
                alert.messageText = L10n.t("Some images could not be saved", "一部の画像を保存できませんでした")
                alert.informativeText = L10n.tf("%d items failed to save.", "%d件の保存に失敗しました。", outcome.1.count)
                    + (outcome.2 ? "\n\(ErrorPresentation.diskSpaceGuidance)" : "")
                alert.runModal()
            }
        }
    }

    @MainActor
    static func autoSave(
        _ item: CaptureItem, settings: AppSettings
    ) async throws -> URL {
        let directory: URL
        var scoped = false
        if settings.saveDestination == .custom {
            guard let bookmark = settings.customSaveFolderBookmark else {
                throw CocoaError(.fileNoSuchFile)
            }
            directory = try SecurityScopedBookmarkService.resolve(bookmark)
            scoped = directory.startAccessingSecurityScopedResource()
        } else {
            guard let resolved = FileManager.default.urls(
                for: settings.saveDestination.searchDirectory, in: .userDomainMask
            ).first else { throw CocoaError(.fileNoSuchFile) }
            directory = resolved
        }
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        let proposed = directory.appendingPathComponent(filename(for: item, settings: settings))
        let destination: URL
        if FileManager.default.fileExists(atPath: proposed.path) {
            switch settings.fileCollisionPolicy {
            case .addCounter:
                if case let .use(url) = FileCollisionResolver.resolve(
                    proposed, policy: .addCounter
                ) {
                    destination = url
                } else {
                    destination = proposed
                }
            case .alwaysOverwrite:
                destination = proposed
            case .cancel:
                throw CocoaError(.userCancelled)
            case .confirmOverwrite:
                let alert = NSAlert()
                alert.messageText = L10n.t("A file with the same name exists", "同名のファイルがあります")
                alert.informativeText = L10n.t("Overwrite the existing file?", "既存のファイルを上書きしますか？")
                alert.addButton(withTitle: L10n.t("Overwrite", "上書き"))
                alert.addButton(withTitle: L10n.t("Cancel", "キャンセル"))
                guard alert.runModal() == .alertFirstButtonReturn else {
                    throw CocoaError(.userCancelled)
                }
                destination = proposed
            }
        } else {
            destination = proposed
        }
        try await Task.detached(priority: .userInitiated) {
            try export(item, to: destination, settings: settings)
        }.value
        await LogService.shared.record(.exportSucceeded)
        return destination
    }

    static func export(
        _ item: CaptureItem, to destination: URL, settings: AppSettings,
        useOriginal: Bool = false
    ) throws {
        let outputData: Data
        if useOriginal, settings.exportFormat == .png, settings.preserveExportMetadata {
            outputData = try Data(
                contentsOf: item.originalURL, options: [.mappedIfSafe]
            )
        } else if !useOriginal, settings.exportFormat == .png,
                  settings.preserveExportMetadata,
                  item.renderedFilename != nil || item.documentFilename == nil {
            outputData = try Data(
                contentsOf: item.bestURL, options: [.mappedIfSafe]
            )
        } else {
            let source: CGImageSource?
            if useOriginal {
                source = CGImageSourceCreateWithURL(
                    item.originalURL as CFURL, nil
                )
            } else if settings.preserveExportMetadata,
                      item.renderedFilename == nil,
                      item.documentFilename == nil {
                source = CGImageSourceCreateWithURL(
                    item.originalURL as CFURL, nil
                )
            } else {
                let latestData = try ImageRenderer.latestPNG(for: item)
                source = CGImageSourceCreateWithData(
                    latestData as CFData, nil
                )
            }
            guard let source,
                  let image = CGImageSourceCreateImageAtIndex(
                    source, 0, nil
                  ) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let type = settings.exportFormat == .png
                ? UTType.png.identifier : UTType.jpeg.identifier
            let output = CFDataCreateMutable(nil, 0)!
            guard let imageDestination = CGImageDestinationCreateWithData(
                output, type as CFString, 1, nil
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
            var properties: [CFString: Any] = [:]
            if settings.preserveExportMetadata,
               let sourceProperties = CGImageSourceCopyPropertiesAtIndex(
                source, 0, nil
               ) as? [CFString: Any] {
                properties = sourceProperties
            }
            if settings.exportFormat == .jpeg {
                properties[kCGImageDestinationLossyCompressionQuality] =
                    settings.jpegQuality
            }
            CGImageDestinationAddImage(
                imageDestination, image, properties as CFDictionary
            )
            guard CGImageDestinationFinalize(imageDestination) else {
                throw CocoaError(.fileWriteUnknown)
            }
            outputData = output as Data
        }

        try ImageFileService.writePrivate(outputData, to: destination)
    }

    static func filename(for item: CaptureItem, settings: AppSettings) -> String {
        let date = dateFormatter.string(from: item.createdAt)
        let time = timeFormatter.string(from: item.createdAt)
        let datetime = "\(date)-\(time)"
        let expanded = settings.filenameTemplate
            .replacingOccurrences(of: "{date}", with: date)
            .replacingOccurrences(of: "{time}", with: time)
            .replacingOccurrences(of: "{datetime}", with: datetime)
            .replacingOccurrences(of: "{width}", with: "\(item.pixelWidth)")
            .replacingOccurrences(of: "{height}", with: "\(item.pixelHeight)")
            .replacingOccurrences(of: "{display}", with: item.displayName)
            .replacingOccurrences(of: "{counter}", with: "1")
            .replacingOccurrences(of: "{uuid}", with: item.id.uuidString)
        let base = FilenameSanitizer.base(expanded)
        return "\(base).\(settings.exportFormat.fileExtension)"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HHmmss"
        return formatter
    }()
}
