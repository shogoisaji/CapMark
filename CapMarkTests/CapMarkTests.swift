import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import CapMark

final class CapMarkTests: XCTestCase {
    func testShortcutRequiresModifierValidationInputs() {
        let shortcut = ShortcutConfiguration(keyCode: 0, command: true, shift: false, option: false, control: false, enabled: true)
        XCTAssertEqual(shortcut.display, "⌘A")
        XCTAssertTrue(ShortcutConflictValidator.isReserved(shortcut))
    }

    func testSelectionKeyboardMovementClampsWithoutShrinking() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 80)
        let movedPastLeftEdge = CGRect(x: -10, y: 20, width: 40, height: 30)
        let clamped = SelectionGeometry.clamped(movedPastLeftEdge, to: bounds)
        XCTAssertEqual(clamped, CGRect(x: 0, y: 20, width: 40, height: 30))

        let movedPastTopRight = CGRect(x: 90, y: 70, width: 40, height: 30)
        XCTAssertEqual(
            SelectionGeometry.clamped(movedPastTopRight, to: bounds),
            CGRect(x: 60, y: 50, width: 40, height: 30)
        )
    }

    func testDisplayCoordinateMappingWithNegativeScreenOrigin() {
        let screen = CGRect(x: -1920, y: 200, width: 1920, height: 1080)
        let global = CGRect(x: -1720, y: 500, width: 400, height: 300)
        XCTAssertEqual(
            DisplayCoordinateMapper.displayLocalRect(
                globalRect: global, screenFrame: screen
            ),
            CGRect(x: 200, y: 300, width: 400, height: 300)
        )
        XCTAssertEqual(
            DisplayCoordinateMapper.screenCaptureSourceRect(
                globalRect: global, screenFrame: screen
            ),
            CGRect(x: 200, y: 480, width: 400, height: 300)
        )
    }

    func testCaptureItemMigrationAllowsMissingDisplayLocalRect() throws {
        let legacy = sampleItem()
        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(CaptureItem.self, from: data)
        XCTAssertNil(decoded.displayLocalRect)
        XCTAssertNil(decoded.lastCopiedAt)
        XCTAssertNil(decoded.lastSavedAt)
    }

    func testCaptureStartPolicyRejectsBusyEditingAndUnconfiguredStates() {
        let shortcut = ShortcutConfiguration()
        XCTAssertTrue(CaptureStartPolicy.allows(
            isCapturing: false, isEditing: false, shortcut: shortcut
        ))
        XCTAssertFalse(CaptureStartPolicy.allows(
            isCapturing: true, isEditing: false, shortcut: shortcut
        ))
        XCTAssertFalse(CaptureStartPolicy.allows(
            isCapturing: false, isEditing: true, shortcut: shortcut
        ))
        XCTAssertFalse(CaptureStartPolicy.allows(
            isCapturing: false, isEditing: false,
            shortcut: ShortcutConfiguration(enabled: false, isConfigured: false)
        ))
    }

    func testDockAndMenuBarVisibilityPolicies() {
        XCTAssertFalse(DockVisibilityPolicy.shouldShow(
            mode: .never, hasVisibleWindow: true
        ))
        XCTAssertFalse(DockVisibilityPolicy.shouldShow(
            mode: .whileWindowOpen, hasVisibleWindow: false
        ))
        XCTAssertTrue(DockVisibilityPolicy.shouldShow(
            mode: .whileWindowOpen, hasVisibleWindow: true
        ))
        XCTAssertTrue(DockVisibilityPolicy.shouldShow(
            mode: .always, hasVisibleWindow: false
        ))

        XCTAssertTrue(MenuBarVisibilityPolicy.shouldShow(
            mode: .always, isProcessing: false, hasHistory: false
        ))
        XCTAssertTrue(MenuBarVisibilityPolicy.shouldShow(
            mode: .duringProcessing, isProcessing: true, hasHistory: false
        ))
        XCTAssertFalse(MenuBarVisibilityPolicy.shouldShow(
            mode: .duringProcessing, isProcessing: false, hasHistory: true
        ))
        XCTAssertTrue(MenuBarVisibilityPolicy.shouldShow(
            mode: .whenHistoryExists, isProcessing: false, hasHistory: true
        ))
        XCTAssertFalse(MenuBarVisibilityPolicy.shouldShow(
            mode: .never, isProcessing: true, hasHistory: true
        ))
    }

    func testStartupDisplayPolicySuppressesWindowsForLoginItemLaunch() {
        for screen in StartupScreen.allCases {
            XCTAssertEqual(
                StartupDisplayPolicy.initialSurface(
                    hasCompletedSetup: true,
                    startupScreen: screen,
                    isLoginItemLaunch: true
                ),
                .none
            )
        }
        XCTAssertEqual(
            StartupDisplayPolicy.initialSurface(
                hasCompletedSetup: false,
                startupScreen: .settings,
                isLoginItemLaunch: true
            ),
            .none,
            "ログイン起動では未完了のセットアップ画面も自動表示しない"
        )

        XCTAssertEqual(
            StartupDisplayPolicy.initialSurface(
                hasCompletedSetup: false,
                startupScreen: .none,
                isLoginItemLaunch: false
            ),
            .setup
        )
        XCTAssertEqual(
            StartupDisplayPolicy.initialSurface(
                hasCompletedSetup: true,
                startupScreen: .history,
                isLoginItemLaunch: false
            ),
            .history
        )
    }

    func testLoginItemLaunchContextReadsAppleEventFlag() {
        let event = NSAppleEventDescriptor.record()
        event.setParam(
            NSAppleEventDescriptor(boolean: true),
            forKeyword: AEKeyword(keyAELaunchedAsLogInItem)
        )

        XCTAssertTrue(AppLaunchContext.isLoginItemLaunch(event: event))
        XCTAssertFalse(AppLaunchContext.isLoginItemLaunch(event: nil))
    }

    func testHistoryLimitNeverRemovesPinnedItems() {
        XCTAssertEqual(
            HistoryLimitPolicy.removableCount(
                totalCount: 25, unpinnedCount: 20, limit: 20,
                pinnedItemsOutsideLimit: true
            ),
            0,
            "上限対象外のピン留め5件は、未ピン留め20件の枠を消費しない"
        )
        XCTAssertEqual(
            HistoryLimitPolicy.removableCount(
                totalCount: 25, unpinnedCount: 20, limit: 20,
                pinnedItemsOutsideLimit: false
            ),
            5,
            "ピン留めを上限へ数える場合も、削除対象は未ピン留めだけ"
        )
        XCTAssertEqual(
            HistoryLimitPolicy.removableCount(
                totalCount: 25, unpinnedCount: 0, limit: 20,
                pinnedItemsOutsideLimit: false
            ),
            0,
            "全項目がピン留めなら上限超過しても自動削除しない"
        )
        XCTAssertTrue(
            HistoryLimitPolicy.exceedsLimit(
                totalCount: 25, unpinnedCount: 0, limit: 20,
                pinnedItemsOutsideLimit: false
            )
        )
        XCTAssertFalse(
            HistoryLimitPolicy.exceedsLimit(
                totalCount: 25, unpinnedCount: 20, limit: 20,
                pinnedItemsOutsideLimit: true
            )
        )
    }

    func testHistoryMetadataPersistenceReportsWriteFailure() throws {
        let blockingFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data("not a directory".utf8).write(to: blockingFile)
        defer { try? FileManager.default.removeItem(at: blockingFile) }

        let impossibleDestination = blockingFile.appendingPathComponent("history.json")
        XCTAssertThrowsError(
            try HistoryMetadataPersistence.write(
                [sampleItem()], to: impossibleDestination
            )
        )
    }

    @MainActor
    func testCorruptHistoryMetadataIsMovedToPrivateRecoveryFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let historyURL = directory.appendingPathComponent("history.json")
        let corruptData = Data("{not valid json".utf8)
        try corruptData.write(to: historyURL)
        let store = HistoryStore(
            storageWorker: HistoryStorageWorker(historyURL: historyURL)
        )
        var recoveryURL: URL?

        do {
            try await store.prepare()
            XCTFail("破損履歴JSONの読込は復旧通知を返す必要がある")
        } catch let error as HistoryLoadFailure {
            recoveryURL = error.recoveryURL
        }

        let recovered = try XCTUnwrap(recoveryURL)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: historyURL.path),
            "破損JSONを新しい履歴で上書き可能な場所へ残さない"
        )
        XCTAssertEqual(try Data(contentsOf: recovered), corruptData)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: recovered.path
        )
        let permissions = try XCTUnwrap(
            attributes[.posixPermissions] as? NSNumber
        ).intValue
        XCTAssertEqual(permissions & 0o777, 0o600)
        XCTAssertTrue(store.items.isEmpty)
    }

    @MainActor
    func testStartupReconcilesMissingOriginalAndRemovesOrphanedFiles() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        func item(id: UUID) -> CaptureItem {
            CaptureItem(
                id: id, createdAt: Date(), updatedAt: Date(),
                originalFilename: "\(id.uuidString).png",
                renderedFilename: "\(id.uuidString).png",
                documentFilename: "\(id.uuidString).json",
                thumbnailFilename: "\(id.uuidString).png",
                pixelWidth: 10, pixelHeight: 10, displayID: 1,
                displayName: "Test", scale: 1,
                selectionRect: .zero, isPinned: false,
                annotationCount: 0
            )
        }
        let valid = item(id: UUID())
        let missing = item(id: UUID())
        let missingRelatedURLs = [
            StoragePaths.rendered.appendingPathComponent(
                "\(missing.id.uuidString).png"
            ),
            StoragePaths.documents.appendingPathComponent(
                "\(missing.id.uuidString).json"
            ),
            StoragePaths.thumbnails.appendingPathComponent(
                "\(missing.id.uuidString).png"
            )
        ]
        try ImageFileService.writePrivate(
            Data([0]), to: valid.originalURL
        )
        for url in missingRelatedURLs {
            try ImageFileService.writePrivate(Data([1]), to: url)
        }
        defer {
            try? FileManager.default.removeItem(at: valid.originalURL)
            for url in missingRelatedURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let historyURL = directory.appendingPathComponent("history.json")
        try HistoryMetadataPersistence.write(
            [valid, missing], to: historyURL
        )
        let store = HistoryStore(
            storageWorker: HistoryStorageWorker(historyURL: historyURL)
        )

        try await store.prepare()

        XCTAssertEqual(store.items.map(\.id), [valid.id])
        let persisted = try JSONDecoder().decode(
            [CaptureItem].self, from: Data(contentsOf: historyURL)
        )
        XCTAssertEqual(persisted.map(\.id), [valid.id])
        for url in missingRelatedURLs {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: url.path)
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: valid.originalURL.path)
        )
    }

    func testHistorySaveFailureRetainsRecoverableItem() {
        let item = sampleItem()
        let underlying = CocoaError(.fileWriteOutOfSpace)
        let failure = HistorySaveFailure(
            item: item, underlyingError: underlying
        )

        XCTAssertEqual(failure.item, item)
        XCTAssertTrue(
            failure.localizedDescription.contains("kept temporarily"),
            "Save failure should tell the user the image remains recoverable"
        )
    }

    @MainActor
    func testHistoryActivityDatesPersistOnlyAfterSuccessfulOperations() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let historyURL = directory.appendingPathComponent("history.json")
        let item = sampleItem()
        let copiedAt = Date(timeIntervalSince1970: 1_000)
        let savedAt = Date(timeIntervalSince1970: 2_000)
        let store = HistoryStore(
            items: [item],
            storageWorker: HistoryStorageWorker(historyURL: historyURL)
        )

        try await store.recordCopied(itemID: item.id, at: copiedAt)
        try await store.recordSaved(itemIDs: [item.id], at: savedAt)

        XCTAssertEqual(store.items.first?.lastCopiedAt, copiedAt)
        XCTAssertEqual(store.items.first?.lastSavedAt, savedAt)
        let persisted = try JSONDecoder().decode(
            [CaptureItem].self, from: Data(contentsOf: historyURL)
        )
        XCTAssertEqual(persisted.first?.lastCopiedAt, copiedAt)
        XCTAssertEqual(persisted.first?.lastSavedAt, savedAt)
    }

    @MainActor
    func testHistoryMutationFailureRollsBackStateBeforeDeletingFiles() async throws {
        let blockingFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data("not a directory".utf8).write(to: blockingFile)
        defer { try? FileManager.default.removeItem(at: blockingFile) }
        let item = sampleItem()
        try FileManager.default.createDirectory(
            at: StoragePaths.originals, withIntermediateDirectories: true
        )
        try Data([0]).write(to: item.originalURL)
        defer { try? FileManager.default.removeItem(at: item.originalURL) }
        let store = HistoryStore(
            items: [item],
            storageWorker: HistoryStorageWorker(
                historyURL: blockingFile.appendingPathComponent("history.json")
            )
        )

        do {
            try await store.delete(item)
            XCTFail("履歴JSONを保存できない削除は失敗する必要がある")
        } catch {
            XCTAssertTrue(error is HistoryMutationFailure)
        }
        XCTAssertEqual(store.items, [item])
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: item.originalURL.path),
            "メタデータ確定前に画像を削除してはならない"
        )

        do {
            try await store.togglePin(item)
            XCTFail("履歴JSONを保存できないピン留め変更は失敗する必要がある")
        } catch {
            XCTAssertTrue(error is HistoryMutationFailure)
        }
        XCTAssertFalse(store.items[0].isPinned)
    }

    func testHistoryDeletionRemovesEveryRelatedFileIncludingDragCache() throws {
        let id = UUID()
        let originalName = "\(id.uuidString)-original.png"
        let renderedName = "\(id.uuidString)-rendered.png"
        let documentName = "\(id.uuidString).json"
        let thumbnailName = "\(id.uuidString)-thumbnail.png"
        for directory in [
            StoragePaths.originals, StoragePaths.rendered,
            StoragePaths.documents, StoragePaths.thumbnails, StoragePaths.drag
        ] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        }
        let item = CaptureItem(
            id: id, createdAt: Date(), updatedAt: Date(),
            originalFilename: originalName, renderedFilename: renderedName,
            documentFilename: documentName, thumbnailFilename: thumbnailName,
            pixelWidth: 10, pixelHeight: 10, displayID: 1,
            displayName: "Test", scale: 1, selectionRect: .zero,
            isPinned: false, annotationCount: 1
        )
        let dragPNG = StoragePaths.drag.appendingPathComponent(
            "CapMark-\(id.uuidString).png"
        )
        let dragClipboard = StoragePaths.drag.appendingPathComponent(
            "CapMark-\(id.uuidString)-clipboard.png"
        )
        let unrelated = StoragePaths.drag.appendingPathComponent(
            "CapMark-\(UUID().uuidString).png"
        )
        let urls = [
            item.originalURL, item.bestURL, try XCTUnwrap(item.documentURL),
            StoragePaths.thumbnails.appendingPathComponent(thumbnailName),
            dragPNG, dragClipboard
        ]
        for url in urls + [unrelated] {
            try Data([0]).write(to: url)
        }
        defer {
            for url in urls + [unrelated] {
                try? FileManager.default.removeItem(at: url)
            }
        }

        HistoryRelatedFileService.removeFiles(for: item)

        for url in urls {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: url.path),
                "\(url.lastPathComponent)が削除されていない"
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: unrelated.path),
            "別の履歴項目の一時ファイルは削除しない"
        )
    }

    func testTemporaryFileCleanupRemovesOnlyFilesOlderThan24Hours() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 2_000_000)
        let expired = directory.appendingPathComponent("expired.png")
        let recent = directory.appendingPathComponent("recent.png")
        let future = directory.appendingPathComponent("future.png")
        for url in [expired, recent, future] {
            try Data([0]).write(to: url)
        }
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-90_000)],
            ofItemAtPath: expired.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-82_800)],
            ofItemAtPath: recent.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(3_600)],
            ofItemAtPath: future.path
        )

        let removed = try TemporaryFileCleanup.removeExpired(
            in: directory, now: now
        )

        XCTAssertEqual(removed.map(\.lastPathComponent), ["expired.png"])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: expired.path)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: future.path))
    }

    func testLogDiagnosticCodesRejectPathsFilenamesAndLineInjection() {
        XCTAssertEqual(
            LogDiagnosticCode.errorType("Swift.DecodingError").serialized,
            "Swift.DecodingError"
        )
        XCTAssertEqual(LogDiagnosticCode.count(12).serialized, "count:12")
        XCTAssertEqual(LogDiagnosticCode.count(-1).serialized, "count:0")
        for sensitive in [
            "/Users/test/Secret Screenshot.png",
            #"C:\Users\test\Secret.jpg"#,
            "Secret Screenshot.png",
            "CocoaError\n event=captureSucceeded"
        ] {
            XCTAssertEqual(
                LogDiagnosticCode.errorType(sensitive).serialized,
                "[redacted]"
            )
        }
        XCTAssertEqual(
            LogDiagnosticCode.errorType(String(repeating: "A", count: 161))
                .serialized,
            "[redacted]"
        )
    }

    @MainActor
    func testHistoryLimitCleanupPersistsOnceAfterRemovingOldestItem() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let historyURL = directory.appendingPathComponent("history.json")
        let newestID = UUID()
        let oldestID = UUID()
        let newest = CaptureItem(
            id: newestID, createdAt: Date(), updatedAt: Date(),
            originalFilename: "\(newestID.uuidString).png",
            renderedFilename: nil, documentFilename: nil,
            thumbnailFilename: nil, pixelWidth: 10, pixelHeight: 10,
            displayID: 1, displayName: "Test", scale: 1,
            selectionRect: .zero, isPinned: false, annotationCount: 0
        )
        let oldest = CaptureItem(
            id: oldestID, createdAt: .distantPast, updatedAt: .distantPast,
            originalFilename: "\(oldestID.uuidString).png",
            renderedFilename: nil, documentFilename: nil,
            thumbnailFilename: nil, pixelWidth: 10, pixelHeight: 10,
            displayID: 1, displayName: "Test", scale: 1,
            selectionRect: .zero, isPinned: false, annotationCount: 0
        )
        try FileManager.default.createDirectory(
            at: StoragePaths.originals, withIntermediateDirectories: true
        )
        try Data([0]).write(to: oldest.originalURL)
        defer { try? FileManager.default.removeItem(at: oldest.originalURL) }
        let worker = HistoryStorageWorker(historyURL: historyURL)
        let store = HistoryStore(
            items: [newest, oldest], storageWorker: worker
        )

        try await store.enforceLimit(1, preservesPinned: true)

        XCTAssertEqual(store.items.map(\.id), [newestID])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: oldest.originalURL.path)
        )
        let persisted = try JSONDecoder().decode(
            [CaptureItem].self, from: Data(contentsOf: historyURL)
        )
        XCTAssertEqual(persisted.map(\.id), [newestID])
    }

    @MainActor
    func testStartupMaintenanceAppliesRetentionThenHistoryLimit() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        func item(daysOld: Int, pinned: Bool) -> CaptureItem {
            let id = UUID()
            let date = Calendar.current.date(
                byAdding: .day, value: -daysOld, to: now
            )!
            return CaptureItem(
                id: id, createdAt: date, updatedAt: date,
                originalFilename: "\(id.uuidString).png",
                renderedFilename: nil, documentFilename: nil,
                thumbnailFilename: nil, pixelWidth: 10, pixelHeight: 10,
                displayID: 1, displayName: "Test", scale: 1,
                selectionRect: .zero, isPinned: pinned,
                annotationCount: 0
            )
        }
        let newest = item(daysOld: 0, pinned: false)
        let overLimit = item(daysOld: 1, pinned: false)
        let pinnedExpired = item(daysOld: 10, pinned: true)
        let expired = item(daysOld: 10, pinned: false)
        let allItems = [newest, overLimit, pinnedExpired, expired]
        try FileManager.default.createDirectory(
            at: StoragePaths.originals, withIntermediateDirectories: true
        )
        for candidate in allItems {
            try ImageFileService.writePrivate(
                Data([0]), to: candidate.originalURL
            )
        }
        defer {
            for candidate in allItems {
                try? FileManager.default.removeItem(at: candidate.originalURL)
            }
        }
        let historyURL = directory.appendingPathComponent("history.json")
        let store = HistoryStore(
            items: allItems,
            storageWorker: HistoryStorageWorker(historyURL: historyURL)
        )

        try await store.performStartupMaintenance(
            retention: .sevenDays,
            historyEnabled: true,
            limit: 1,
            preservesPinned: true
        )

        XCTAssertEqual(store.items.map(\.id), [newest.id, pinnedExpired.id])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: expired.originalURL.path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: overLimit.originalURL.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: pinnedExpired.originalURL.path)
        )
        let persisted = try JSONDecoder().decode(
            [CaptureItem].self, from: Data(contentsOf: historyURL)
        )
        XCTAssertEqual(persisted.map(\.id), [newest.id, pinnedExpired.id])
    }

    func testEditorCanvasLayoutFitsAndExpandsForFixedZoom() {
        let viewport = CGSize(width: 800, height: 600)
        let image = CGSize(width: 1600, height: 900)
        let fitted = EditorCanvasLayout.make(
            viewport: viewport, imageSize: image, requestedScale: nil
        )
        XCTAssertEqual(fitted.canvasSize, viewport)
        XCTAssertEqual(fitted.scale, 0.47, accuracy: 0.0001)

        let actualSize = EditorCanvasLayout.make(
            viewport: viewport, imageSize: image, requestedScale: 1
        )
        XCTAssertEqual(actualSize.scale, 1)
        XCTAssertEqual(actualSize.canvasSize, CGSize(width: 1640, height: 940))

        let oversizedRequest = EditorCanvasLayout.make(
            viewport: viewport, imageSize: image, requestedScale: 10
        )
        XCTAssertEqual(oversizedRequest.scale, 4)
        XCTAssertEqual(oversizedRequest.canvasSize, CGSize(width: 6440, height: 3640))
    }

    func testImageLoadingServiceReadsMappedDataOffMainPath() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let expected = Data((0..<4_096).map { UInt8($0 % 251) })
        try expected.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let loaded = await ImageLoadingService.readData(from: url)
        XCTAssertEqual(loaded, expected)
    }

    func testCacheCleanupRemovesContentsButKeepsCacheDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let thumbnails = root.appendingPathComponent(
            "thumbnails", isDirectory: true
        )
        let drag = root.appendingPathComponent("drag", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for directory in [thumbnails, drag] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            try Data([0]).write(
                to: directory.appendingPathComponent("cached-file")
            )
        }

        try CacheCleanupService.clear(directories: [thumbnails, drag])

        for directory in [thumbnails, drag] {
            var isDirectory: ObjCBool = false
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: directory.path, isDirectory: &isDirectory
                )
            )
            XCTAssertTrue(isDirectory.boolValue)
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil
                ).count,
                0
            )
        }
    }

    func testDragTemporaryFileLeaseCleansUpBeforeAndAfterGeneration() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let generatedBeforeFinish = directory.appendingPathComponent("before.png")
        let generatedAfterFinish = directory.appendingPathComponent("after.png")
        try Data([0]).write(to: generatedBeforeFinish)
        try Data([0]).write(to: generatedAfterFinish)

        let activeLease = DragTemporaryFileLease()
        activeLease.register(generatedBeforeFinish)
        activeLease.finish()

        let cancelledLease = DragTemporaryFileLease()
        cancelledLease.finish()
        cancelledLease.register(generatedAfterFinish)

        for _ in 0..<100 where
            FileManager.default.fileExists(atPath: generatedBeforeFinish.path)
                || FileManager.default.fileExists(atPath: generatedAfterFinish.path) {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: generatedBeforeFinish.path),
            "通常のドラッグ終了時に生成済み一時ファイルを削除する"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: generatedAfterFinish.path),
            "キャンセル後に遅れて生成された一時ファイルも削除する"
        )
    }

    func testDragMaterializeWritesPrivateFileBeforeProviderHandOff() throws {
        let id = UUID()
        let filename = "\(id.uuidString).png"
        try FileManager.default.createDirectory(
            at: StoragePaths.originals, withIntermediateDirectories: true
        )
        let originalURL = StoragePaths.originals.appendingPathComponent(filename)
        let dragURL = StoragePaths.drag.appendingPathComponent(
            "CapMark-\(id.uuidString).png"
        )
        defer {
            try? FileManager.default.removeItem(at: originalURL)
            try? FileManager.default.removeItem(at: dragURL)
        }

        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.systemGreen.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try bitmap.representation(using: .png, properties: [:])!
            .write(to: originalURL)

        let item = CaptureItem(
            id: id, createdAt: Date(), updatedAt: Date(),
            originalFilename: filename, renderedFilename: nil,
            documentFilename: nil, thumbnailFilename: nil,
            pixelWidth: 4, pixelHeight: 4, displayID: 1, displayName: "Test",
            scale: 1, selectionRect: .zero, isPinned: false, annotationCount: 0
        )
        var settings = AppSettings()
        settings.dragImageFormat = .png
        settings.exportFormat = .png

        let url = try DragExportService.materialize(for: item, settings: settings)
        XCTAssertEqual(url, dragURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let permissions = try FileManager.default.attributesOfItem(
            atPath: url.path
        )[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.uint16Value, 0o600)

        let provider = DragExportService.makeProvider(
            fileURL: url,
            suggestedName: "CapMark-test.png",
            contentType: .png
        )
        XCTAssertTrue(
            provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
            "Terminal 等のパス受け取り先向けに public.file-url を広告する"
        )
        XCTAssertTrue(
            provider.hasItemConformingToTypeIdentifier(UTType.png.identifier),
            "Finder 等の画像受け取り先向けに PNG を広告する"
        )
        XCTAssertEqual(provider.suggestedName, "CapMark-test.png")
    }

    func testShelfGeometryUsesTargetDisplayVisibleFrame() {
        let visible = CGRect(x: -1900, y: 40, width: 1880, height: 1000)
        let size = CGSize(width: 320, height: 240)
        XCTAssertEqual(
            ShelfGeometry.origin(
                panelSize: size, visibleFrame: visible, position: .bottomRight
            ),
            CGPoint(x: -358, y: 58)
        )
        XCTAssertEqual(
            ShelfGeometry.origin(
                panelSize: size, visibleFrame: visible, position: .topLeft
            ),
            CGPoint(x: -1882, y: 782)
        )
    }

    func testTransientItemsAreRemovedWhenShelfIsDisabledAfterImmediateActions() {
        for action in [PostCaptureAction.shelfOnly] {
            XCTAssertTrue(
                TransientLifecyclePolicy.removesAfterPostCapture(
                    action: action, shelfEnabled: false
                )
            )
        }
        for action in [
            PostCaptureAction.autoCopy, .saveDialog, .autoSave, .openAnnotation,
            .copyThenAnnotate, .annotateThenCopy
        ] {
            XCTAssertFalse(
                TransientLifecyclePolicy.removesAfterPostCapture(
                    action: action, shelfEnabled: false
                )
            )
        }
        XCTAssertFalse(
            TransientLifecyclePolicy.removesAfterPostCapture(
                action: .autoCopy, shelfEnabled: true
            )
        )
    }

    func testPreferredLanguageDefaultsToEnglishAndLocalizesTitles() throws {
        let settings = AppSettings()
        XCTAssertEqual(settings.preferredLanguage, .english)

        L10n.language = .english
        XCTAssertEqual(MenuBarMode.always.title, "Always show")
        XCTAssertEqual(AnnotationTool.pen.title, "Pen")
        XCTAssertEqual(L10n.t("History", "履歴"), "History")

        L10n.language = .japanese
        XCTAssertEqual(MenuBarMode.always.title, "常に表示")
        XCTAssertEqual(AnnotationTool.pen.title, "ペン")
        XCTAssertEqual(L10n.t("History", "履歴"), "履歴")
        L10n.language = .english
    }

    func testLegacyJapaneseEnumRawValuesStillDecode() throws {
        let data = #""常に表示""#.data(using: .utf8)!
        let mode = try JSONDecoder().decode(MenuBarMode.self, from: data)
        XCTAssertEqual(mode, .always)

        let toolData = #""矢印""#.data(using: .utf8)!
        let tool = try JSONDecoder().decode(AnnotationTool.self, from: toolData)
        XCTAssertEqual(tool, .arrow)
    }

    func testShortcutCanBeUnconfiguredAndMigratesOldData() throws {
        let unconfigured = ShortcutConfiguration(enabled: false, isConfigured: false)
        XCTAssertEqual(unconfigured.display, "Not set")

        let legacyData = """
        {
          "keyCode": 19,
          "command": true,
          "shift": true,
          "option": false,
          "control": false,
          "enabled": true
        }
        """.data(using: .utf8)!
        let migrated = try JSONDecoder().decode(ShortcutConfiguration.self, from: legacyData)
        XCTAssertTrue(migrated.isConfigured)
        XCTAssertEqual(migrated.display, "⇧⌘2")
    }

    func testFilenameTemplateExpansion() {
        var settings = AppSettings()
        settings.filenameTemplate = "Shot-{width}x{height}-{display}-{uuid}"
        settings.exportFormat = .jpeg
        let item = sampleItem()
        let filename = FileExportService.filename(for: item, settings: settings)
        XCTAssertTrue(filename.hasPrefix("Shot-400x240-Test Display-"))
        XCTAssertTrue(filename.hasSuffix(".jpg"))
    }

    func testFilenameSanitizerPreventsTraversalControlCharactersAndOverflow() {
        XCTAssertEqual(FilenameSanitizer.base(" . . "), "CapMark")
        XCTAssertEqual(
            FilenameSanitizer.base("../Secret\\Shot:\u{0}\n"),
            "-Secret-Shot---"
        )
        let longUnicode = FilenameSanitizer.base(
            String(repeating: "画", count: 100)
        )
        XCTAssertLessThanOrEqual(longUnicode.utf8.count, 200)
        XCTAssertFalse(longUnicode.isEmpty)

        var settings = AppSettings()
        settings.filenameTemplate = "../outside/{display}\n"
        settings.exportFormat = .png
        let unsafeID = UUID()
        let item = CaptureItem(
            id: unsafeID, createdAt: Date(), updatedAt: Date(),
            originalFilename: "\(unsafeID.uuidString).png",
            renderedFilename: nil, documentFilename: nil,
            thumbnailFilename: nil, pixelWidth: 10, pixelHeight: 10,
            displayID: 1, displayName: "Display/../../Secret",
            scale: 1, selectionRect: .zero, isPinned: false,
            annotationCount: 0
        )

        let filename = FileExportService.filename(
            for: item, settings: settings
        )

        XCTAssertEqual(filename, URL(fileURLWithPath: filename).lastPathComponent)
        XCTAssertFalse(filename.hasPrefix("."))
        XCTAssertFalse(filename.contains("/"))
        XCTAssertFalse(filename.contains("\\"))
        XCTAssertFalse(filename.contains("\n"))
        XCTAssertLessThanOrEqual(
            filename.utf8.count,
            200 + ".png".utf8.count
        )
    }

    func testFileCollisionResolverHonorsEveryPolicyAndBatchReservation() {
        let directory = URL(fileURLWithPath: "/tmp/capmark-collision-test")
        let proposed = directory.appendingPathComponent("Shot.png")
        let second = directory.appendingPathComponent("Shot-2.png")
        let third = directory.appendingPathComponent("Shot-3.png")
        let fourth = directory.appendingPathComponent("Shot-4.png")
        let existing = Set([proposed, second])
        let exists: (URL) -> Bool = { existing.contains($0) }

        XCTAssertEqual(
            FileCollisionResolver.resolve(
                proposed, policy: .addCounter,
                occupied: [third], fileExists: exists
            ),
            .use(fourth)
        )
        XCTAssertEqual(
            FileCollisionResolver.resolve(
                proposed, policy: .confirmOverwrite,
                fileExists: exists
            ),
            .confirm(proposed)
        )
        XCTAssertEqual(
            FileCollisionResolver.resolve(
                proposed, policy: .alwaysOverwrite,
                fileExists: exists
            ),
            .use(proposed)
        )
        XCTAssertEqual(
            FileCollisionResolver.resolve(
                proposed, policy: .cancel,
                fileExists: exists
            ),
            .cancel
        )
        XCTAssertEqual(
            FileCollisionResolver.resolve(
                third, policy: .cancel, fileExists: exists
            ),
            .use(third)
        )
        XCTAssertEqual(
            FileCollisionResolver.resolve(
                proposed, policy: .addCounter,
                occupied: [proposed], fileExists: { _ in false }
            ),
            .use(second)
        )
    }

    func testAnnotationDocumentRoundTrip() throws {
        let annotation = Annotation(
            tool: .arrow, points: [.zero, CGPoint(x: 30, y: 40)],
            color: .red, lineWidth: 4
        )
        let document = CaptureDocument(
            cropRect: CGRect(x: 0, y: 0, width: 100, height: 80),
            annotations: [annotation], updatedAt: Date(timeIntervalSince1970: 100)
        )
        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(CaptureDocument.self, from: data)
        XCTAssertEqual(decoded, document)
    }

    func testCorruptAnnotationDocumentNeverFallsBackToUnannotatedImage() throws {
        let id = UUID()
        let originalName = "\(id.uuidString).png"
        let documentName = "\(id.uuidString).json"
        try FileManager.default.createDirectory(
            at: StoragePaths.originals, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: StoragePaths.documents, withIntermediateDirectories: true
        )
        let originalURL = StoragePaths.originals.appendingPathComponent(originalName)
        let documentURL = StoragePaths.documents.appendingPathComponent(documentName)
        try Data([0]).write(to: originalURL)
        try Data("{broken json".utf8).write(to: documentURL)
        defer {
            try? FileManager.default.removeItem(at: originalURL)
            try? FileManager.default.removeItem(at: documentURL)
        }
        let item = CaptureItem(
            id: id, createdAt: Date(), updatedAt: Date(),
            originalFilename: originalName, renderedFilename: nil,
            documentFilename: documentName, thumbnailFilename: nil,
            pixelWidth: 10, pixelHeight: 10, displayID: 1,
            displayName: "Test", scale: 1, selectionRect: .zero,
            isPinned: false, annotationCount: 1
        )

        XCTAssertThrowsError(try AnnotationDocumentService.load(from: documentURL)) {
            XCTAssertTrue($0 is AnnotationDocumentReadError)
            XCTAssertTrue($0.localizedDescription.contains("original image was left unchanged"))
        }
        XCTAssertThrowsError(try ImageRenderer.latestPNG(for: item)) {
            XCTAssertTrue(
                $0 is AnnotationDocumentReadError,
                "破損時に元画像へ黙ってフォールバックしてはならない"
            )
        }
    }

    @MainActor
    func testFailedHistoryDuplicationRollsBackEveryGeneratedFile() async throws {
        let id = UUID()
        let originalName = "\(id.uuidString)-invalid.png"
        let documentName = "\(id.uuidString).json"
        for directory in [
            StoragePaths.originals, StoragePaths.rendered,
            StoragePaths.documents, StoragePaths.thumbnails
        ] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        }
        let originalURL = StoragePaths.originals.appendingPathComponent(originalName)
        let documentURL = StoragePaths.documents.appendingPathComponent(documentName)
        try Data("not an image".utf8).write(to: originalURL)
        let document = CaptureDocument(
            cropRect: CGRect(x: 0, y: 0, width: 10, height: 10),
            annotations: [
                Annotation(
                    tool: .blackout,
                    points: [.zero, CGPoint(x: 5, y: 5)],
                    color: .black, lineWidth: 1
                )
            ],
            updatedAt: Date()
        )
        try JSONEncoder().encode(document).write(to: documentURL)
        defer {
            try? FileManager.default.removeItem(at: originalURL)
            try? FileManager.default.removeItem(at: documentURL)
        }
        let item = CaptureItem(
            id: id, createdAt: Date(), updatedAt: Date(),
            originalFilename: originalName, renderedFilename: nil,
            documentFilename: documentName, thumbnailFilename: nil,
            pixelWidth: 10, pixelHeight: 10, displayID: 1,
            displayName: "Test", scale: 1, selectionRect: .zero,
            isPinned: false, annotationCount: 1
        )
        let directories = [
            StoragePaths.originals, StoragePaths.rendered,
            StoragePaths.documents, StoragePaths.thumbnails
        ]
        func filenames() -> Set<String> {
            Set(directories.flatMap {
                (try? FileManager.default.contentsOfDirectory(
                    at: $0, includingPropertiesForKeys: nil
                ))?.map(\.path) ?? []
            })
        }
        let before = filenames()

        let store = HistoryStore()
        do {
            _ = try await store.duplicate(
                item, limit: 20, preservesPinned: true
            )
            XCTFail("壊れた画像の複製は失敗する必要がある")
        } catch {
            XCTAssertEqual(
                filenames(), before,
                "複製途中で生成したファイルをすべてロールバックする"
            )
        }
    }

    func testTextAlignmentUsesInsertionPointAsAnchor() {
        XCTAssertEqual(
            AnnotationTextLayout.originX(
                anchorX: 100, textWidth: 40, alignment: .left
            ),
            100
        )
        XCTAssertEqual(
            AnnotationTextLayout.originX(
                anchorX: 100, textWidth: 40, alignment: .center
            ),
            80
        )
        XCTAssertEqual(
            AnnotationTextLayout.originX(
                anchorX: 100, textWidth: 40, alignment: .right
            ),
            60
        )
    }

    func testAnnotationSelectionCyclesInBothDirections() {
        XCTAssertNil(
            AnnotationSelectionCycle.index(
                count: 0, current: nil, movesForward: true
            )
        )
        XCTAssertEqual(
            AnnotationSelectionCycle.index(
                count: 3, current: nil, movesForward: true
            ),
            0
        )
        XCTAssertEqual(
            AnnotationSelectionCycle.index(
                count: 3, current: nil, movesForward: false
            ),
            2
        )
        XCTAssertEqual(
            AnnotationSelectionCycle.index(
                count: 3, current: 2, movesForward: true
            ),
            0
        )
        XCTAssertEqual(
            AnnotationSelectionCycle.index(
                count: 3, current: 0, movesForward: false
            ),
            2
        )
    }

    func testAnnotationKeyboardMovementClampsToImageBounds() {
        let imageSize = CGSize(width: 100, height: 80)
        XCTAssertEqual(
            AnnotationMovementGeometry.clampedDelta(
                bounds: CGRect(x: 10, y: 10, width: 20, height: 20),
                imageSize: imageSize,
                requested: CGPoint(x: -15, y: 70)
            ),
            CGPoint(x: -10, y: 50)
        )
        XCTAssertEqual(
            AnnotationMovementGeometry.clampedDelta(
                bounds: CGRect(x: 75, y: 55, width: 20, height: 20),
                imageSize: imageSize,
                requested: CGPoint(x: 10, y: 10)
            ),
            CGPoint(x: 5, y: 5)
        )
    }

    func testSettingsMigrationKeepsExistingValuesAndDefaultsNewOnes() throws {
        let oldJSON = """
        {
          "historyLimit": 50,
          "shelfLimit": 5,
          "hasCompletedSetup": true
        }
        """.data(using: .utf8)!
        let settings = try JSONDecoder().decode(AppSettings.self, from: oldJSON)
        XCTAssertEqual(settings.historyLimit, 50)
        XCTAssertEqual(settings.shelfLimit, 5)
        XCTAssertTrue(settings.hasCompletedSetup)
        XCTAssertEqual(settings.dockMode, .never)
        XCTAssertEqual(settings.exportFormat, .png)
        XCTAssertEqual(settings.shelfAnimation, .fade)
        XCTAssertEqual(settings.dragImageFormat, .png)
        XCTAssertFalse(settings.preserveExportMetadata)
        XCTAssertEqual(settings.editorInitialZoom, .fit)
        XCTAssertTrue(settings.keepOriginalImages)
        XCTAssertTrue(settings.cacheAnnotatedImages)
    }

    func testSettingsStoreWritesAtomicPrivateJSONAndLoadsIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("settings.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: "CapMarkTests.\(UUID().uuidString)")
        )
        let store = SettingsStore(
            url: url, legacyDefaults: defaults,
            legacyKey: "legacy"
        )
        var settings = AppSettings()
        settings.historyLimit = 73
        settings.shelfLimit = 4

        try store.save(settings)

        XCTAssertEqual(store.load(), settings)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        let permissions = try XCTUnwrap(
            attributes[.posixPermissions] as? NSNumber
        ).intValue
        XCTAssertEqual(
            permissions & 0o777, 0o600
        )
    }

    func testCorruptSettingsAreMovedToPrivateRecoveryBeforeDefaultsLoad() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        let corruptData = Data("{broken settings".utf8)
        try corruptData.write(to: url)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: "CapMarkTests.\(UUID().uuidString)")
        )
        let store = SettingsStore(
            url: url, legacyDefaults: defaults,
            legacyKey: "CorruptSettings"
        )

        let loaded = store.load()
        let failure = try XCTUnwrap(store.consumeLoadFailure())
        let recoveryURL = try XCTUnwrap(failure.recoveryURL)

        XCTAssertEqual(loaded, AppSettings())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: recoveryURL), corruptData)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: recoveryURL.path
        )
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600
        )
        XCTAssertNil(store.consumeLoadFailure())

        var replacement = AppSettings()
        replacement.soundEnabled = false
        try store.save(replacement)
        XCTAssertEqual(store.load(), replacement)
        XCTAssertEqual(try Data(contentsOf: recoveryURL), corruptData)
    }

    func testFailedLegacySettingsMigrationKeepsRecoverableDefaults() throws {
        let blockingFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data([0]).write(to: blockingFile)
        defer { try? FileManager.default.removeItem(at: blockingFile) }
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: "CapMarkTests.\(UUID().uuidString)")
        )
        let key = "legacy"
        var settings = AppSettings()
        settings.historyLimit = 91
        defaults.set(try JSONEncoder().encode(settings), forKey: key)
        let store = SettingsStore(
            url: blockingFile.appendingPathComponent("settings.json"),
            legacyDefaults: defaults, legacyKey: key
        )

        XCTAssertEqual(store.load().historyLimit, 91)
        XCTAssertNotNil(
            defaults.data(forKey: key),
            "新しい保存先への移行失敗時は旧設定を削除しない"
        )
    }

    func testPNGExportStripsMetadataByDefaultAndCanPreserveIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.png")
        let image = CGImage(
            width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data([255, 0, 0, 255]) as CFData)!,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
        let destination = CGImageDestinationCreateWithURL(
            sourceURL as CFURL, "public.png" as CFString, 1, nil
        )!
        CGImageDestinationAddImage(
            destination, image,
            [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGTitle: "secret"]] as CFDictionary
        )
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let item = CaptureItem(
            id: UUID(), createdAt: Date(), updatedAt: Date(),
            originalFilename: sourceURL.lastPathComponent, renderedFilename: nil,
            documentFilename: nil, thumbnailFilename: nil,
            pixelWidth: 1, pixelHeight: 1, displayID: 1, displayName: "Test",
            scale: 1, selectionRect: .zero, isPinned: false, annotationCount: 0
        )
        // CaptureItemの保存場所を差し替えられないため、エクスポート検証用に元画像を所定場所へ置く。
        try FileManager.default.createDirectory(at: StoragePaths.originals, withIntermediateDirectories: true)
        let storedURL = item.originalURL
        try? FileManager.default.removeItem(at: storedURL)
        try FileManager.default.copyItem(at: sourceURL, to: storedURL)
        defer { try? FileManager.default.removeItem(at: storedURL) }

        var settings = AppSettings()
        settings.exportFormat = .png
        let strippedURL = directory.appendingPathComponent("stripped.png")
        try Data("replace me".utf8).write(to: strippedURL)
        try FileExportService.export(item, to: strippedURL, settings: settings)
        let strippedSource = CGImageSourceCreateWithURL(strippedURL as CFURL, nil)!
        let stripped = CGImageSourceCopyPropertiesAtIndex(strippedSource, 0, nil) as? [CFString: Any]
        let strippedPNG = stripped?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        XCTAssertNil(strippedPNG?[kCGImagePropertyPNGTitle])

        settings.preserveExportMetadata = true
        let preservedURL = directory.appendingPathComponent("preserved.png")
        try FileExportService.export(item, to: preservedURL, settings: settings)
        let preservedSource = CGImageSourceCreateWithURL(preservedURL as CFURL, nil)!
        let preserved = CGImageSourceCopyPropertiesAtIndex(preservedSource, 0, nil) as? [CFString: Any]
        let preservedPNG = preserved?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        XCTAssertEqual(preservedPNG?[kCGImagePropertyPNGTitle] as? String, "secret")
    }

    func testFailedExportPreservesExistingDestinationFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let originalName = "\(id.uuidString)-corrupt.png"
        try FileManager.default.createDirectory(
            at: StoragePaths.originals, withIntermediateDirectories: true
        )
        let originalURL = StoragePaths.originals.appendingPathComponent(
            originalName
        )
        try Data("corrupt image".utf8).write(to: originalURL)
        defer { try? FileManager.default.removeItem(at: originalURL) }
        let item = CaptureItem(
            id: id, createdAt: Date(), updatedAt: Date(),
            originalFilename: originalName, renderedFilename: nil,
            documentFilename: nil, thumbnailFilename: nil,
            pixelWidth: 10, pixelHeight: 10, displayID: 1,
            displayName: "Test", scale: 1, selectionRect: .zero,
            isPinned: false, annotationCount: 0
        )
        let destination = directory.appendingPathComponent("existing.png")
        let existingData = Data("important existing file".utf8)
        try existingData.write(to: destination)

        XCTAssertThrowsError(
            try FileExportService.export(
                item, to: destination, settings: AppSettings()
            )
        )
        XCTAssertEqual(
            try Data(contentsOf: destination), existingData,
            "出力生成に失敗しても既存ファイルを失わない"
        )
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            ).allSatisfy { !$0.lastPathComponent.hasPrefix(".capmark-") },
            "失敗したステージングファイルを残さない"
        )
    }

    @MainActor
    func testClipboardRepresentationsForImageDataAndFileCopy() async throws {
        let id = UUID()
        let filename = "\(id.uuidString).png"
        try FileManager.default.createDirectory(at: StoragePaths.originals, withIntermediateDirectories: true)
        let originalURL = StoragePaths.originals.appendingPathComponent(filename)
        defer {
            try? FileManager.default.removeItem(at: originalURL)
            NSPasteboard.general.clearContents()
        }
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: originalURL)
        let item = CaptureItem(
            id: id, createdAt: Date(), updatedAt: Date(),
            originalFilename: filename, renderedFilename: nil,
            documentFilename: nil, thumbnailFilename: nil,
            pixelWidth: 2, pixelHeight: 2, displayID: 1, displayName: "Test",
            scale: 1, selectionRect: .zero, isPinned: false, annotationCount: 0
        )

        let copiedImageData = try await ClipboardService.copyImageData(item)
        XCTAssertTrue(copiedImageData)
        XCTAssertNotNil(NSPasteboard.general.data(forType: .png))
        XCTAssertNotNil(NSPasteboard.general.data(forType: .tiff))
        XCTAssertNil(NSPasteboard.general.string(forType: .fileURL))

        let copiedFile = try await ClipboardService.copyFile(item)
        XCTAssertTrue(copiedFile)
        XCTAssertNotNil(NSPasteboard.general.string(forType: .fileURL))

        let copiedAllRepresentations = try await ClipboardService.copy(item)
        XCTAssertTrue(copiedAllRepresentations)
        XCTAssertNotNil(NSPasteboard.general.data(forType: .png))
        XCTAssertNotNil(NSPasteboard.general.data(forType: .tiff))
        XCTAssertNotNil(NSPasteboard.general.string(forType: .fileURL))
    }

    func testRendererProducesCroppedPNG() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: url) }
        let image = NSImage(size: NSSize(width: 100, height: 80))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 100, height: 80).fill()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
        let document = CaptureDocument(
            cropRect: CGRect(x: 10, y: 10, width: 50, height: 40),
            annotations: [Annotation(tool: .blackout, points: [.zero, CGPoint(x: 20, y: 20)], color: .black, lineWidth: 2)],
            updatedAt: Date()
        )
        let data = try ImageRenderer.render(sourceURL: url, document: document)
        let output = NSBitmapImageRep(data: data)
        XCTAssertEqual(output?.pixelsWide, 50)
        XCTAssertEqual(output?.pixelsHigh, 40)
        let redactedPixel = output?.colorAt(x: 5, y: 34)?.usingColorSpace(.deviceRGB)
        XCTAssertLessThan(redactedPixel?.redComponent ?? 1, 0.05)
        XCTAssertLessThan(redactedPixel?.greenComponent ?? 1, 0.05)
        XCTAssertLessThan(redactedPixel?.blueComponent ?? 1, 0.05)
    }

    func testRendererKeepsMarkerTranslucentAndBlackoutOpaque() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: url) }

        let image = NSImage(size: NSSize(width: 100, height: 100))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 100, height: 100).fill()
        image.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: image.tiffRepresentation!))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: url)

        let document = CaptureDocument(
            cropRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            annotations: [
                Annotation(
                    tool: .marker,
                    points: [CGPoint(x: 10, y: 20), CGPoint(x: 90, y: 20)],
                    color: RGBAColor(red: 1, green: 0, blue: 0, alpha: 0.4),
                    lineWidth: 10
                ),
                Annotation(
                    tool: .blackout,
                    points: [CGPoint(x: 10, y: 40), CGPoint(x: 30, y: 60)],
                    color: .black,
                    lineWidth: 1
                )
            ],
            updatedAt: Date()
        )

        let output = try XCTUnwrap(
            NSBitmapImageRep(data: ImageRenderer.render(sourceURL: url, document: document))
        )
        let marker = try XCTUnwrap(
            output.colorAt(x: 50, y: 79)?.usingColorSpace(.deviceRGB)
        )
        XCTAssertGreaterThan(marker.redComponent, 0.9)
        XCTAssertGreaterThan(marker.greenComponent, 0.2)
        XCTAssertLessThan(marker.greenComponent, 0.9)
        XCTAssertGreaterThan(marker.blueComponent, 0.2)
        XCTAssertLessThan(marker.blueComponent, 0.9)

        let blackout = try XCTUnwrap(
            output.colorAt(x: 20, y: 49)?.usingColorSpace(.deviceRGB)
        )
        XCTAssertLessThan(blackout.redComponent, 0.05)
        XCTAssertLessThan(blackout.greenComponent, 0.05)
        XCTAssertLessThan(blackout.blueComponent, 0.05)
    }

    func testExportRendersDocumentWhenAnnotatedImageIsNotCached() throws {
        let id = UUID()
        let originalName = "\(id.uuidString).png"
        let documentName = "\(id.uuidString).json"
        try FileManager.default.createDirectory(at: StoragePaths.originals, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: StoragePaths.documents, withIntermediateDirectories: true)
        let originalURL = StoragePaths.originals.appendingPathComponent(originalName)
        let documentURL = StoragePaths.documents.appendingPathComponent(documentName)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(id.uuidString)-output.png")
        let originalOutputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(id.uuidString)-original-output.png")
        let materializedDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(id.uuidString)-materialized", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: originalURL)
            try? FileManager.default.removeItem(at: documentURL)
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: originalOutputURL)
            try? FileManager.default.removeItem(at: materializedDirectory)
        }

        let image = NSImage(size: NSSize(width: 20, height: 20))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 20, height: 20).fill()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: originalURL)
        let document = CaptureDocument(
            cropRect: CGRect(x: 0, y: 0, width: 20, height: 20),
            annotations: [
                Annotation(
                    tool: .blackout, points: [.zero, CGPoint(x: 10, y: 10)],
                    color: .black, lineWidth: 1
                )
            ],
            updatedAt: Date()
        )
        try JSONEncoder().encode(document).write(to: documentURL)
        let item = CaptureItem(
            id: id, createdAt: Date(), updatedAt: Date(),
            originalFilename: originalName, renderedFilename: nil,
            documentFilename: documentName, thumbnailFilename: nil,
            pixelWidth: 20, pixelHeight: 20, displayID: 1, displayName: "Test",
            scale: 1, selectionRect: .zero, isPinned: false, annotationCount: 1
        )
        var settings = AppSettings()
        settings.exportFormat = .png
        settings.preserveExportMetadata = true
        try FileExportService.export(item, to: outputURL, settings: settings)

        let output = NSBitmapImageRep(data: try Data(contentsOf: outputURL))
        let redactedPixel = output?.colorAt(x: 5, y: 14)?.usingColorSpace(.deviceRGB)
        XCTAssertLessThan(redactedPixel?.redComponent ?? 1, 0.05)
        XCTAssertLessThan(redactedPixel?.greenComponent ?? 1, 0.05)
        XCTAssertLessThan(redactedPixel?.blueComponent ?? 1, 0.05)

        try FileExportService.export(
            item, to: originalOutputURL, settings: settings, useOriginal: true
        )
        let originalOutput = NSBitmapImageRep(data: try Data(contentsOf: originalOutputURL))
        let originalPixel = originalOutput?.colorAt(x: 5, y: 14)?.usingColorSpace(.deviceRGB)
        XCTAssertGreaterThan(originalPixel?.redComponent ?? 0, 0.95)
        XCTAssertGreaterThan(originalPixel?.greenComponent ?? 0, 0.95)
        XCTAssertGreaterThan(originalPixel?.blueComponent ?? 0, 0.95)

        let materializedURL = try ImageMaterializationService.materializeLatestPNG(
            for: item, in: materializedDirectory, suffix: "finder"
        )
        let materialized = try XCTUnwrap(
            NSBitmapImageRep(data: Data(contentsOf: materializedURL))
        )
        let materializedRed = materialized.colorAt(x: 5, y: 14)?
            .usingColorSpace(.deviceRGB)?.redComponent
        XCTAssertLessThan(
            materializedRed ?? 1,
            0.05,
            "合成キャッシュがなくてもFinder用画像には最新の注釈を反映する"
        )

        let clearedDocument = CaptureDocument(
            cropRect: document.cropRect, annotations: [], updatedAt: Date()
        )
        try JSONEncoder().encode(clearedDocument).write(
            to: documentURL, options: .atomic
        )
        let refreshedURL = try ImageMaterializationService.materializeLatestPNG(
            for: item, in: materializedDirectory, suffix: "finder"
        )
        XCTAssertEqual(refreshedURL, materializedURL)
        let refreshed = try XCTUnwrap(
            NSBitmapImageRep(data: Data(contentsOf: refreshedURL))
        )
        let refreshedRed = refreshed.colorAt(x: 5, y: 14)?
            .usingColorSpace(.deviceRGB)?.redComponent
        XCTAssertGreaterThan(
            refreshedRed ?? 0,
            0.95,
            "同じ一時ファイルが残っていても再編集後の最新状態で上書きする"
        )
    }

    func testDiskSpaceErrorPresentationAddsRecoveryGuidance() {
        let error = CocoaError(.fileWriteOutOfSpace)

        XCTAssertTrue(ErrorPresentation.isOutOfDiskSpace(error))
        XCTAssertTrue(
            ErrorPresentation.message(for: error)
                .contains(ErrorPresentation.diskSpaceGuidance)
        )
    }

    func testDiskSpaceErrorPresentationFindsWrappedStorageFailure() {
        let wrapped = HistorySaveFailure(
            item: sampleItem(),
            underlyingError: POSIXError(.ENOSPC)
        )
        let unrelated = CocoaError(.fileReadNoSuchFile)

        XCTAssertTrue(ErrorPresentation.isOutOfDiskSpace(wrapped))
        XCTAssertTrue(
            ErrorPresentation.message(for: wrapped)
                .contains("Free up disk space")
        )
        XCTAssertFalse(ErrorPresentation.isOutOfDiskSpace(unrelated))
        XCTAssertFalse(
            ErrorPresentation.message(for: unrelated)
                .contains(ErrorPresentation.diskSpaceGuidance)
        )
    }

    func testUserCancellationClassificationHandlesWrappedAndTaskCancellation() {
        let wrapped = HistoryMutationFailure(
            operation: "更新",
            underlyingError: CocoaError(.userCancelled)
        )

        XCTAssertTrue(ErrorPresentation.isUserCancellation(wrapped))
        XCTAssertTrue(
            ErrorPresentation.isUserCancellation(CancellationError())
        )
        XCTAssertTrue(
            ErrorPresentation.isUserCancellation(POSIXError(.ECANCELED))
        )
        XCTAssertFalse(
            ErrorPresentation.isUserCancellation(
                CocoaError(.fileWriteUnknown)
            )
        )
    }

    func testPrivateFileWriterAtomicallyReplacesWithPrivatePermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("private.data")
        try Data("old".utf8).write(to: destination)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: destination.path
        )

        try ImageFileService.writePrivate(Data("new".utf8), to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), Data("new".utf8))
        let attributes = try FileManager.default.attributesOfItem(
            atPath: destination.path
        )
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let remainingNames = try FileManager.default.contentsOfDirectory(
            atPath: directory.path
        )
        XCTAssertEqual(remainingNames, ["private.data"])
    }

    @MainActor
    func testAnnotationSaveRestoresEveryFileWhenMetadataCommitFails() async throws {
        let id = UUID()
        let item = CaptureItem(
            id: id, createdAt: Date(), updatedAt: Date(),
            originalFilename: "\(id.uuidString).png",
            renderedFilename: "\(id.uuidString).png",
            documentFilename: "\(id.uuidString).json",
            thumbnailFilename: "\(id.uuidString).png",
            pixelWidth: 20, pixelHeight: 20, displayID: 1,
            displayName: "Test Display", scale: 1,
            selectionRect: CGRect(x: 0, y: 0, width: 20, height: 20),
            isPinned: false, annotationCount: 0
        )
        for directory in [
            StoragePaths.originals, StoragePaths.rendered,
            StoragePaths.documents, StoragePaths.thumbnails
        ] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        }
        let image = NSImage(size: NSSize(width: 20, height: 20))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 20, height: 20).fill()
        image.unlockFocus()
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))
        )
        let originalData = try XCTUnwrap(
            bitmap.representation(using: .png, properties: [:])
        )
        let oldDocumentData = Data("old-document".utf8)
        let oldRenderedData = Data("old-rendered".utf8)
        let oldThumbnailData = Data("old-thumbnail".utf8)
        let documentURL = StoragePaths.documents.appendingPathComponent(
            "\(id.uuidString).json"
        )
        let renderedURL = StoragePaths.rendered.appendingPathComponent(
            "\(id.uuidString).png"
        )
        let thumbnailURL = StoragePaths.thumbnails.appendingPathComponent(
            "\(id.uuidString).png"
        )
        let expected: [URL: Data] = [
            item.originalURL: originalData,
            documentURL: oldDocumentData,
            renderedURL: oldRenderedData,
            thumbnailURL: oldThumbnailData
        ]
        for (url, data) in expected {
            try ImageFileService.writePrivate(data, to: url)
        }
        defer {
            for url in expected.keys {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let blockingFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data("not a directory".utf8).write(to: blockingFile)
        defer { try? FileManager.default.removeItem(at: blockingFile) }
        let store = HistoryStore(
            items: [item],
            storageWorker: HistoryStorageWorker(
                historyURL: blockingFile.appendingPathComponent("history.json")
            )
        )
        let document = CaptureDocument(
            cropRect: CGRect(x: 0, y: 0, width: 10, height: 10),
            annotations: [], updatedAt: Date()
        )

        do {
            _ = try await store.save(
                document: document, for: item,
                keepOriginal: false, cacheRendered: false
            )
            XCTFail("履歴メタデータの確定失敗を返す必要がある")
        } catch {
            XCTAssertTrue(error is HistoryMutationFailure)
        }

        XCTAssertEqual(store.items, [item])
        for (url, data) in expected {
            XCTAssertEqual(
                try Data(contentsOf: url), data,
                "\(url.lastPathComponent)を更新前の内容へ戻す必要がある"
            )
        }
    }

    private func sampleItem() -> CaptureItem {
        CaptureItem(
            id: UUID(), createdAt: Date(), updatedAt: Date(),
            originalFilename: "sample.png", renderedFilename: nil,
            documentFilename: nil, thumbnailFilename: nil,
            pixelWidth: 400, pixelHeight: 240, displayID: 1,
            displayName: "Test Display", scale: 2,
            selectionRect: CGRect(x: 0, y: 0, width: 200, height: 120),
            isPinned: false, annotationCount: 0
        )
    }
}
