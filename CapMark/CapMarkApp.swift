import SwiftUI
import AppKit

enum InitialAppSurface: Equatable {
    case none
    case setup
    case history
    case settings
}

enum StartupDisplayPolicy {
    static func initialSurface(
        hasCompletedSetup: Bool,
        startupScreen: StartupScreen,
        isLoginItemLaunch: Bool
    ) -> InitialAppSurface {
        if isLoginItemLaunch { return .none }
        if !hasCompletedSetup { return .setup }
        switch startupScreen {
        case .none: return .none
        case .history: return .history
        case .settings: return .settings
        }
    }
}

enum AppLaunchContext {
    static func isLoginItemLaunch(
        event: NSAppleEventDescriptor? = NSAppleEventManager.shared().currentAppleEvent
    ) -> Bool {
        event?.paramDescriptor(
            forKeyword: AEKeyword(keyAELaunchedAsLogInItem)
        ) != nil
    }
}

@main
struct CapMarkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(AppModel.shared)
                .frame(minWidth: 680, minHeight: 480)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var isFinishingTermination = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.start(
            isLoginItemLaunch: AppLaunchContext.isLoginItemLaunch()
        )
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppModel.shared.showHistory()
        return true
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard !isFinishingTermination else { return .terminateNow }
        isFinishingTermination = true
        Task {
            await AppModel.shared.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
