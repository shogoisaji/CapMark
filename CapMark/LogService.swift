import Foundation
import OSLog

enum LogDiagnosticCode: Sendable {
    case errorType(String)
    case count(Int)

    var serialized: String {
        switch self {
        case let .errorType(value):
            return LogSanitizer.errorType(value)
        case let .count(value):
            return "count:\(max(0, value))"
        }
    }
}

enum LogSanitizer {
    static func errorType(_ value: String) -> String {
        guard value.count <= 160,
              !value.contains(where: \.isNewline),
              !value.contains("/"),
              !value.contains("\\") else {
            return "[redacted]"
        }
        let forbiddenExtensions = [
            ".png", ".jpg", ".jpeg", ".tif", ".tiff",
            ".heic", ".gif", ".json", ".pdf"
        ]
        let lowercased = value.lowercased()
        guard !forbiddenExtensions.contains(
            where: lowercased.hasSuffix
        ) else {
            return "[redacted]"
        }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.:<>() ,"
        )
        guard value.unicodeScalars.allSatisfy(allowed.contains),
              !value.isEmpty else {
            return "[redacted]"
        }
        return value
    }
}

actor LogService {
    static let shared = LogService()
    private let logger = Logger(subsystem: "com.capmark.app", category: "lifecycle")
    private let logURL = StoragePaths.root.appendingPathComponent("Logs/capmark.log")

    enum Event: String {
        case appStarted, appStopped
        case shortcutRegistered, shortcutRegistrationFailed
        case permissionGranted, permissionDenied
        case captureSucceeded, captureFailed
        case exportSucceeded, exportFailed
        case historyCleaned, historyLoadFailed, historySaveFailed
        case annotationDataCorrupt
        case settingsLoadFailed, settingsSaveFailed, cacheCleanupFailed
    }

    func record(_ event: Event, code: LogDiagnosticCode? = nil) {
        let safeCode = code?.serialized ?? "-"
        logger.info("event=\(event.rawValue, privacy: .public) code=\(safeCode, privacy: .public)")
        let directory = logURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let line = "\(ISO8601DateFormatter().string(from: Date())) event=\(event.rawValue) code=\(safeCode)\n"
        guard let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: logURL.path) {
            try? ImageFileService.writePrivate(data, to: logURL)
        } else if let handle = try? FileHandle(forWritingTo: logURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        }
        trimIfNeeded()
    }

    func clear() {
        try? FileManager.default.removeItem(at: logURL)
    }

    private func trimIfNeeded() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = attributes[.size] as? Int, size > 1_000_000,
              let data = try? Data(contentsOf: logURL) else { return }
        try? ImageFileService.writePrivate(Data(data.suffix(500_000)), to: logURL)
    }
}
