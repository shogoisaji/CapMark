import CoreGraphics
import AppKit

enum PermissionService {
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Registers CapMark with TCC and shows the system permission UI when needed.
    /// Call this before opening System Settings so CapMark appears in the list.
    @discardableResult
    @MainActor
    static func request() -> Bool {
        // Menu-bar (LSUIElement) apps need to activate or the system sheet may not appear.
        NSApp.activate(ignoringOtherApps: true)
        return CGRequestScreenCaptureAccess()
    }

    /// Requests access (so CapMark is listed under Screen Recording), then opens
    /// System Settings → Privacy & Security → Screen & System Audio Recording.
    @MainActor
    static func openSettings() {
        if !isGranted {
            _ = request()
        }

        // Prefer the Ventura+ Privacy & Security extension anchor, then the legacy pane.
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
        ]
        for string in candidates {
            guard let url = URL(string: string) else { continue }
            if NSWorkspace.shared.open(url) { return }
        }
    }
}
