import Foundation
import CoreGraphics
import AppKit

protocol UnderlyingErrorProviding {
    var underlyingError: Error { get }
}

enum ErrorPresentation {
    static var diskSpaceGuidance: String {
        L10n.t(
            "Free up disk space by deleting unused history items, or change the save destination in Settings.",
            "ディスクの空き容量を増やすため不要な履歴を削除するか、設定で保存先を変更してください。"
        )
    }

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
    case always
    case duringProcessing
    case whenHistoryExists
    case never
    var id: Self { self }
    var title: String {
        switch self {
        case .always: L10n.t("Always show", "常に表示")
        case .duringProcessing: L10n.t("Only while capturing or processing", "撮影・処理中のみ")
        case .whenHistoryExists: L10n.t("Only when history exists", "履歴ありの場合のみ")
        case .never: L10n.t("Always hide", "常に非表示")
        }
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        let legacy: [String: Self] = [
            "常に表示": .always,
            "撮影・処理中のみ": .duringProcessing,
            "履歴ありの場合のみ": .whenHistoryExists,
            "常に非表示": .never,
        ]
        if let value = Self(rawValue: raw) {
            self = value
        } else if let value = legacy[raw] {
            self = value
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown MenuBarMode: \(raw)"
            )
        }
    }
}

enum DockMode: String, Codable, CaseIterable, Identifiable {
    case never
    case whileWindowOpen
    case always
    var id: Self { self }
    var title: String {
        switch self {
        case .never: L10n.t("Always hide", "常に非表示")
        case .whileWindowOpen: L10n.t("Only while a window is open", "ウィンドウ表示中のみ")
        case .always: L10n.t("Always show", "常に表示")
        }
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        let legacy: [String: Self] = [
            "常に非表示": .never,
            "ウィンドウ表示中のみ": .whileWindowOpen,
            "常に表示": .always,
        ]
        if let value = Self(rawValue: raw) {
            self = value
        } else if let value = legacy[raw] {
            self = value
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown DockMode: \(raw)"
            )
        }
    }
}

enum StartupScreen: String, Codable, CaseIterable, Identifiable {
    case none
    case history
    case settings
    var id: Self { self }
    var title: String {
        switch self {
        case .none: L10n.t("Open nothing", "何も開かない")
        case .history: L10n.t("History", "履歴")
        case .settings: L10n.t("Settings", "設定")
        }
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        let legacy: [String: Self] = [
            "何も開かない": .none,
            "履歴": .history,
            "設定": .settings,
        ]
        if let value = Self(rawValue: raw) {
            self = value
        } else if let value = legacy[raw] {
            self = value
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown StartupScreen: \(raw)"
            )
        }
    }
}

enum ShelfPosition: String, Codable, CaseIterable, Identifiable {
    case bottomRight
    case bottomLeft
    case topRight
    case topLeft
    var id: Self { self }
    var title: String {
        switch self {
        case .bottomRight: L10n.t("Bottom right", "右下")
        case .bottomLeft: L10n.t("Bottom left", "左下")
        case .topRight: L10n.t("Top right", "右上")
        case .topLeft: L10n.t("Top left", "左上")
        }
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        let legacy: [String: Self] = [
            "右下": .bottomRight,
            "左下": .bottomLeft,
            "右上": .topRight,
            "左上": .topLeft,
        ]
        if let value = Self(rawValue: raw) {
            self = value
        } else if let value = legacy[raw] {
            self = value
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown ShelfPosition: \(raw)"
            )
        }
    }
}

enum ShelfThumbnailSize: String, Codable, CaseIterable, Identifiable {
    case small
    case medium
    case large
    var id: Self { self }
    var title: String {
        switch self {
        case .small: L10n.t("Small", "小")
        case .medium: L10n.t("Medium", "中")
        case .large: L10n.t("Large", "大")
        }
    }
    var width: CGFloat {
        switch self { case .small: 80; case .medium: 108; case .large: 148 }
    }
    var height: CGFloat { width * 0.76 }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        let legacy: [String: Self] = [
            "小": .small, "中": .medium, "大": .large,
        ]
        if let value = Self(rawValue: raw) {
            self = value
        } else if let value = legacy[raw] {
            self = value
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown ShelfThumbnailSize: \(raw)"
            )
        }
    }
}

enum ShelfAnimation: String, Codable, CaseIterable, Identifiable {
    case none
    case fade
    case slide
    var id: Self { self }
    var title: String {
        switch self {
        case .none: L10n.t("None", "なし")
        case .fade: L10n.t("Fade", "フェード")
        case .slide: L10n.t("Slide", "スライド")
        }
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        let legacy: [String: Self] = [
            "なし": .none,
            "フェード": .fade,
            "スライド": .slide,
        ]
        if let value = Self(rawValue: raw) {
            self = value
        } else if let value = legacy[raw] {
            self = value
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown ShelfAnimation: \(raw)"
            )
        }
    }
}

