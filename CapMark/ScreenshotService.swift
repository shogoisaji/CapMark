import ScreenCaptureKit
import CoreGraphics

struct CapturedRegion {
    let image: CGImage
    let displayID: UInt32
    let displayName: String
    let scale: CGFloat
    let globalRect: CGRect
    let displayLocalRect: CGRect
}

enum DisplayCoordinateMapper {
    static func displayLocalRect(globalRect: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(
            x: globalRect.minX - screenFrame.minX,
            y: globalRect.minY - screenFrame.minY,
            width: globalRect.width,
            height: globalRect.height
        )
    }

    static func screenCaptureSourceRect(globalRect: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(
            x: globalRect.minX - screenFrame.minX,
            y: screenFrame.maxY - globalRect.maxY,
            width: globalRect.width,
            height: globalRect.height
        )
    }
}

enum ScreenshotService {
    @MainActor
    static func capture(screen: NSScreen, rectInScreen: CGRect, includeCursor: Bool) async throws -> CapturedRegion {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw CaptureError.displayUnavailable
        }
        let displayID = number.uint32Value
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayUnavailable
        }
        let ownBundleID = Bundle.main.bundleIdentifier
        let ownApplications = content.applications.filter { $0.bundleIdentifier == ownBundleID }
        let filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = DisplayCoordinateMapper.screenCaptureSourceRect(
            globalRect: rectInScreen, screenFrame: screen.frame
        )
        configuration.width = Int(rectInScreen.width * screen.backingScaleFactor)
        configuration.height = Int(rectInScreen.height * screen.backingScaleFactor)
        configuration.showsCursor = includeCursor
        configuration.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return CapturedRegion(
            image: image, displayID: displayID,
            displayName: screen.localizedName, scale: screen.backingScaleFactor,
            globalRect: rectInScreen,
            displayLocalRect: DisplayCoordinateMapper.displayLocalRect(
                globalRect: rectInScreen, screenFrame: screen.frame
            )
        )
    }
}

enum CaptureError: LocalizedError {
    case displayUnavailable
    case selectionTooSmall
    case busy

    var errorDescription: String? {
        switch self {
        case .displayUnavailable:
            L10n.t("The target display is unavailable.", "対象ディスプレイを利用できません。")
        case .selectionTooSmall:
            L10n.t("The selection is too small.", "選択範囲が小さすぎます。")
        case .busy:
            L10n.t("Another capture is already in progress.", "別の撮影処理を実行中です。")
        }
    }
}
