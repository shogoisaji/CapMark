import CoreGraphics
import AppKit

enum PermissionService {
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