enum DragImageFormat: String, Codable, CaseIterable, Identifiable {
    case png = "PNG"
    case jpeg = "JPEG"
    var id: Self { self }
    var fileExtension: String { self == .png ? "png" : "jpg" }
}

enum EditorInitialZoom: String, Codable, CaseIterable, Identifiable {
    case fit
    case actualSize
    case fiftyPercent
    case twoHundredPercent
    var id: Self { self }
    var title: String {
        switch self {
        case .fit: L10n.t("Fit to window", "ウィンドウに合わせる")
        case .actualSize: "100%"
        case .fiftyPercent: "50%"
        case .twoHundredPercent: "200%"
        }
    }
    var scale: CGFloat? {
        switch self {
        case .fit: nil
        case .actualSize: 1
        case .fiftyPercent: 0.5
        case .twoHundredPercent: 2
        }
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        let legacy: [String: Self] = [
            "ウィンドウに合わせる": .fit,
            "100%": .actualSize,
            "50%": .fiftyPercent,
            "200%": .twoHundredPercent,
        ]
        if let value = Self(rawValue: raw) {
            self = value
        } else if let value = legacy[raw] {
            self = value
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown EditorInitialZoom: \(raw)"
            )
        }
    }
}

enum PostCaptureAction: String, Codable, CaseIterable, Identifiable {
    case shelfOnly
    case autoCopy
    case openAnnotation
    case saveDialog
    case autoSave
    case copyThenAnnotate
    case annotateThenCopy
    var id: Self { self }
    var title: String {
        switch self {
        case .shelfOnly: L10n.t("Temporary display only", "一時表示のみ")
        case .autoCopy: L10n.t("Auto copy", "自動コピー")
        case .openAnnotation: L10n.t("Open annotation", "注釈を開く")
        case .saveDialog: L10n.t("Save dialog", "保存ダイアログ")
        case .autoSave: L10n.t("Auto save", "自動保存")
        case .copyThenAnnotate: L10n.t("Copy then annotate", "コピーして注釈")
        case .annotateThenCopy: L10n.t("Annotate then copy", "注釈してコピー")
        }
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        let legacy: [String: Self] = [
            "Shelfのみ": .shelfOnly,
            "自動コピー": .autoCopy,
            "注釈を開く": .openAnnotation,
            "保存ダイアログ": .saveDialog,
            "自動保存": .autoSave,
            "コピーして注釈": .copyThenAnnotate,
            "注釈してコピー": .annotateThenCopy,
        ]
        if let value = Self(rawValue: raw) {
            self = value
        } else if let value = legacy[raw] {
            self = value
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown PostCaptureAction: \(raw)"
            )
        }
    }
}

enum SaveDestination: String, Codable, CaseIterable, Identifiable {
    case desktop = "Desktop"
    case downloads = "Downloads"
    case pictures = "Pictures"
    case custom
    var id: Self { self }
    var title: String {
        switch self {
        case .desktop: "Desktop"
        case .downloads: "Downloads"
        case .pictures: "Pictures"
        case .custom: L10n.t("Custom folder", "任意フォルダ")
        }
    }
    var searchDirectory: FileManager.SearchPathDirectory {
        switch self {
        case .desktop: .desktopDirectory
        case .downloads: .downloadsDirectory
        case .pictures: .picturesDirectory
        case .custom: .documentDirectory
        }
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if let value = Self(rawValue: raw) {
            self = value
        } else if raw == "任意フォルダ" {
            self = .custom
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown SaveDestination: \(raw)"
            )
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
    case addCounter
    case confirmOverwrite
    case alwaysOverwrite
    case cancel
    var id: Self { self }
    var title: String {
        switch self {
        case .addCounter: L10n.t("Add a counter", "連番を追加")
        case .confirmOverwrite: L10n.t("Confirm overwrite", "上書き確認")
        case .alwaysOverwrite: L10n.t("Always overwrite", "常に上書き")
        case .cancel: L10n.t("Cancel save", "保存を中止")
        }
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        let legacy: [String: Self] = [
            "連番を追加": .addCounter,
            "上書き確認": .confirmOverwrite,
            "常に上書き": .alwaysOverwrite,
            "保存を中止": .cancel,
        ]
        if let value = Self(rawValue: raw) {
            self = value
        } else if let value = legacy[raw] {
            self = value
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown FileCollisionPolicy: \(raw)"
            )
        }
    }
}

