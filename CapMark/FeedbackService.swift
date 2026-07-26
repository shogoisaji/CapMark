import AppKit
import UserNotifications

enum FeedbackService {
    static func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    @MainActor
    static func copied(settings: AppSettings) {
        if settings.soundEnabled { NSSound(named: "Tink")?.play() }
        if settings.notificationsEnabled {
            let content = UNMutableNotificationContent()
            content.title = "CapMark"
            content.body = "画像をクリップボードへコピーしました。"
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            )
        }
    }

    @MainActor
    static func copyFailed(settings: AppSettings) {
        if settings.soundEnabled { NSSound.beep() }
    }
}
