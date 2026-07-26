import Foundation
import AppKit

struct HistorySaveFailure: LocalizedError, UnderlyingErrorProviding {
    let item: CaptureItem
    let underlyingError: Error

    var errorDescription: String? {
        "履歴へ保存できませんでした。画像は一時的に保持しています。\n\(underlyingError.localizedDescription)"
    }
}

struct HistoryMutationFailure: LocalizedError, UnderlyingErrorProviding {
    let operation: String
    let underlyingError: Error

    var errorDescription: String? {
        "履歴の\(operation)を保存できませんでした。\n"
            + underlyingError.localizedDescription
    }
}

struct HistoryLoadFailure: LocalizedError, UnderlyingErrorProviding {
    let recoveryURL: URL
    let underlyingError: Error

    var errorDescription: String? {
        "履歴データが破損していたため、安全な場所へ退避しました。\n"
            + recoveryURL.path
    }
}

enum HistoryMetadataPersistence {
    static func write(_ items: [CaptureItem], to url: URL) throws {
        let data = try JSONEncoder().encode(items)
        try ImageFileService.writePrivate(data, to: url)
    }
}

enum HistoryRelatedFileService {
    static func dragURLs(
        for itemID: UUID,
        in directory: URL = StoragePaths.drag
    ) -> [URL] {
        let token = itemID.uuidString
        return (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ))?.filter { $0.lastPathComponent.contains(token) } ?? []
    }

    static func urls(for item: CaptureItem) -> [URL] {
        var urls = [item.originalURL]
        if let filename = item.renderedFilename {
            urls.append(StoragePaths.rendered.appendingPathComponent(filename))
        }
        if let documentURL = item.documentURL { urls.append(documentURL) }
        if let filename = item.thumbnailFilename {
            urls.append(StoragePaths.thumbnails.appendingPathComponent(filename))
        }
        urls.append(contentsOf: dragURLs(for: item.id))
        return Array(Set(urls))
    }

    static func removeFiles(for item: CaptureItem) {
        for url in urls(for: item) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func removeDragFiles(
        for itemID: UUID,
        in directory: URL = StoragePaths.drag
    ) {
        for url in dragURLs(for: itemID, in: directory) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

enum TemporaryFileCleanup {
    static func removeExpired(
        in directory: URL,
        now: Date = Date(),
        maximumAge: TimeInterval = 86_400
    ) throws -> [URL] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )
        let cutoff = now.addingTimeInterval(-maximumAge)
        var removed: [URL] = []
        for url in urls {
            guard let modifiedAt = try url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate,
                  modifiedAt < cutoff else {
                continue
            }
            try FileManager.default.removeItem(at: url)
            removed.append(url)
        }
        return removed
    }
}

actor HistoryStorageWorker {
    private let historyURL: URL

    init(historyURL: URL = StoragePaths.historyFile) {
        self.historyURL = historyURL
    }

    func persist(_ items: [CaptureItem]) throws {
        try HistoryMetadataPersistence.write(items, to: historyURL)
    }

    func load() throws -> [CaptureItem] {
        guard FileManager.default.fileExists(atPath: historyURL.path) else {
            return []
        }
        do {
            let data = try Data(contentsOf: historyURL)
            return try JSONDecoder().decode([CaptureItem].self, from: data)
        } catch {
            let recoveryURL = historyURL.deletingLastPathComponent()
                .appendingPathComponent(
                    "history-recovery-\(UUID().uuidString).json"
                )
            do {
                try FileManager.default.moveItem(
                    at: historyURL, to: recoveryURL
                )
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: recoveryURL.path
                )
            } catch let recoveryError {
                throw HistoryMutationFailure(
                    operation: "破損データ退避",
                    underlyingError: recoveryError
                )
            }
            throw HistoryLoadFailure(
                recoveryURL: recoveryURL, underlyingError: error
            )
        }
    }

    func cleanup(
        _ deletedItems: [CaptureItem],
        remainingItems: [CaptureItem]
    ) throws {
        try HistoryMetadataPersistence.write(
            remainingItems, to: historyURL
        )
        for item in deletedItems {
            HistoryRelatedFileService.removeFiles(for: item)
        }
    }
}