enum RetentionPeriod: Int, Codable, CaseIterable, Identifiable {
    case unlimited = 0
    case oneDay = 1
    case sevenDays = 7
    case thirtyDays = 30
    case ninetyDays = 90
    var id: Self { self }
    var title: String {
        if self == .unlimited {
            return L10n.t("No limit", "制限なし")
        }
        return L10n.tf("%d days", "%d日", rawValue)
    }
}

enum AnnotationCompletionAction: String, Codable, CaseIterable, Identifiable {
    case none
    case copy
    case save
    var id: Self { self }
    var title: String {
        switch self {
        case .none: L10n.t("Do nothing", "何もしない")
        case .copy: L10n.t("Copy", "コピー")
        case .save: L10n.t("Save", "保存")
        }
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        let legacy: [String: Self] = [
            "何もしない": .none,
            "コピー": .copy,
            "保存": .save,
        ]
        if let value = Self(rawValue: raw) {
            self = value
        } else if let value = legacy[raw] {
            self = value
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown AnnotationCompletionAction: \(raw)"
            )
        }
    }
}

struct ShortcutConfiguration: Codable, Equatable {
    var keyCode: UInt32 = 19 // 2
    var command = true
    var shift = true
    var option = false
    var control = false
    var isConfigured = true

    var display: String {
        guard isConfigured else { return L10n.t("Not set", "未設定") }
        return "\(control ? "⌃" : "")\(option ? "⌥" : "")\(shift ? "⇧" : "")\(command ? "⌘" : "")\(Self.keyName(keyCode))"
    }

    private enum CodingKeys: String, CodingKey {
        case keyCode, command, shift, option, control, isConfigured
    }

    init(
        keyCode: UInt32 = 19, command: Bool = true, shift: Bool = true,
        option: Bool = false, control: Bool = false,
        isConfigured: Bool = true
    ) {
        self.keyCode = keyCode
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
        self.isConfigured = isConfigured
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try values.decodeIfPresent(UInt32.self, forKey: .keyCode) ?? 19
        command = try values.decodeIfPresent(Bool.self, forKey: .command) ?? true
        shift = try values.decodeIfPresent(Bool.self, forKey: .shift) ?? true
        option = try values.decodeIfPresent(Bool.self, forKey: .option) ?? false
        control = try values.decodeIfPresent(Bool.self, forKey: .control) ?? false
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
    var preferredLanguage = AppLanguage.english

    private enum CodingKeys: String, CodingKey {
        case shortcut, menuBarMode, dockMode, shelfPosition, shelfDuration, shelfLimit
        case startupScreen
        case shelfThumbnailSize, shelfAnimation, dragImageFormat
        case historyLimit, includeCursor, postCaptureAction, retentionPeriod
        case historyEnabled, keepOriginalImages, cacheAnnotatedImages
        case deleteHistoryOnExit, pinnedItemsOutsideLimit
        case selectionDelay, overlayDimness, selectionBorderWidth
        case exportFormat, jpegQuality, filenameTemplate, saveDestination
        case customSaveFolderBookmark, customSaveFolderName
        case fileCollisionPolicy, preserveExportMetadata
        case pauseShelfTimerOnHover, soundEnabled, hasCompletedSetup
        case defaultAnnotationTool, defaultAnnotationColor, defaultAnnotationLineWidth
        case defaultMarkerOpacity, defaultFontName, defaultFontSize, annotationCompletionAction
        case defaultTextAlignment, editorInitialZoom, preferredLanguage
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        shortcut = try values.decodeIfPresent(ShortcutConfiguration.self, forKey: .shortcut) ?? ShortcutConfiguration()
        menuBarMode = try values.decodeIfPresent(MenuBarMode.self, forKey: .menuBarMode) ?? .always
        dockMode = try values.decodeIfPresent(DockMode.self, forKey: .dockMode) ?? .never
        startupScreen = try values.decodeIfPresent(StartupScreen.self, forKey: .startupScreen) ?? .none
        shelfPosition = try values.decodeIfPresent(ShelfPosition.self, forKey: .shelfPosition) ?? .bottomRight
        shelfThumbnailSize = try values.decodeIfPresent(ShelfThumbnailSize.self, forKey: .shelfThumbnailSize) ?? .medium
        shelfAnimation = try values.decodeIfPresent(ShelfAnimation.self, forKey: .shelfAnimation) ?? .fade
        dragImageFormat = try values.decodeIfPresent(DragImageFormat.self, forKey: .dragImageFormat) ?? .png
        shelfDuration = try values.decodeIfPresent(Double.self, forKey: .shelfDuration) ?? 0
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
        preferredLanguage = try values.decodeIfPresent(AppLanguage.self, forKey: .preferredLanguage) ?? .english
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
