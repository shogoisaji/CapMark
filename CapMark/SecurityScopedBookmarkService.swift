import AppKit

enum SecurityScopedBookmarkService {
    @MainActor
    static func chooseFolder() -> (data: Data, name: String)? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "保存先に設定"
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
              ) else { return nil }
        return (data, url.lastPathComponent)
    }

    static func resolve(_ data: Data) throws -> URL {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        if stale { throw CocoaError(.fileReadUnknown) }
        return url
    }
}
