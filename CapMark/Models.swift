import Foundation
import CoreGraphics
import AppKit

protocol UnderlyingErrorProviding {
    var underlyingError: Error { get }
}

enum ErrorPresentation {
    static let diskSpaceGuidance =
        "ディスクの空き容量を増やすため不要な履歴を削除するか、設定で保存先を変更してください。"

    static func message(for error: Error) -> String {
        let description = error.localizedDescription
        guard isOutOfDiskSpace(error) else { return description }
        return "\(description)\n\(diskSpaceGuidance)"
    }

    static func isUserCancellation(_ error: Error) -> Bool {
        contains(error) { candidate, cocoa in
            candidate is CancellationError
                || (cocoa.domain == NSCocoaErrorDomain
                    && CocoaError.Code(rawValue: cocoa.code) == .userCancelled)
                || (cocoa.domain == NSPOSIXErrorDomain
                    && POSIXError.Code(rawValue: Int32(cocoa.code)) == .ECANCELED)
        }
    }

    static func isOutOfDiskSpace(_ error: Error) -> Bool {
        contains(error) { _, cocoa in
            (cocoa.domain == NSCocoaErrorDomain
                && CocoaError.Code(rawValue: cocoa.code) == .fileWriteOutOfSpace)
                || (cocoa.domain == NSPOSIXErrorDomain
                    && POSIXError.Code(rawValue: Int32(cocoa.code)) == .ENOSPC)
        }
    }

    private static func contains(
        _ error: Error,
        matching predicate: (Error, NSError) -> Bool
    ) -> Bool {
        var current: Error? = error
        var depth = 0
        while let candidate = current, depth < 12 {
            let cocoa = candidate as NSError
            if predicate(candidate, cocoa) { return true }
            if let wrapped = candidate as? UnderlyingErrorProviding {
                current = wrapped.underlyingError
            } else {
                current = cocoa.userInfo[NSUnderlyingErrorKey] as? Error
            }
            depth += 1
        }
        return false
    }
}

enum MenuBarMode: String, Codable, CaseIterable, Identifiable {
    case always = "常に表示"
    case duringProcessing = "撮影・処理中のみ"
    case whenHistoryExists = "履歴ありの場合のみ"
    case never = "常に非表示"
    var id: Self { self }
}

enum DockMode: String, Codable, CaseIterable, Identifiable {
    case never = "常に非表示"
    case whileWindowOpen = "ウィンドウ表示中のみ"
    case always = "常に表示"
    var id: Self { self }
}

enum StartupScreen: String, Codable, CaseIterable, Identifiable {
    case none = "何も開かない"
    case history = "履歴"
    case settings = "設定"
    var id: Self { self }
}

enum ShelfPosition: String, Codable, CaseIterable, Identifiable {
    case bottomRight = "右下"
    case bottomLeft = "左下"
    case topRight = "右上"
    case topLeft = "左上"
    var id: Self { self }
}

enum ShelfThumbnailSize: String, Codable, CaseIterable, Identifiable {
    case small = "小"
    case medium = "中"
    case large = "大"
    var id: Self { self }
    var width: CGFloat {
        switch self { case .small: 80; case .medium: 108; case .large: 148 }
    }
    var height: CGFloat { width * 0.76 }
}

enum ShelfAnimation: String, Codable, CaseIterable, Identifiable {
    case none = "なし"
    case fade = "フェード"
    case slide = "スライド"
    var id: Self { self }
}

enum DragImageFormat: String, Codable, CaseIterable, Identifiable {
    case png = "PNG"
    case jpeg = "JPEG"
    var id: Self { self }
    var fileExtension: String { self == .png ? "png" : "jpg" }
}

enum EditorInitialZoom: String, Codable, CaseIterable, Identifiable {
    case fit = "ウィンドウに合わせる"
    case actualSize = "100%"
    case fiftyPercent = "50%"
    case twoHundredPercent = "200%"
    var id: Self { self }
    var scale: CGFloat? {
        switch self {
        case .fit: nil
        case .actualSize: 1
        case .fiftyPercent: 0.5
        case .twoHundredPercent: 2
        }
    }
}

enum PostCaptureAction: String, Codable, CaseIterable, Identifiable {
    case shelfOnly = "Shelfのみ"
    case autoCopy = "自動コピー"
    case openAnnotation = "注釈を開く"
    case saveDialog = "保存ダイアログ"
    case autoSave = "自動保存"
    case copyThenAnnotate = "コピーして注釈"
    case annotateThenCopy = "注釈してコピー"
    var id: Self { self }
}

