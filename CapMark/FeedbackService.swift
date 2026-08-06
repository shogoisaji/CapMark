import AppKit

enum FeedbackService {
    @MainActor
    static func copied(settings: AppSettings) {
        if settings.soundEnabled { NSSound(named: "Tink")?.play() }
    }

    @MainActor
    static func copyFailed(settings: AppSettings) {
        if settings.soundEnabled { NSSound.beep() }
    }
}
