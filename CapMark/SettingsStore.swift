import Foundation

struct SettingsLoadFailure: LocalizedError, UnderlyingErrorProviding {
    let recoveryURL: URL?
    let underlyingError: Error

    var errorDescription: String? {
        if let recoveryURL {
            return "設定データが破損していたため、安全な場所へ退避して既定値で起動しました。\n"
                + recoveryURL.path
        }
        return "設定データを読み込めず、退避にも失敗しました。元の設定ファイルは上書きしません。\n"
            + underlyingError.localizedDescription
    }
}

final class SettingsStore: @unchecked Sendable {
    static let shared = SettingsStore()
    private let url: URL
    private let legacyDefaults: UserDefaults
    private let legacyKey: String
    private let stateLock = NSLock()
    private var pendingLoadFailure: SettingsLoadFailure?
    private var blocksSaving = false

    init(
        url: URL = StoragePaths.settingsFile,
        legacyDefaults: UserDefaults = .standard,
        legacyKey: String = "CapMark.Settings.v1"
    ) {
        self.url = url
        self.legacyDefaults = legacyDefaults
        self.legacyKey = legacyKey
    }

    func load() -> AppSettings {
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                return try JSONDecoder().decode(AppSettings.self, from: data)
            } catch {
                recoverCorruptSettings(underlyingError: error)
                return AppSettings()
            }
        }
        if let data = legacyDefaults.data(forKey: legacyKey),
           let value = try? JSONDecoder().decode(AppSettings.self, from: data) {
            if (try? save(value)) != nil {
                legacyDefaults.removeObject(forKey: legacyKey)
            }
            return value
        }
        return AppSettings()
    }

    func consumeLoadFailure() -> SettingsLoadFailure? {
        stateLock.withLock {
            defer { pendingLoadFailure = nil }
            return pendingLoadFailure
        }
    }

    func save(_ settings: AppSettings) throws {
        let savingIsBlocked = stateLock.withLock { blocksSaving }
        if savingIsBlocked {
            throw SettingsLoadFailure(
                recoveryURL: nil,
                underlyingError: CocoaError(.fileWriteNoPermission)
            )
        }
        let data = try JSONEncoder().encode(settings)
        try ImageFileService.writePrivate(data, to: url)
    }

    private func recoverCorruptSettings(underlyingError: Error) {
        let recoveryURL = url.deletingLastPathComponent()
            .appendingPathComponent(
                "settings-recovery-\(UUID().uuidString).json"
            )
        do {
            try FileManager.default.moveItem(at: url, to: recoveryURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: recoveryURL.path
            )
            stateLock.withLock {
                pendingLoadFailure = SettingsLoadFailure(
                    recoveryURL: recoveryURL,
                    underlyingError: underlyingError
                )
                blocksSaving = false
            }
        } catch {
            stateLock.withLock {
                pendingLoadFailure = SettingsLoadFailure(
                    recoveryURL: nil, underlyingError: error
                )
                blocksSaving = true
            }
        }
    }
}