enum SaveDestination: String, Codable, CaseIterable, Identifiable {
    case desktop = "Desktop"
    case downloads = "Downloads"
    case pictures = "Pictures"
    case custom = "任意フォルダ"
    var id: Self { self }
    var searchDirectory: FileManager.SearchPathDirectory {
        switch self {
        case .desktop: .desktopDirectory
        case .downloads: .downloadsDirectory
        case .pictures: .picturesDirectory
        case .custom: .documentDirectory
        }
    }
}

enum ExportFormat: String, Codable, CaseIterable, Identifiable {
    case png = "PNG"
    case jpeg = "JPEG"
    var id: Self { self }
    var fileExtension: String { self == .png ? "png" : "jpg" }
}

enum FileCollisionPolicy: String, Codable, CaseIterable, Identifiable {
    case addCounter = "連番を追加"
    case confirmOverwrite = "上書き確認"
    case alwaysOverwrite = "常に上書き"
    case cancel = "保存を中止"
    var id: Self { self }
}

enum RetentionPeriod: Int, Codable, CaseIterable, Identifiable {
    case unlimited = 0
    case oneDay = 1
    case sevenDays = 7
    case thirtyDays = 30
    case ninetyDays = 90
    var id: Self { self }
    var title: String { self == .unlimited ? "制限なし" : "\(rawValue)日" }
}

enum AnnotationCompletionAction: String, Codable, CaseIterable, Identifiable {
    case none = "何もしない"
    case copy = "コピー"
    case save = "保存"
    var id: Self { self }
}

struct ShortcutConfiguration: Codable, Equatable {
    var keyCode: UInt32 = 19 // 2
    var command = true
    var shift = true
    var option = false
    var control = false
    var enabled = true
    var isConfigured = true

    var display: String {
        guard isConfigured else { return "未設定" }
        return "\(control ? "⌃" : "")\(option ? "⌥" : "")\(shift ? "⇧" : "")\(command ? "⌘" : "")\(Self.keyName(keyCode))"
    }

    private enum CodingKeys: String, CodingKey {
        case keyCode, command, shift, option, control, enabled, isConfigured
    }

    init(
        keyCode: UInt32 = 19, command: Bool = true, shift: Bool = true,
        option: Bool = false, control: Bool = false,
        enabled: Bool = true, isConfigured: Bool = true
    ) {
        self.keyCode = keyCode
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
        self.enabled = enabled
        self.isConfigured = isConfigured
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try values.decodeIfPresent(UInt32.self, forKey: .keyCode) ?? 19
        command = try values.decodeIfPresent(Bool.self, forKey: .command) ?? true
        shift = try values.decodeIfPresent(Bool.self, forKey: .shift) ?? true
        option = try values.decodeIfPresent(Bool.self, forKey: .option) ?? false
        control = try values.decodeIfPresent(Bool.self, forKey: .control) ?? false
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        isConfigured = try values.decodeIfPresent(Bool.self, forKey: .isConfigured) ?? true
    }

    static func keyName(_ code: UInt32) -> String {
        let names: [UInt32: String] = [
            0:"A", 1:"S", 2:"D", 3:"F", 4:"H", 5:"G", 6:"Z", 7:"X", 8:"C", 9:"V",
            11:"B", 12:"Q", 13:"W", 14:"E", 15:"R", 16:"Y", 17:"T",
            18:"1", 19:"2", 20:"3", 21:"4", 22:"6", 23:"5", 24:"=", 25:"9", 26:"7",
            27:"-", 28:"8", 29:"0", 30:"]", 31:"O", 32:"U", 33:"[", 34:"I", 35:"P",
            37:"L", 38:"J", 40:"K", 41:";", 42:"\\", 43:",", 44:"/", 45:"N", 46:"M",
            47:".", 50:"`", 36:"↩", 49:"Space", 51:"⌫", 53:"Esc",
            123:"←", 124:"→", 125:"↓", 126:"↑"
        ]
        return names[code] ?? "Key \(code)"
    }
}

