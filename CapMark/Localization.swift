import Foundation
import SwiftUI

/// Supported UI languages. English is the default regardless of system locale.
enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case japanese = "ja"

    var id: String { rawValue }

    /// Shown in the language picker (native name for each language).
    var displayName: String {
        switch self {
        case .english: "English"
        case .japanese: "日本語"
        }
    }
}

/// Runtime language source of truth for SwiftUI refresh and non-UI strings.
@MainActor
final class LanguageCenter: ObservableObject {
    static let shared = LanguageCenter()

    @Published private(set) var language: AppLanguage = .english

    func apply(_ language: AppLanguage) {
        L10n.language = language
        guard self.language != language else { return }
        self.language = language
    }
}

/// Bilingual string lookup. Default language is English.
enum L10n {
    /// Mirrored from `LanguageCenter` so background error paths can read it.
    nonisolated(unsafe) static var language: AppLanguage = .english

    nonisolated static func t(_ english: String, _ japanese: String) -> String {
        language == .japanese ? japanese : english
    }

    nonisolated static func tf(
        _ english: String, _ japanese: String, _ arguments: CVarArg...
    ) -> String {
        let template = t(english, japanese)
        return String(format: template, locale: locale, arguments: arguments)
    }

    nonisolated static var locale: Locale {
        language == .japanese
            ? Locale(identifier: "ja_JP")
            : Locale(identifier: "en_US_POSIX")
    }
}

/// Rebuilds the view tree when the app language changes so every `L10n.t` call refreshes.
private struct ObservesLanguageModifier: ViewModifier {
    @ObservedObject private var center = LanguageCenter.shared

    func body(content: Content) -> some View {
        content.id(center.language)
    }
}

extension View {
    func observesLanguage() -> some View {
        modifier(ObservesLanguageModifier())
    }
}
