import SwiftUI
import AppKit
import ServiceManagement

enum CaptureStartPolicy {
    static func allows(
        isCapturing: Bool, isEditing: Bool, shortcut: ShortcutConfiguration
    ) -> Bool {
        !isCapturing && !isEditing && shortcut.isConfigured
    }
}

enum DockVisibilityPolicy {
    static func shouldShow(mode: DockMode, hasVisibleWindow: Bool) -> Bool {
        switch mode {
        case .never: false
        case .whileWindowOpen: hasVisibleWindow
        case .always: true
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var settings = SettingsStore.shared.load()
    @Published var history: [CaptureItem] = []
    @Published var shelfItems: [CaptureItem] = []
    @Published var errorMessage: String?
    @Published var shortcutRegistrationFailed = false
    @Published var isCapturing = false
    @Published var isEditing = false
    @Published var copiedItemID: UUID?
    @Published var copyFailedItemID: UUID?
    var isProcessing: Bool { isCapturing || isEditing }

    private let historyStore = HistoryStore()
    private let shortcutService = GlobalShortcutService()
    private let overlay = SelectionOverlayController()
    private let menuBar = MenuBarController()
    private let shelf = ShelfController()
    private let historyWindow = HistoryWindowController()
    private let settingsWindow = SettingsWindowController()
    private let annotationEditor = AnnotationEditorController()
    private var transientURLs: [UUID: URL] = [:]
    private var transientRenderedURLs: [UUID: URL] = [:]
    private var lastValidShortcut = ShortcutConfiguration()
    private var copyAfterEditing: Set<UUID> = []
    private var historyPreparationTask: Task<Void, Never>?
    private var settingsSaveTask: Task<Void, Never>?
    private var temporaryFileMaintenanceTask: Task<Void, Never>?
    private var isShelfHovered = false
    private var shelfOperationCount = 0
    private var shelfEditingIDs: Set<UUID> = []

    func start(isLoginItemLaunch: Bool = false) {
        LanguageCenter.shared.apply(settings.preferredLanguage)
        Task { await LogService.shared.record(.appStarted) }
        if let settingsLoadFailure = SettingsStore.shared.consumeLoadFailure() {
            showError(settingsLoadFailure.localizedDescription)
            Task {
                await LogService.shared.record(
                    .settingsLoadFailed,
                    code: .errorType(
                        String(
                            describing: type(
                                of: settingsLoadFailure.underlyingError
                            )
                        )
                    )
                )
            }
        }
        Task {
            await LogService.shared.record(
                PermissionService.isGranted ? .permissionGranted : .permissionDenied
            )
        }
        historyPreparationTask = Task {
            do {
                try await historyStore.prepare()
            } catch {
                showError(ErrorPresentation.message(for: error))
                await LogService.shared.record(
                    .historyLoadFailed,
                    code: .errorType(String(describing: type(of: error)))
                )
            }
            do {
                try await historyStore.performStartupMaintenance(
                    retention: settings.retentionPeriod,
                    historyEnabled: settings.historyEnabled,
                    limit: settings.historyLimit,
                    preservesPinned: settings.pinnedItemsOutsideLimit
                )
            } catch {
                reportHistoryMutationError(error)
            }
            refreshHistory()
        }
        temporaryFileMaintenanceTask?.cancel()
        temporaryFileMaintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(3_600))
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                await self.historyStore.cleanupExpiredDragCache()
            }
        }
        Task {
            await historyPreparationTask?.value
            await historyStore.ensureThumbnails()
            refreshHistory()
        }
        shortcutService.onPress = { [weak self] in self?.startCapture() }
        shortcutRegistrationFailed = !shortcutService.register(settings.shortcut)
        Task { await LogService.shared.record(shortcutRegistrationFailed ? .shortcutRegistrationFailed : .shortcutRegistered) }
        if !shortcutRegistrationFailed { lastValidShortcut = settings.shortcut }
        menuBar.attach(model: self)
        menuBar.update()
        applyActivationPolicy(windowIsOpen: false)
        switch StartupDisplayPolicy.initialSurface(
            hasCompletedSetup: settings.hasCompletedSetup,
            startupScreen: settings.startupScreen,
            isLoginItemLaunch: isLoginItemLaunch
        ) {
        case .none:
            break
        case .setup:
            showSettings()
        case .history:
            showHistory()
        case .settings:
            showSettings()
        }
    }

    func stop() async {
        temporaryFileMaintenanceTask?.cancel()
        temporaryFileMaintenanceTask = nil
        await historyPreparationTask?.value
        await settingsSaveTask?.value
        shortcutService.unregister()
        let originalURLs = Array(transientURLs.values)
        let renderedURLs = Array(transientRenderedURLs.values)
        let transientIDs = Array(transientURLs.keys)
        await Task.detached(priority: .utility) {
            for url in originalURLs + renderedURLs {
                try? FileManager.default.removeItem(at: url)
            }
            for id in transientIDs {
                try? FileManager.default.removeItem(
                    at: StoragePaths.thumbnails.appendingPathComponent(
                        "\(id.uuidString).png"
                    )
                )
                HistoryRelatedFileService.removeDragFiles(for: id)
            }
        }.value
        await historyStore.clearDragCache()
        if settings.deleteHistoryOnExit {
            do {
                try await historyStore.deleteAll()
            } catch {
                await LogService.shared.record(
                    .historySaveFailed,
                    code: .errorType(String(describing: type(of: error)))
                )
            }
        }
        await LogService.shared.record(.appStopped)
    }

    func setLanguage(_ language: AppLanguage) {
        LanguageCenter.shared.apply(language)
        settings.preferredLanguage = language
        persistSettings()
        applyLocalizationToWindows()
    }

    func applyLocalizationToWindows() {
        menuBar.update()
        historyWindow.applyLocalization()
        settingsWindow.applyLocalization()
        annotationEditor.applyLocalization()
    }

    func persistSettings() {
        LanguageCenter.shared.apply(settings.preferredLanguage)
        let requestedShortcut = settings.shortcut
        shortcutRegistrationFailed = !shortcutService.register(requestedShortcut)
        Task { await LogService.shared.record(shortcutRegistrationFailed ? .shortcutRegistrationFailed : .shortcutRegistered) }
        if shortcutRegistrationFailed {
            settings.shortcut = lastValidShortcut
            _ = shortcutService.register(lastValidShortcut)
        } else {
            lastValidShortcut = requestedShortcut
        }
        let settingsSnapshot = settings
        let previousSave = settingsSaveTask
        settingsSaveTask = Task {
            await previousSave?.value
            do {
                try await Task.detached(priority: .utility) {
                    try SettingsStore.shared.save(settingsSnapshot)
                }.value
            } catch {
                showError(L10n.t("Could not save settings.\n", "設定を保存できませんでした。\n") + error.localizedDescription)
                await LogService.shared.record(
                    .settingsSaveFailed,
                    code: .errorType(String(describing: type(of: error)))
                )
            }
        }
        Task {
            await historyPreparationTask?.value
            if settings.historyEnabled {
                do {
                    try await historyStore.enforceLimit(
                        settings.historyLimit,
                        preservesPinned: settings.pinnedItemsOutsideLimit
                    )
                } catch {
                    reportHistoryMutationError(error)
                }
            }
            do {
                try await historyStore.enforceRetention(
                    settings.retentionPeriod
                )
            } catch {
                reportHistoryMutationError(error)
            }
            refreshHistory()
        }
        menuBar.update()
        applyActivationPolicy(windowIsOpen: false)
    }

    func startCapture() {
        guard CaptureStartPolicy.allows(
            isCapturing: isCapturing, isEditing: isEditing, shortcut: settings.shortcut
        ) else { return }
        guard PermissionService.isGranted else {
            Task { await LogService.shared.record(.permissionDenied) }
            // request() inside openSettings registers CapMark in the TCC list first
            PermissionService.openSettings()
            errorMessage = L10n.t("Please allow screen recording. Turn CapMark on in System Settings, then restart the app.", "画面キャプチャ権限を許可してください。システム設定でCapMarkをオンにしたあと、アプリを再起動してください。")
            showSettings()
            return
        }
        isCapturing = true
        menuBar.update()
        shelf.hide()
        overlay.begin(
            dimness: settings.overlayDimness,
            borderWidth: settings.selectionBorderWidth
        ) { [weak self] screen, rect in
            self?.capture(screen: screen, rect: rect)
        } onCancel: { [weak self] in
            self?.isCapturing = false
            self?.menuBar.update()
        }
    }

    private func capture(screen: NSScreen, rect: CGRect) {
        Task {
            do {
                await historyPreparationTask?.value
                if settings.selectionDelay > 0 {
                    try await Task.sleep(for: .seconds(settings.selectionDelay))
                }
                let result = try await ScreenshotService.capture(
                    screen: screen, rectInScreen: rect, includeCursor: settings.includeCursor
                )
                let item = try await historyStore.add(
                    image: result.image, displayID: result.displayID, displayName: result.displayName,
                    scale: result.scale, rect: result.globalRect,
                    displayLocalRect: result.displayLocalRect,
                    limit: settings.historyEnabled ? settings.historyLimit : 0,
                    preservesPinned: settings.pinnedItemsOutsideLimit
                )
                if !settings.historyEnabled || settings.historyLimit == 0 {
                    transientURLs[item.id] = item.originalURL
                }
                shelfItems = [item]
                refreshHistory()
                isEditing = true
                overlay.beginQuickAnnotation(
                    image: result.image, item: item, settings: settings
                ) { [weak self] document in
                    guard let self else { return }
                    Task {
                        await self.finishEditing(item: item, document: document)
                        self.isEditing = false
                        self.isCapturing = false
                        self.menuBar.update()
                        self.presentShelf()
                    }
                } onCancel: { [weak self] in
                    guard let self else { return }
                    self.isEditing = false
                    self.isCapturing = false
                    self.menuBar.update()
                    self.delete(item)
                }
                Task { await LogService.shared.record(.captureSucceeded) }
                menuBar.update()
                return
            } catch let failure as HistorySaveFailure {
                let item = failure.item
                transientURLs[item.id] = item.originalURL
                shelfItems = [item]
                presentShelf()
                let message = ErrorPresentation.message(for: failure)
                errorMessage = message
                showError(message)
                Task {
                    await LogService.shared.record(
                        .historySaveFailed,
                        code: .errorType(
                            String(
                                describing: type(
                                    of: failure.underlyingError
                                )
                            )
                        )
                    )
                }
            } catch {
                let message = ErrorPresentation.message(for: error)
                errorMessage = message
                showError(message)
                Task {
                    await LogService.shared.record(
                        .captureFailed,
                        code: .errorType(
                            String(describing: type(of: error))
                        )
                    )
                }
            }
            overlay.cancel()
            isCapturing = false
            isEditing = false
            menuBar.update()
        }
    }

    func copy(_ item: CaptureItem) {
        performCopy(item) {
            try await ClipboardService.copy(item)
        }
    }

    func copyOriginal(_ item: CaptureItem) {
        performCopy(item) {
            try await ClipboardService.copyOriginal(item)
        }
    }

    func copyImageData(_ item: CaptureItem) {
        performCopy(item) {
            try await ClipboardService.copyImageData(item)
        }
    }

    func copyFile(_ item: CaptureItem) {
        performCopy(item) {
            try await ClipboardService.copyFile(item)
        }
    }
    func save(_ item: CaptureItem) {
        let suspendsAutoHide = beginShelfOperation(for: item)
        FileExportService.save(item, settings: settings) { [weak self] ids in
            guard let self else { return }
            defer { endShelfOperation(if: suspendsAutoHide) }
            if !ids.isEmpty { recordSaved(ids) }
        }
    }

    func save(_ items: [CaptureItem]) {
        FileExportService.save(items, settings: settings) { [weak self] ids in
            if !ids.isEmpty { self?.recordSaved(ids) }
        }
    }

    func edit(_ item: CaptureItem) {
        guard history.contains(where: { $0.id == item.id }) || transientURLs[item.id] != nil else {
            errorMessage = L10n.t("This image was already removed from the temporary display.", "この画像はすでに一時表示から削除されています。")
            return
        }
        let document: CaptureDocument
        do {
            document = try historyStore.document(for: item)
        } catch {
            let message = ErrorPresentation.message(for: error)
            errorMessage = message
            showError(message)
            Task {
                await LogService.shared.record(
                    .annotationDataCorrupt,
                    code: .errorType(String(describing: type(of: error)))
                )
            }
            return
        }
        applyActivationPolicy(windowIsOpen: true)
        if shelfItems.contains(where: { $0.id == item.id }),
           shelfEditingIDs.insert(item.id).inserted {
            beginShelfOperation()
        }
        isEditing = true
        menuBar.update()
        annotationEditor.show(item: item, document: document, model: self)
    }

    @discardableResult
    func finishEditing(item: CaptureItem, document: CaptureDocument) async -> CaptureItem? {
        do {
            let isPersistent = history.contains { $0.id == item.id }
            let updated = isPersistent
                ? try await historyStore.save(
                    document: document, for: item,
                    keepOriginal: settings.keepOriginalImages,
                    cacheRendered: settings.cacheAnnotatedImages
                )
                : try await historyStore.saveTemporary(document: document, for: item)
            if !isPersistent { transientRenderedURLs[item.id] = updated.bestURL }
            if let index = shelfItems.firstIndex(where: { $0.id == item.id }) {
                shelfItems[index] = updated
            }
            ThumbnailImageCache.shared.removeAll()
            refreshHistory()
            presentShelf()
            return updated
        } catch {
            let message = ErrorPresentation.message(for: error)
            errorMessage = message
            showError(message)
            return nil
        }
    }

    func annotationDidClose() {
        isEditing = false
        menuBar.update()
    }

    func editorDidFinish(_ item: CaptureItem) {
        defer { endShelfEditing(item.id) }
        if copyAfterEditing.remove(item.id) != nil {
            copy(item)
            return
        }
        switch settings.annotationCompletionAction {
        case .none: break
        case .copy: copy(item)
        case .save: save(item)
        }
    }

    func editorDidCancel(_ id: UUID) {
        defer { endShelfEditing(id) }
        copyAfterEditing.remove(id)
        if transientURLs[id] != nil {
            presentShelf()
        }
    }

    func captureItem(id: UUID) -> CaptureItem? {
        history.first(where: { $0.id == id })
            ?? shelfItems.first(where: { $0.id == id })
    }

    func delete(_ item: CaptureItem) {
        if history.contains(where: { $0.id == item.id }) {
            Task {
                await historyPreparationTask?.value
                do {
                    try await historyStore.delete(item)
                    shelfItems.removeAll { $0.id == item.id }
                    refreshHistory()
                    presentShelf()
                } catch {
                    reportHistoryMutationError(error)
                }
            }
            return
        } else {
            try? FileManager.default.removeItem(at: item.originalURL)
            transientURLs.removeValue(forKey: item.id)
            try? FileManager.default.removeItem(at: item.thumbnailURL)
            if let rendered = transientRenderedURLs.removeValue(forKey: item.id) {
                try? FileManager.default.removeItem(at: rendered)
            }
            HistoryRelatedFileService.removeDragFiles(for: item.id)
        }
        shelfItems.removeAll { $0.id == item.id }
        refreshHistory()
        presentShelf()
    }

    func togglePin(_ item: CaptureItem) {
        Task {
            await historyPreparationTask?.value
            do {
                try await historyStore.togglePin(item)
                try await historyStore.enforceLimit(
                    settings.historyLimit,
                    preservesPinned: settings.pinnedItemsOutsideLimit
                )
            } catch {
                reportHistoryMutationError(error)
            }
            refreshHistory()
        }
    }

    func duplicate(_ item: CaptureItem) {
        Task {
            do {
                await historyPreparationTask?.value
                _ = try await historyStore.duplicate(
                    item, limit: settings.historyLimit,
                    preservesPinned: settings.pinnedItemsOutsideLimit
                )
                refreshHistory()
            } catch { showError(ErrorPresentation.message(for: error)) }
        }
    }

    func reveal(_ item: CaptureItem, rendered: Bool = true) {
        if !rendered {
            NSWorkspace.shared.activateFileViewerSelecting([item.originalURL])
            return
        }
        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try ImageMaterializationService.materializeLatestPNG(
                        for: item, suffix: "finder"
                    )
                }.value
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                await LogService.shared.record(
                    .exportFailed,
                    code: .errorType(String(describing: type(of: error)))
                )
                showError(ErrorPresentation.message(for: error))
            }
        }
    }

    func sendToShelf(_ item: CaptureItem) {
        shelfItems = [item]
        presentShelf()
    }

    func deleteAllHistory() {
        shelfItems.removeAll()
        shelf.hide()
        Task { await performDeleteAllHistory() }
    }

    func deleteAllData() {
        shelfItems.removeAll()
        shelf.hide()
        ThumbnailImageCache.shared.removeAll()
        Task {
            await performDeleteAllHistory()
            await performClearCache()
            await LogService.shared.clear()
        }
    }

    func clearCache() {
        ThumbnailImageCache.shared.removeAll()
        Task { await performClearCache() }
    }

    private func performDeleteAllHistory() async {
        let deletedCount = history.count
        await historyPreparationTask?.value
        do {
            try await historyStore.deleteAll()
            refreshHistory()
            await LogService.shared.record(
                .historyCleaned, code: .count(deletedCount)
            )
        } catch {
            reportHistoryMutationError(error)
        }
    }

    private func performClearCache() async {
        do {
            try await Task.detached(priority: .utility) {
                try CacheCleanupService.clear()
            }.value
            refreshHistory()
        } catch {
            showError(
                L10n.t(
                    "Could not clear the cache.\n",
                    "キャッシュを削除できませんでした。\n"
                ) + error.localizedDescription
            )
            await LogService.shared.record(
                .cacheCleanupFailed,
                code: .errorType(String(describing: type(of: error)))
            )
        }
    }

    func clearLogs() {
        Task { await LogService.shared.clear() }
    }

    func resetSettings() {
        settings = AppSettings()
        LanguageCenter.shared.apply(settings.preferredLanguage)
        persistSettings()
        applyLocalizationToWindows()
    }

    func applyActivationPolicy(windowIsOpen: Bool) {
        let hasVisibleWindow = windowIsOpen || NSApp.windows.contains {
            $0.isVisible && !($0 is NSPanel) && $0.styleMask.contains(.titled)
        }
        let policy: NSApplication.ActivationPolicy = DockVisibilityPolicy.shouldShow(
            mode: settings.dockMode, hasVisibleWindow: hasVisibleWindow
        ) ? .regular : .accessory
        NSApp.setActivationPolicy(policy)
    }

    var diskUsageText: String {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: StoragePaths.root, includingPropertiesForKeys: Array(keys)
        ) else { return "0 KB" }
        var bytes = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isRegularFile == true { bytes += values?.fileSize ?? 0 }
        }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    func delete(_ items: [CaptureItem]) {
        shelfItems.removeAll { candidate in items.contains(where: { $0.id == candidate.id }) }
        Task {
            await historyPreparationTask?.value
            do {
                try await historyStore.delete(items)
                refreshHistory()
            } catch {
                reportHistoryMutationError(error)
            }
        }
    }

    func showHistory() {
        applyActivationPolicy(windowIsOpen: true)
        historyWindow.show(model: self)
    }

    func showShelf() {
        let source = shelfItems.isEmpty
            ? Array(history.prefix(1))
            : Array(shelfItems.prefix(1))
        shelf.show(items: source, model: self)
    }

    /// Shelfを閉じる（閉じるボタン）。表示中の一時ファイルも片付け対象になる。
    func dismissShelf() {
        shelf.hide()
    }

    func shelfHoverChanged(_ hovering: Bool) {
        guard isShelfHovered != hovering else { return }
        isShelfHovered = hovering
        updateShelfAutoHideState()
    }

    func editorWindowDidClose(_ id: UUID) {
        endShelfEditing(id)
    }

    func shelfDidHide() {
        isShelfHovered = false
        let transientIDs = Set(transientURLs.keys)
        for url in transientURLs.values {
            try? FileManager.default.removeItem(at: url)
        }
        for url in transientRenderedURLs.values {
            try? FileManager.default.removeItem(at: url)
        }
        for id in transientIDs {
            try? FileManager.default.removeItem(
                at: StoragePaths.thumbnails.appendingPathComponent("\(id.uuidString).png")
            )
            HistoryRelatedFileService.removeDragFiles(for: id)
        }
        transientURLs.removeAll()
        transientRenderedURLs.removeAll()
        shelfItems.removeAll { transientIDs.contains($0.id) }
    }

    func dragURL(for item: CaptureItem) async throws -> URL {
        let exportSettings = settings
        return try await Task.detached(priority: .userInitiated) {
            try DragExportService.materialize(for: item, settings: exportSettings)
        }.value
    }

    func showSettings() {
        applyActivationPolicy(windowIsOpen: true)
        settingsWindow.show(model: self)
    }

    func quit() { NSApp.terminate(nil) }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { errorMessage = ErrorPresentation.message(for: error) }
    }

    private func refreshHistory() {
        history = historyStore.items
        menuBar.update()
    }

    private func performPostCaptureAction(_ item: CaptureItem) {
        switch settings.postCaptureAction {
        case .shelfOnly:
            presentShelf()
        case .autoCopy:
            copy(item)
            presentShelf()
            return
        case .openAnnotation:
            edit(item)
        case .saveDialog:
            save(item)
            presentShelf()
            return
        case .autoSave:
            Task {
                do {
                    _ = try await FileExportService.autoSave(
                        item, settings: settings
                    )
                    recordSaved([item.id])
                } catch let error
                    where ErrorPresentation.isUserCancellation(error) {
                } catch {
                    await LogService.shared.record(
                        .exportFailed,
                        code: .errorType(
                            String(describing: type(of: error))
                        )
                    )
                    showError(ErrorPresentation.message(for: error))
                }
            }
            presentShelf()
            return
        case .copyThenAnnotate:
            copy(item)
            edit(item)
        case .annotateThenCopy:
            copyAfterEditing.insert(item.id)
            edit(item)
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "CapMark"
        alert.informativeText = message
        alert.runModal()
    }

    private func showCopyFeedback(_ id: UUID, succeeded: Bool) {
        if succeeded {
            copiedItemID = id
            copyFailedItemID = nil
        } else {
            copyFailedItemID = id
            copiedItemID = nil
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copiedItemID == id { copiedItemID = nil }
            if copyFailedItemID == id { copyFailedItemID = nil }
        }
    }

    private func performCopy(
        _ item: CaptureItem,
        operation: @escaping @MainActor () async throws -> Bool
    ) {
        let suspendsAutoHide = beginShelfOperation(for: item)
        Task {
            defer { endShelfOperation(if: suspendsAutoHide) }
            do {
                let succeeded = try await operation()
                showCopyFeedback(item.id, succeeded: succeeded)
                if succeeded {
                    recordCopied(item.id)
                    FeedbackService.copied(settings: settings)
                } else {
                    FeedbackService.copyFailed(settings: settings)
                }
            } catch {
                showCopyFeedback(item.id, succeeded: false)
                FeedbackService.copyFailed(settings: settings)
                showError(ErrorPresentation.message(for: error))
                await LogService.shared.record(
                    error is AnnotationDocumentReadError
                        ? .annotationDataCorrupt : .exportFailed,
                    code: .errorType(String(describing: type(of: error)))
                )
            }
        }
    }

    private func recordCopied(_ itemID: UUID) {
        let date = Date()
        if let index = shelfItems.firstIndex(where: { $0.id == itemID }) {
            shelfItems[index].lastCopiedAt = date
        }
        Task {
            await historyPreparationTask?.value
            do {
                try await historyStore.recordCopied(
                    itemID: itemID, at: date
                )
                refreshHistory()
            } catch {
                reportHistoryMutationError(error)
            }
        }
    }

    private func recordSaved(_ itemIDs: Set<UUID>) {
        let date = Date()
        for index in shelfItems.indices
        where itemIDs.contains(shelfItems[index].id) {
            shelfItems[index].lastSavedAt = date
        }
        Task {
            await historyPreparationTask?.value
            do {
                try await historyStore.recordSaved(
                    itemIDs: itemIDs, at: date
                )
                refreshHistory()
            } catch {
                reportHistoryMutationError(error)
            }
        }
    }

    private func reportHistoryMutationError(_ error: Error) {
        showError(ErrorPresentation.message(for: error))
        Task {
            await LogService.shared.record(
                .historySaveFailed,
                code: .errorType(String(describing: type(of: error)))
            )
        }
    }

    private func presentShelf() {
        shelf.show(items: Array(shelfItems.prefix(1)), model: self)
        updateShelfAutoHideState()
    }

    @discardableResult
    private func beginShelfOperation(for item: CaptureItem) -> Bool {
        guard shelfItems.contains(where: { $0.id == item.id }) else {
            return false
        }
        beginShelfOperation()
        return true
    }

    private func beginShelfOperation() {
        shelfOperationCount += 1
        updateShelfAutoHideState()
    }

    private func endShelfOperation(if began: Bool) {
        guard began else { return }
        shelfOperationCount = max(0, shelfOperationCount - 1)
        updateShelfAutoHideState()
    }

    private func endShelfEditing(_ id: UUID) {
        guard shelfEditingIDs.remove(id) != nil else { return }
        endShelfOperation(if: true)
    }

    private func updateShelfAutoHideState() {
        if ShelfAutoHidePolicy.shouldSchedule(
            isHovered: isShelfHovered,
            activeOperationCount: shelfOperationCount,
            pausesOnHover: settings.pauseShelfTimerOnHover
        ) {
            shelf.resumeAutoHide(model: self)
        } else {
            shelf.pauseAutoHide()
        }
    }

    private func removeTransient(id: UUID) {
        if let original = transientURLs.removeValue(forKey: id) {
            try? FileManager.default.removeItem(at: original)
        }
        if let rendered = transientRenderedURLs.removeValue(forKey: id) {
            try? FileManager.default.removeItem(at: rendered)
        }
        try? FileManager.default.removeItem(
            at: StoragePaths.thumbnails.appendingPathComponent("\(id.uuidString).png")
        )
        shelfItems.removeAll { $0.id == id }
    }
}