struct AppSettings: Codable, Equatable, Sendable {
    var shortcut = ShortcutConfiguration()
    var menuBarMode = MenuBarMode.always
    var dockMode = DockMode.never
    var startupScreen = StartupScreen.none
    var shelfPosition = ShelfPosition.bottomRight
    var shelfEnabled = true
    var shelfThumbnailSize = ShelfThumbnailSize.medium
    var shelfAnimation = ShelfAnimation.fade
    var dragImageFormat = DragImageFormat.png
    var shelfDuration = 0.0
    var shelfLimit = 1
    var historyLimit = 20
    var historyEnabled = true
    var keepOriginalImages = true
    var cacheAnnotatedImages = true
    var deleteHistoryOnExit = false
    var pinnedItemsOutsideLimit = true
    var includeCursor = false
    var selectionDelay = 0.0
    var overlayDimness = 0.55
    var selectionBorderWidth = 2.0
    var postCaptureAction = PostCaptureAction.shelfOnly
    var retentionPeriod = RetentionPeriod.unlimited
    var exportFormat = ExportFormat.png
    var jpegQuality = 0.9
    var filenameTemplate = "CapMark-{date}-{time}-{width}x{height}"
    var saveDestination = SaveDestination.desktop
    var customSaveFolderBookmark: Data?
    var customSaveFolderName: String?
    var fileCollisionPolicy = FileCollisionPolicy.addCounter
    var preserveExportMetadata = false
    var pauseShelfTimerOnHover = true
    var soundEnabled = false
    var notificationsEnabled = false
    var defaultAnnotationTool = AnnotationTool.arrow
    var defaultAnnotationColor = RGBAColor.red
    var defaultAnnotationLineWidth = 6.0
    var defaultMarkerOpacity = 0.4
    var defaultFontName = "Helvetica"
    var defaultFontSize = 28.0
    var defaultTextAlignment = AnnotationTextAlignment.left
    var annotationCompletionAction = AnnotationCompletionAction.none
    var editorInitialZoom = EditorInitialZoom.fit
    var hasCompletedSetup = false

    private enum CodingKeys: String, CodingKey {
        case shortcut, menuBarMode, dockMode, shelfPosition, shelfDuration, shelfLimit
        case startupScreen
        case shelfEnabled, shelfThumbnailSize, shelfAnimation, dragImageFormat
        case historyLimit, includeCursor, postCaptureAction, retentionPeriod
        case historyEnabled, keepOriginalImages, cacheAnnotatedImages
        case deleteHistoryOnExit, pinnedItemsOutsideLimit
        case selectionDelay, overlayDimness, selectionBorderWidth
        case exportFormat, jpegQuality, filenameTemplate, saveDestination
        case customSaveFolderBookmark, customSaveFolderName
        case fileCollisionPolicy, preserveExportMetadata
        case pauseShelfTimerOnHover, soundEnabled, notificationsEnabled, hasCompletedSetup
        case defaultAnnotationTool, defaultAnnotationColor, defaultAnnotationLineWidth
        case defaultMarkerOpacity, defaultFontName, defaultFontSize, annotationCompletionAction
        case defaultTextAlignment, editorInitialZoom
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        shortcut = try values.decodeIfPresent(ShortcutConfiguration.self, forKey: .shortcut) ?? ShortcutConfiguration()
        menuBarMode = try values.decodeIfPresent(MenuBarMode.self, forKey: .menuBarMode) ?? .always
        dockMode = try values.decodeIfPresent(DockMode.self, forKey: .dockMode) ?? .never
        startupScreen = try values.decodeIfPresent(StartupScreen.self, forKey: .startupScreen) ?? .none
        shelfPosition = try values.decodeIfPresent(ShelfPosition.self, forKey: .shelfPosition) ?? .bottomRight
        shelfEnabled = try values.decodeIfPresent(Bool.self, forKey: .shelfEnabled) ?? true
        shelfThumbnailSize = try values.decodeIfPresent(ShelfThumbnailSize.self, forKey: .shelfThumbnailSize) ?? .medium
        shelfAnimation = try values.decodeIfPresent(ShelfAnimation.self, forKey: .shelfAnimation) ?? .fade
        dragImageFormat = try values.decodeIfPresent(DragImageFormat.self, forKey: .dragImageFormat) ?? .png
        shelfDuration = try values.decodeIfPresent(Double.self, forKey: .shelfDuration) ?? 10
        shelfLimit = try values.decodeIfPresent(Int.self, forKey: .shelfLimit) ?? 3
        historyLimit = try values.decodeIfPresent(Int.self, forKey: .historyLimit) ?? 20
        historyEnabled = try values.decodeIfPresent(Bool.self, forKey: .historyEnabled) ?? true
        keepOriginalImages = try values.decodeIfPresent(Bool.self, forKey: .keepOriginalImages) ?? true
        cacheAnnotatedImages = try values.decodeIfPresent(Bool.self, forKey: .cacheAnnotatedImages) ?? true
        deleteHistoryOnExit = try values.decodeIfPresent(Bool.self, forKey: .deleteHistoryOnExit) ?? false
        pinnedItemsOutsideLimit = try values.decodeIfPresent(Bool.self, forKey: .pinnedItemsOutsideLimit) ?? true
        includeCursor = try values.decodeIfPresent(Bool.self, forKey: .includeCursor) ?? false
        selectionDelay = try values.decodeIfPresent(Double.self, forKey: .selectionDelay) ?? 0
        overlayDimness = try values.decodeIfPresent(Double.self, forKey: .overlayDimness) ?? 0.55
        selectionBorderWidth = try values.decodeIfPresent(Double.self, forKey: .selectionBorderWidth) ?? 2
        postCaptureAction = try values.decodeIfPresent(PostCaptureAction.self, forKey: .postCaptureAction) ?? .shelfOnly
        retentionPeriod = try values.decodeIfPresent(RetentionPeriod.self, forKey: .retentionPeriod) ?? .unlimited
        exportFormat = try values.decodeIfPresent(ExportFormat.self, forKey: .exportFormat) ?? .png
        jpegQuality = try values.decodeIfPresent(Double.self, forKey: .jpegQuality) ?? 0.9
        filenameTemplate = try values.decodeIfPresent(String.self, forKey: .filenameTemplate)
            ?? "CapMark-{date}-{time}-{width}x{height}"
        saveDestination = try values.decodeIfPresent(SaveDestination.self, forKey: .saveDestination) ?? .desktop
        customSaveFolderBookmark = try values.decodeIfPresent(Data.self, forKey: .customSaveFolderBookmark)
        customSaveFolderName = try values.decodeIfPresent(String.self, forKey: .customSaveFolderName)
        fileCollisionPolicy = try values.decodeIfPresent(
            FileCollisionPolicy.self, forKey: .fileCollisionPolicy
        ) ?? .addCounter
        preserveExportMetadata = try values.decodeIfPresent(Bool.self, forKey: .preserveExportMetadata) ?? false
        pauseShelfTimerOnHover = try values.decodeIfPresent(Bool.self, forKey: .pauseShelfTimerOnHover) ?? true
        soundEnabled = try values.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? false
        notificationsEnabled = try values.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? false
        defaultAnnotationTool = try values.decodeIfPresent(AnnotationTool.self, forKey: .defaultAnnotationTool) ?? .arrow
        defaultAnnotationColor = try values.decodeIfPresent(RGBAColor.self, forKey: .defaultAnnotationColor) ?? .red
        defaultAnnotationLineWidth = try values.decodeIfPresent(Double.self, forKey: .defaultAnnotationLineWidth) ?? 6
        defaultMarkerOpacity = try values.decodeIfPresent(Double.self, forKey: .defaultMarkerOpacity) ?? 0.4
        defaultFontName = try values.decodeIfPresent(String.self, forKey: .defaultFontName) ?? "Helvetica"
        defaultFontSize = try values.decodeIfPresent(Double.self, forKey: .defaultFontSize) ?? 28
        defaultTextAlignment = try values.decodeIfPresent(
            AnnotationTextAlignment.self, forKey: .defaultTextAlignment
        ) ?? .left
        annotationCompletionAction = try values.decodeIfPresent(
            AnnotationCompletionAction.self, forKey: .annotationCompletionAction
        ) ?? .none
        editorInitialZoom = try values.decodeIfPresent(
            EditorInitialZoom.self, forKey: .editorInitialZoom
        ) ?? .fit
        hasCompletedSetup = try values.decodeIfPresent(Bool.self, forKey: .hasCompletedSetup) ?? false
    }
}