enum HistoryLimitPolicy {
    static func removableCount(
        totalCount: Int, unpinnedCount: Int, limit: Int,
        pinnedItemsOutsideLimit: Bool
    ) -> Int {
        guard limit >= 0 else { return 0 }
        if pinnedItemsOutsideLimit {
            return max(0, unpinnedCount - limit)
        }
        return min(unpinnedCount, max(0, totalCount - limit))
    }

    static func exceedsLimit(
        totalCount: Int, unpinnedCount: Int, limit: Int,
        pinnedItemsOutsideLimit: Bool
    ) -> Bool {
        if pinnedItemsOutsideLimit {
            return unpinnedCount > limit
        }
        return totalCount > limit
    }
}

@MainActor
final class HistoryStore {
    private(set) var items: [CaptureItem] = []
    private let storageWorker: HistoryStorageWorker

    init(
        items: [CaptureItem] = [],
        storageWorker: HistoryStorageWorker = HistoryStorageWorker()
    ) {
        self.items = items
        self.storageWorker = storageWorker
    }

    func prepare() async throws {
        await Task.detached(priority: .utility) {
            for directory in [
                StoragePaths.originals, StoragePaths.rendered,
                StoragePaths.documents, StoragePaths.thumbnails, StoragePaths.drag
            ] {
                try? FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true
                )
            }
            Self.cleanupDragCacheFiles()
        }.value
        let decoded = try await storageWorker.load()
        let availableItems = decoded.filter {
            FileManager.default.fileExists(atPath: $0.originalURL.path)
        }
        let missingItems = decoded.filter { candidate in
            !availableItems.contains { $0.id == candidate.id }
        }
        if !missingItems.isEmpty {
            do {
                try await storageWorker.cleanup(
                    missingItems, remainingItems: availableItems
                )
            } catch {
                throw HistoryMutationFailure(
                    operation: "欠損履歴の整理",
                    underlyingError: error
                )
            }
        }
        items = availableItems
    }

    func enforceRetention(_ retention: RetentionPeriod) async throws {
        guard retention != .unlimited,
              let cutoff = Calendar.current.date(byAdding: .day, value: -retention.rawValue, to: Date()) else { return }
        let expired = items.filter { !$0.isPinned && $0.createdAt < cutoff }
        try await delete(expired)
    }

    func performStartupMaintenance(
        retention: RetentionPeriod,
        historyEnabled: Bool,
        limit: Int,
        preservesPinned: Bool
    ) async throws {
        try await enforceRetention(retention)
        if historyEnabled {
            try await enforceLimit(
                limit, preservesPinned: preservesPinned
            )
        }
    }

    func ensureThumbnails() async {
        for index in items.indices {
            let item = items[index]
            let name = item.thumbnailFilename ?? "\(item.id.uuidString).png"
            let destinationURL = StoragePaths.thumbnails.appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
                continue
            }
            do {
                try await Task.detached(priority: .utility) {
                    try ThumbnailService.generate(
                        sourceURL: item.bestURL,
                        destinationURL: destinationURL
                    )
                }.value
                items[index].thumbnailFilename = name
            } catch {
                continue
            }
        }
        try? await persist()
    }

    func clearDragCache() async {
        await Task.detached(priority: .utility) {
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: StoragePaths.drag, includingPropertiesForKeys: nil
            ) else { return }
            for url in urls { try? FileManager.default.removeItem(at: url) }
        }.value
    }

    func cleanupExpiredDragCache(now: Date = Date()) async {
        await Task.detached(priority: .utility) {
            _ = try? TemporaryFileCleanup.removeExpired(
                in: StoragePaths.drag, now: now
            )
        }.value
    }

    func add(
        image: CGImage, displayID: UInt32, displayName: String, scale: CGFloat,
        rect: CGRect, displayLocalRect: CGRect, limit: Int, preservesPinned: Bool
    ) async throws -> CaptureItem {
        let id = UUID()
        let filename = "\(id.uuidString).png"
        let thumbnailName = "\(id.uuidString).png"
        let url = StoragePaths.originals.appendingPathComponent(filename)
        let thumbnailURL = StoragePaths.thumbnails.appendingPathComponent(thumbnailName)
        try await Task.detached(priority: .userInitiated) {
            try ImageFileService.writePNG(image, to: url)
            try ThumbnailService.generate(sourceURL: url, destinationURL: thumbnailURL)
        }.value
        let item = CaptureItem(
            id: id, createdAt: Date(), updatedAt: Date(), originalFilename: filename,
            renderedFilename: nil, documentFilename: nil, thumbnailFilename: thumbnailName,
            pixelWidth: image.width, pixelHeight: image.height,
            displayID: displayID, displayName: displayName, scale: scale,
            selectionRect: rect, displayLocalRect: displayLocalRect,
            isPinned: false, annotationCount: 0
        )
        if limit > 0 {
            let previousItems = items
            items.insert(item, at: 0)
            let snapshot = items
            do {
                try await storageWorker.persist(snapshot)
            } catch {
                items = previousItems
                throw HistorySaveFailure(item: item, underlyingError: error)
            }
            do {
                try await enforceLimit(
                    limit, preservesPinned: preservesPinned
                )
            } catch {
                items = previousItems
                try? await storageWorker.persist(previousItems)
                throw HistorySaveFailure(item: item, underlyingError: error)
            }
        }
        return item
    }

    func delete(_ item: CaptureItem) async throws {
        try await delete([item])
    }

    func delete(_ deletedItems: [CaptureItem]) async throws {
        guard !deletedItems.isEmpty else { return }
        let previousItems = items
        let deletedIDs = Set(deletedItems.map(\.id))
        items.removeAll { deletedIDs.contains($0.id) }
        let remainingItems = items
        do {
            try await storageWorker.cleanup(
                deletedItems, remainingItems: remainingItems
            )
        } catch {
            items = previousItems
            throw HistoryMutationFailure(
                operation: "削除", underlyingError: error
            )
        }
    }

    func togglePin(_ item: CaptureItem) async throws {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let previousValue = items[index].isPinned
        items[index].isPinned.toggle()
        do {
            try await persist()
        } catch {
            items[index].isPinned = previousValue
            throw HistoryMutationFailure(
                operation: "ピン留め変更", underlyingError: error
            )
        }
    }

    func recordCopied(itemID: UUID, at date: Date = Date()) async throws {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else {
            return
        }
        guard items[index].lastCopiedAt.map({ date > $0 }) ?? true else {
            return
        }
        let previousValue = items[index].lastCopiedAt
        items[index].lastCopiedAt = date
        do {
            try await persist()
        } catch {
            items[index].lastCopiedAt = previousValue
            throw HistoryMutationFailure(
                operation: "コピー日時更新", underlyingError: error
            )
        }
    }

    func recordSaved(itemIDs: Set<UUID>, at date: Date = Date()) async throws {
        guard !itemIDs.isEmpty else { return }
        let previousItems = items
        var changed = false
        for index in items.indices where itemIDs.contains(items[index].id) {
            if items[index].lastSavedAt.map({ date > $0 }) ?? true {
                items[index].lastSavedAt = date
                changed = true
            }
        }
        guard changed else { return }
        do {
            try await persist()
        } catch {
            items = previousItems
            throw HistoryMutationFailure(
                operation: "保存日時更新", underlyingError: error
            )
        }
    }

    func duplicate(_ item: CaptureItem, limit: Int, preservesPinned: Bool) async throws -> CaptureItem {
        let sourceDocument = try item.documentURL.map {
            try AnnotationDocumentService.load(from: $0)
        }
        let id = UUID()
        let originalName = "\(id.uuidString).png"
        let documentName = sourceDocument.map { _ in "\(id.uuidString).json" }
        let renderedName = sourceDocument.map { _ in "\(id.uuidString).png" }
        let thumbnailName = "\(id.uuidString).png"
        let copy = CaptureItem(
            id: id, createdAt: Date(), updatedAt: Date(), originalFilename: originalName,
            renderedFilename: renderedName, documentFilename: documentName,
            thumbnailFilename: thumbnailName,
            pixelWidth: item.pixelWidth, pixelHeight: item.pixelHeight,
            displayID: item.displayID, displayName: item.displayName, scale: item.scale,
            selectionRect: item.selectionRect, displayLocalRect: item.displayLocalRect,
            isPinned: false, annotationCount: sourceDocument?.annotations.count ?? 0
        )
        let documentData = try sourceDocument.map { try JSONEncoder().encode($0) }
        try await Task.detached(priority: .userInitiated) {
            let originalURL = copy.originalURL
            let documentURL = documentName.map {
                StoragePaths.documents.appendingPathComponent($0)
            }
            let renderedURL = renderedName.map {
                StoragePaths.rendered.appendingPathComponent($0)
            }
            let thumbnailURL = StoragePaths.thumbnails.appendingPathComponent(thumbnailName)
            let generatedURLs: [URL] = [
                Optional(originalURL), documentURL, renderedURL, Optional(thumbnailURL)
            ].compactMap { $0 }
            do {
                try ImageFileService.writePrivate(
                    Data(contentsOf: item.originalURL, options: [.mappedIfSafe]),
                    to: originalURL
                )
                if let document = sourceDocument,
                   let documentData, let documentURL, let renderedURL {
                    try ImageFileService.writePrivate(
                        documentData, to: documentURL
                    )
                    let rendered = try ImageRenderer.render(
                        sourceURL: originalURL, document: document
                    )
                    try ImageFileService.writePrivate(
                        rendered, to: renderedURL
                    )
                }
                try ThumbnailService.generate(
                    sourceURL: copy.bestURL, destinationURL: thumbnailURL
                )
            } catch {
                for url in generatedURLs {
                    try? FileManager.default.removeItem(at: url)
                }
                throw error
            }
        }.value
        let previousItems = items
        items.insert(copy, at: 0)
        do {
            try await enforceLimit(
                limit, preservesPinned: preservesPinned
            )
        } catch {
            items = previousItems
            await Task.detached(priority: .utility) {
                HistoryRelatedFileService.removeFiles(for: copy)
            }.value
            throw error
        }
        return copy
    }

    func document(for item: CaptureItem) throws -> CaptureDocument {
        if let url = item.documentURL {
            return try AnnotationDocumentService.load(from: url)
        }
        return CaptureDocument(
            cropRect: CGRect(x: 0, y: 0, width: item.pixelWidth, height: item.pixelHeight),
            annotations: [], updatedAt: Date()
        )
    }

    func save(
        document: CaptureDocument, for item: CaptureItem,
        keepOriginal: Bool, cacheRendered: Bool
    ) async throws -> CaptureItem {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let previousItem = items[index]
        let documentName = "\(item.id.uuidString).json"
        let renderedName = "\(item.id.uuidString).png"
        let documentData = try JSONEncoder().encode(document)
        let sourceURL = item.originalURL
        let thumbnailName = items[index].thumbnailFilename ?? "\(item.id.uuidString).png"
        let documentURL = StoragePaths.documents.appendingPathComponent(documentName)
        let renderedURL = StoragePaths.rendered.appendingPathComponent(renderedName)
        let thumbnailURL = StoragePaths.thumbnails.appendingPathComponent(
            thumbnailName
        )
        let snapshots = try await Task.detached(priority: .userInitiated) {
            let snapshots = try ImageFileService.snapshot(
                [sourceURL, documentURL, renderedURL, thumbnailURL]
            )
            do {
            let renderedData = try ImageRenderer.render(sourceURL: sourceURL, document: document)
            if keepOriginal {
                try ImageFileService.writePrivate(
                    documentData, to: documentURL
                )
                if cacheRendered {
                    try ImageFileService.writePrivate(
                        renderedData, to: renderedURL
                    )
                } else {
                    try? FileManager.default.removeItem(at: renderedURL)
                }
            } else {
                try ImageFileService.writePrivate(
                    renderedData, to: sourceURL
                )
                try? FileManager.default.removeItem(at: documentURL)
                try? FileManager.default.removeItem(at: renderedURL)
            }
            try ThumbnailService.generate(
                data: renderedData,
                destinationURL: thumbnailURL
            )
            } catch {
                try? ImageFileService.restore(snapshots)
                throw error
            }
            return snapshots
        }.value
        items[index].documentFilename = keepOriginal ? documentName : nil
        items[index].renderedFilename = keepOriginal && cacheRendered ? renderedName : nil
        items[index].thumbnailFilename = thumbnailName
        items[index].annotationCount = keepOriginal ? document.annotations.count : 0
        if !keepOriginal, !document.cropRect.isEmpty {
            items[index].pixelWidth = Int(document.cropRect.integral.width)
            items[index].pixelHeight = Int(document.cropRect.integral.height)
        }
        items[index].updatedAt = Date()
        do {
            try await persist()
        } catch {
            items[index] = previousItem
            do {
                try await Task.detached(priority: .utility) {
                    try ImageFileService.restore(snapshots)
                }.value
            } catch let rollbackError {
                throw HistoryMutationFailure(
                    operation: "注釈変更のロールバック",
                    underlyingError: rollbackError
                )
            }
            throw HistoryMutationFailure(
                operation: "注釈変更", underlyingError: error
            )
        }
        return items[index]
    }

    func saveTemporary(document: CaptureDocument, for item: CaptureItem) async throws -> CaptureItem {
        let renderedName = "\(item.id.uuidString)-temporary.png"
        let sourceURL = item.originalURL
        let renderedURL = StoragePaths.rendered.appendingPathComponent(renderedName)
        let thumbnailURL = item.thumbnailURL
        try await Task.detached(priority: .userInitiated) {
            let snapshots = try ImageFileService.snapshot(
                [renderedURL, thumbnailURL]
            )
            do {
                let renderedData = try ImageRenderer.render(
                    sourceURL: sourceURL, document: document
                )
                try ImageFileService.writePrivate(
                    renderedData, to: renderedURL
                )
                try ThumbnailService.generate(
                    data: renderedData, destinationURL: thumbnailURL
                )
            } catch {
                try? ImageFileService.restore(snapshots)
                throw error
            }
        }.value
        var updated = item
        updated.renderedFilename = renderedName
        updated.annotationCount = document.annotations.count
        updated.updatedAt = Date()
        return updated
    }

    func deleteAll() async throws {
        try await delete(items)
    }

    func enforceLimit(
        _ limit: Int, preservesPinned: Bool = true
    ) async throws {
        guard limit >= 0 else { return }
        let unpinnedCount = items.lazy.filter { !$0.isPinned }.count
        let count = HistoryLimitPolicy.removableCount(
            totalCount: items.count,
            unpinnedCount: unpinnedCount,
            limit: limit,
            pinnedItemsOutsideLimit: preservesPinned
        )
        let previousItems = items
        var removed: [CaptureItem] = []
        for _ in 0..<count {
            guard let index = items.lastIndex(where: { !$0.isPinned }) else { break }
            removed.append(items.remove(at: index))
        }
        let remainingItems = items
        do {
            try await storageWorker.cleanup(
                removed, remainingItems: remainingItems
            )
        } catch {
            items = previousItems
            throw HistoryMutationFailure(
                operation: "上限整理", underlyingError: error
            )
        }
    }

    private func persist() async throws {
        let snapshot = items
        try await storageWorker.persist(snapshot)
    }

    nonisolated private static func cleanupDragCacheFiles() {
        _ = try? TemporaryFileCleanup.removeExpired(
            in: StoragePaths.drag
        )
    }
}