struct CaptureItem: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let createdAt: Date
    var updatedAt: Date
    let originalFilename: String
    var renderedFilename: String?
    var documentFilename: String?
    var thumbnailFilename: String?
    var pixelWidth: Int
    var pixelHeight: Int
    let displayID: UInt32
    let displayName: String
    let scale: CGFloat
    let selectionRect: CGRect
    var displayLocalRect: CGRect?
    var isPinned: Bool
    var annotationCount: Int
    var lastCopiedAt: Date? = nil
    var lastSavedAt: Date? = nil

    var originalURL: URL { StoragePaths.originals.appendingPathComponent(originalFilename) }
    var bestURL: URL {
        renderedFilename.map { StoragePaths.rendered.appendingPathComponent($0) } ?? originalURL
    }
    var documentURL: URL? {
        documentFilename.map { StoragePaths.documents.appendingPathComponent($0) }
    }
    var thumbnailURL: URL {
        guard let thumbnailFilename else { return bestURL }
        let candidate = StoragePaths.thumbnails.appendingPathComponent(thumbnailFilename)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : bestURL
    }
}

enum StoragePaths {
    static let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CapMark", isDirectory: true)
    static let originals = root.appendingPathComponent("Captures/originals", isDirectory: true)
    static let rendered = root.appendingPathComponent("Captures/rendered", isDirectory: true)
    static let documents = root.appendingPathComponent("Captures/documents", isDirectory: true)
    static let thumbnails = root.appendingPathComponent("Cache/thumbnails", isDirectory: true)
    static let drag = root.appendingPathComponent("Cache/drag", isDirectory: true)
    static let historyFile = root.appendingPathComponent("history.json")
    static let settingsFile = root.appendingPathComponent("settings.json")
}
