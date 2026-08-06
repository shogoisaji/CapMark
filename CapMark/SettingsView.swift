import SwiftUI
import ServiceManagement

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private weak var model: AppModel?

    func show(model: AppModel) {
        self.model = model
        if window == nil {
            let controller = NSHostingController(
                rootView: SettingsView().environmentObject(model)
            )
            window = NSWindow(contentViewController: controller)
            window?.title = L10n.t("Settings", "設定")
            window?.setContentSize(CGSize(width: 760, height: 560))
            window?.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window?.titlebarAppearsTransparent = false
            window?.isReleasedWhenClosed = false
            window?.delegate = self
            window?.setFrameAutosaveName("CapMark.SettingsWindow")
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        Task { @MainActor [weak model] in
            await Task.yield()
            model?.applyActivationPolicy(windowIsOpen: false)
        }
    }

    func applyLocalization() {
        window?.title = L10n.t("Settings", "設定")
    }
}

// MARK: - Navigation

private enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case general
    case shortcut
    case capture
    case history
    case annotation
    case privacy

    var id: Self { self }

    var title: String {
        switch self {
        case .general: L10n.t("General", "一般")
        case .shortcut: L10n.t("Shortcut", "ショートカット")
        case .capture: L10n.t("Capture & Temporary Display", "撮影と一時表示")
        case .history: L10n.t("History & Save", "履歴と保存")
        case .annotation: L10n.t("Annotation", "注釈")
        case .privacy: L10n.t("Privacy", "プライバシー")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .shortcut: "command"
        case .capture: "viewfinder"
        case .history: "clock.arrow.circlepath"
        case .annotation: "pencil.tip.crop.circle"
        case .privacy: "hand.raised"
        }
    }
}

// MARK: - Root

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: SettingsPane? = .general
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var showDeleteConfirmation = false
    @State private var showResetConfirmation = false
    @State private var shortcutValidationMessage: String?

    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { model.settings.preferredLanguage },
            set: { model.setLanguage($0) }
        )
    }

    var body: some View {
        Group {
            if !model.settings.hasCompletedSetup {
                SetupView()
            } else {
                settingsShell
            }
        }
        .observesLanguage()
    }

    private var settingsShell: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $selection) { pane in
                Label(pane.title, systemImage: pane.symbol)
                    .tag(pane)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 168, ideal: 188, max: 220)
        } detail: {
            NavigationStack {
                detailContent
                    .formStyle(.grouped)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 680, minHeight: 480)
        .onChange(of: model.settings) { _, _ in model.persistSettings() }
        .confirmationDialog(
            L10n.t("Delete all app data?", "アプリのデータをすべて削除しますか？"),
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.t("Delete All Data", "すべてのデータを削除"), role: .destructive) {
                model.deleteAllData()
            }
            Button(L10n.t("Cancel", "キャンセル"), role: .cancel) {}
        } message: {
            Text(L10n.t("History, cached files, and logs will be deleted. Settings will be kept. This cannot be undone.", "履歴・キャッシュ・ログを削除します。設定は保持されます。この操作は取り消せません。"))
        }
        .confirmationDialog(
            L10n.t("Reset settings to defaults?", "設定を初期状態へ戻しますか？"),
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.t("Reset", "初期化"), role: .destructive) { model.resetSettings() }
            Button(L10n.t("Cancel", "キャンセル"), role: .cancel) {}
        } message: {
            Text(L10n.t("Shortcuts, save destinations, and other preferences return to defaults. History is kept.", "ショートカットや保存先などの設定が既定値に戻ります。履歴データは削除されません。"))
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selection ?? .general {
        case .general:
            generalPane
        case .shortcut:
            shortcutPane
        case .capture:
            capturePane
        case .history:
            historyAndSavePane
        case .annotation:
            annotationPane
        case .privacy:
            privacyPane
        }
    }

    // MARK: - General

    private var generalPane: some View {
        Form {
            Section {
                Toggle(L10n.t("Launch at login", "ログイン時に起動"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, value in
                        model.setLaunchAtLogin(value)
                    }
                settingsPicker(L10n.t("Menu bar icon", "メニューバーアイコン"), selection: $model.settings.menuBarMode) {
                    ForEach(MenuBarMode.allCases) { Text($0.title).tag($0) }
                }
                settingsPicker(L10n.t("Dock icon", "Dockアイコン"), selection: $model.settings.dockMode) {
                    ForEach(DockMode.allCases) { Text($0.title).tag($0) }
                }
                settingsPicker(L10n.t("Open at launch", "起動時に開く画面"), selection: $model.settings.startupScreen) {
                    ForEach(StartupScreen.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text(L10n.t("Launch & Appearance", "起動と表示"))
            } footer: {
                Text(L10n.t("When registered as a login item, CapMark waits in the background after Mac startup.", "ログイン項目として登録すると、Macの起動後にCapMarkがバックグラウンドで待機します。"))
            }


            Section {
                Picker(L10n.t("Language", "言語"), selection: languageBinding) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text(L10n.t("Language", "言語"))
            } footer: {
                Text(L10n.t("The interface language switches immediately. Default is English.", "表示言語はすぐに切り替わります。既定は英語です。"))
            }

            Section {
                Button(L10n.t("Reset Settings", "設定を初期化"), role: .destructive) {
                    showResetConfirmation = true
                }
            } header: {
                Text(L10n.t("Reset", "リセット"))
            } footer: {
                Text(L10n.t("Settings return to their defaults. History is kept.", "設定を初期状態に戻します。履歴は保持されます。"))
            }
        }
        .navigationTitle(L10n.t("General", "一般"))
    }

    // MARK: - Shortcut

    private var shortcutPane: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    ShortcutRecorderView(
                        configuration: $model.settings.shortcut,
                        validationMessage: $shortcutValidationMessage
                    )
                    .frame(height: 40)
                    .frame(maxWidth: 320)

                    if let shortcutValidationMessage {
                        Label(shortcutValidationMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .symbolRenderingMode(.hierarchical)
                    }
                }
                .padding(.vertical, 4)

                if model.shortcutRegistrationFailed {
                    Label(
                        L10n.t("Registration failed. Try a different combination.", "登録に失敗しました。ほかの組み合わせを試してください。"),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .symbolRenderingMode(.hierarchical)
                }
            } header: {
                Text(L10n.t("Global Shortcut", "グローバルショートカット"))
            } footer: {
                Text(L10n.t("Click the field and type a combination with modifier keys. Capture starts only from this shortcut.", "枠をクリックして、修飾キーを含む組み合わせを入力します。撮影開始の入口はこのショートカットだけです。"))
            }

            Section {
                Button(L10n.t("Restore Default (⌘⇧2)", "デフォルト（⌘⇧2）へ戻す")) {
                    model.settings.shortcut = ShortcutConfiguration()
                    shortcutValidationMessage = nil
                }
                .disabled(
                    model.settings.shortcut == ShortcutConfiguration()
                )
            }
        }
        .navigationTitle(L10n.t("Shortcut", "ショートカット"))
    }

    // MARK: - Capture & Temporary Display

    private var capturePane: some View {
        Form {
            Section {
                Toggle(L10n.t("Include mouse cursor", "マウスカーソルを含める"), isOn: $model.settings.includeCursor)
                settingsPicker(L10n.t("Delay after confirm", "確定後の遅延"), selection: $model.settings.selectionDelay) {
                    Text(L10n.t("None", "なし")).tag(0.0)
                    Text(L10n.t("0.5 s", "0.5秒")).tag(0.5)
                    Text(L10n.t("1 s", "1秒")).tag(1.0)
                    Text(L10n.t("2 s", "2秒")).tag(2.0)
                }
            } header: {
                Text(L10n.t("Capture", "撮影"))
            } footer: {
                Text(L10n.t("Delay after confirming the selection before capture. Useful for menus and tooltips.", "確定後の遅延は、範囲を決めてから実際に取り込むまでの待ち時間です。メニューやツールチップを写すときに使います。"))
            }

            Section {
                settingsPicker(L10n.t("Display position", "表示位置"), selection: $model.settings.shelfPosition) {
                    ForEach(ShelfPosition.allCases) { Text($0.title).tag($0) }
                }
                settingsPicker(L10n.t("Auto-close", "自動で閉じる"), selection: $model.settings.shelfDuration) {
                    Text(L10n.t("Never", "閉じない")).tag(0.0)
                    ForEach(temporaryDisplayDurations, id: \.self) { seconds in
                        Text(L10n.tf("%d seconds", "%d秒", Int(seconds))).tag(seconds)
                    }
                }
            } header: {
                Text(L10n.t("Temporary Display", "一時表示"))
            } footer: {
                Text(L10n.t("Shows the latest capture in a screen corner until dismissed. You can drag it into Finder or other apps.", "最新の撮影画像を画面隅に表示し、閉じるまで維持します。Finderやほかのアプリへドラッグできます。"))
            }
        }
        .navigationTitle(L10n.t("Capture & Temporary Display", "撮影と一時表示"))
    }

    private static let temporaryDisplayDurations = [3.0, 5.0, 10.0, 15.0, 30.0, 60.0]

    private var temporaryDisplayDurations: [Double] {
        Self.temporaryDisplayDurations
    }

    // MARK: - History & Save

    private var historyAndSavePane: some View {
        Form {
            Section {
                Toggle(L10n.t("Enable history", "履歴機能を使用"), isOn: $model.settings.historyEnabled)
                settingsPicker(L10n.t("Maximum items", "最大保持件数"), selection: $model.settings.historyLimit) {
                    ForEach([0, 1, 5, 10, 20, 50, 100, 250, 500], id: \.self) {
                        Text(L10n.tf("%d items", "%d件", $0)).tag($0)
                    }
                }
                .disabled(!model.settings.historyEnabled)
                settingsPicker(L10n.t("Retention period", "保存期間"), selection: $model.settings.retentionPeriod) {
                    ForEach(RetentionPeriod.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!model.settings.historyEnabled)
            } header: {
                Text(L10n.t("Retention", "保持"))
            } footer: {
                Text(L10n.t("When over the limit, the oldest unpinned items are removed first.", "上限を超えると、最古のピン留めされていない項目から削除します。"))
            }

            Section {
                settingsPicker(L10n.t("Default format", "デフォルト形式"), selection: $model.settings.exportFormat) {
                    ForEach(ExportFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                if model.settings.exportFormat == .jpeg {
                    percentSlider(
                        L10n.t("JPEG quality", "JPEG品質"),
                        value: $model.settings.jpegQuality,
                        range: 0.1...1,
                        accessibilityLabel: L10n.t("JPEG quality", "JPEG品質")
                    )
                }
            } header: {
                Text(L10n.t("Format", "形式"))
            } footer: {
                Text(L10n.t("Choose the format used when saving an image.", "画像を保存するときの形式を選びます。"))
            }

            Section {
                settingsPicker(L10n.t("Auto-save destination", "自動保存先"), selection: $model.settings.saveDestination) {
                    ForEach(SaveDestination.allCases) { Text($0.title).tag($0) }
                }
                if model.settings.saveDestination == .custom {
                    LabeledContent(L10n.t("Folder", "フォルダ")) {
                        HStack(spacing: 8) {
                            if let name = model.settings.customSaveFolderName {
                                Text(name)
                                    .lineLimit(1)
                            } else {
                                Text(L10n.t("Not selected", "未選択"))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Button(L10n.t("Choose…", "選択…")) {
                                if let folder = SecurityScopedBookmarkService.chooseFolder() {
                                    model.settings.customSaveFolderBookmark = folder.data
                                    model.settings.customSaveFolderName = folder.name
                                }
                            }
                        }
                    }
                }
            } header: {
                Text(L10n.t("Destination", "保存先"))
            }
        }
        .navigationTitle(L10n.t("History & Save", "履歴と保存"))
    }

    // MARK: - Annotation

    private var annotationPane: some View {
        Form {
            Section {
                settingsPicker(L10n.t("Default tool", "デフォルトツール"), selection: $model.settings.defaultAnnotationTool) {
                    ForEach(AnnotationTool.allCases) { Text($0.title).tag($0) }
                }
                RGBAColorPicker(title: L10n.t("Default color", "デフォルト色"), color: $model.settings.defaultAnnotationColor)
                pointSlider(
                    L10n.t("Line width", "線幅"),
                    value: $model.settings.defaultAnnotationLineWidth,
                    range: 1...30,
                    accessibilityLabel: L10n.t("Default line width", "デフォルトの線幅")
                )
                percentSlider(
                    L10n.t("Marker opacity", "マーカー不透明度"),
                    value: $model.settings.defaultMarkerOpacity,
                    range: 0.1...0.9,
                    accessibilityLabel: L10n.t("Default marker opacity", "デフォルトのマーカー不透明度")
                )
            } header: {
                Text(L10n.t("Tools", "ツール"))
            }

            Section {
                settingsPicker(L10n.t("Font", "フォント"), selection: $model.settings.defaultFontName) {
                    ForEach(["Helvetica", "Avenir Next", "Menlo", "Hiragino Sans"], id: \.self) {
                        Text($0).tag($0)
                    }
                }
                pointSlider(
                    L10n.t("Font size", "フォントサイズ"),
                    value: $model.settings.defaultFontSize,
                    range: 12...96,
                    unit: "pt",
                    accessibilityLabel: L10n.t("Default font size", "デフォルトのフォントサイズ")
                )
                settingsPicker(L10n.t("Text alignment", "テキスト揃え"), selection: $model.settings.defaultTextAlignment) {
                    ForEach(AnnotationTextAlignment.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text(L10n.t("Text", "テキスト"))
            }

            Section {
                settingsPicker(L10n.t("After completion", "完了後のアクション"), selection: $model.settings.annotationCompletionAction) {
                    ForEach(AnnotationCompletionAction.allCases) { Text($0.title).tag($0) }
                }
                settingsPicker(L10n.t("Initial zoom", "起動時のズーム"), selection: $model.settings.editorInitialZoom) {
                    ForEach(EditorInitialZoom.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text(L10n.t("Editor", "エディタ"))
            }
        }
        .navigationTitle(L10n.t("Annotation", "注釈"))
    }

    // MARK: - Privacy

    private var privacyPane: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: PermissionService.isGranted
                          ? "checkmark.seal.fill"
                          : "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(PermissionService.isGranted ? .green : .orange)
                        .symbolRenderingMode(.hierarchical)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(PermissionService.isGranted
                              ? L10n.t("Screen recording permission is granted", "画面キャプチャ権限は許可済みです")
                              : L10n.t("Screen recording permission is required", "画面キャプチャ権限が必要です"))
                            .font(.body.weight(.medium))
                        Text(PermissionService.isGranted
                              ? L10n.t("You can capture selected regions.", "選択した範囲の撮影が利用できます。")
                              : L10n.t("Use the button below to request permission. CapMark appears in System Settings; turn it on, then restart CapMark.", "下のボタンで権限を要求すると、システム設定の一覧にCapMarkが現れます。オンにしたらCapMarkを再起動してください。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    if !PermissionService.isGranted {
                        Button(L10n.t("Grant Permission…", "権限を許可する…")) {
                            PermissionService.openSettings()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    } else {
                        Button(L10n.t("System Settings…", "システム設定…")) {
                            PermissionService.openSettings()
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            } header: {
                Text(L10n.t("Permissions", "権限"))
            }

            Section {
                Label {
                    Text(L10n.t("Images are never sent off this Mac", "画像は外部へ送信されません"))
                } icon: {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.secondary)
                }
                Label {
                    Text(L10n.t("Clipboard is not monitored", "クリップボードは監視しません"))
                } icon: {
                    Image(systemName: "eye.slash.fill")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(L10n.t("Privacy", "プライバシー"))
            } footer: {
                Text(L10n.t("Captures, annotations, and history stay only on this Mac.", "撮影・注釈・履歴はすべてこのMac内にのみ保存されます。"))
            }

            Section {
                Button(L10n.t("Delete All Data", "すべてのデータを削除"), role: .destructive) {
                    showDeleteConfirmation = true
                }
            } header: {
                Text(L10n.t("Data Management", "データ管理"))
            } footer: {
                Text(L10n.t("Deletes history, cached files, and logs. Settings are kept.", "履歴・キャッシュ・ログを削除します。設定は保持されます。"))
            }
        }
        .navigationTitle(L10n.t("Privacy", "プライバシー"))
    }

    // MARK: - Controls

    private func settingsPicker<SelectionValue: Hashable, Content: View>(
        _ title: String,
        selection: Binding<SelectionValue>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Picker(title, selection: selection) {
            content()
        }
        .pickerStyle(.menu)
    }

    private func percentSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        accessibilityLabel: String
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: value, in: range)
                    .controlSize(.small)
                    .frame(maxWidth: 200)
                    .accessibilityLabel(accessibilityLabel)
                    .accessibilityValue(L10n.tf("%d percent", "%dパーセント", Int(value.wrappedValue * 100)))
                Text("\(Int(value.wrappedValue * 100))%")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }

    private func pointSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        unit: String = "pt",
        accessibilityLabel: String
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: value, in: range)
                    .controlSize(.small)
                    .frame(maxWidth: 200)
                    .accessibilityLabel(accessibilityLabel)
                    .accessibilityValue(L10n.tf("%d points", "%dポイント", Int(value.wrappedValue)))
                Text("\(Int(value.wrappedValue))\(unit)")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }

}

// MARK: - Color

struct RGBAColorPicker: View {
    let title: String
    @Binding var color: RGBAColor

    var body: some View {
        ColorPicker(title, selection: Binding(
            get: { Color(nsColor: color.nsColor) },
            set: {
                let converted = NSColor($0).usingColorSpace(.deviceRGB) ?? .red
                color = RGBAColor(
                    red: converted.redComponent,
                    green: converted.greenComponent,
                    blue: converted.blueComponent,
                    alpha: converted.alphaComponent
                )
            }
        ), supportsOpacity: true)
    }
}

// MARK: - Setup

struct SetupView: View {
    @EnvironmentObject private var model: AppModel
    @State private var page = 0
    @State private var launchAtLogin = false
    @State private var shortcutMessage: String?

    private let pageCount = 6

    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { model.settings.preferredLanguage },
            set: { model.setLanguage($0) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            pageContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 36)
                .padding(.vertical, 28)
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .observesLanguage()
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "viewfinder.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("Welcome to CapMark", "CapMarkへようこそ"))
                    .font(.title2.weight(.semibold))
                Text(L10n.t("Capture with a shortcut and hand off to the next step.", "ショートカットで切り取り、すぐ次の作業へ渡せます。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            progressDots
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<pageCount, id: \.self) { index in
                Circle()
                    .fill(index == page ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: index == page ? 8 : 6, height: index == page ? 8 : 6)
                    .animation(.easeInOut(duration: 0.15), value: page)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.tf("Setup %d of %d", "セットアップ %d / %d", page + 1, pageCount))
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case 0:
            setupPage(L10n.t("Fully local", "完全にローカル"), symbol: "lock.shield.fill") {
                Text(L10n.t("Captures and annotations stay on this Mac only. Nothing is sent to external servers, and the clipboard is not monitored.", "撮影画像や注釈は、このMacの中だけに保存されます。外部サーバーへの送信やクリップボード監視は行いません。"))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
                Picker(L10n.t("Language", "言語"), selection: languageBinding) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 220)
                .padding(.top, 8)
            }
        case 1:
            setupPage(L10n.t("Screen Recording Permission", "画面キャプチャ権限"), symbol: "rectangle.dashed.badge.record") {
                Text(L10n.t("macOS screen recording permission is required to capture selected regions.", "選択した範囲を撮影するため、macOSの画面キャプチャ権限が必要です。"))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
                HStack(spacing: 12) {
                    Label(
                        PermissionService.isGranted ? L10n.t("Granted", "許可済み") : L10n.t("Not granted", "未許可"),
                        systemImage: PermissionService.isGranted
                            ? "checkmark.circle.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(PermissionService.isGranted ? .green : .orange)
                    .symbolRenderingMode(.hierarchical)
                    if !PermissionService.isGranted {
                        Button(L10n.t("Grant Permission…", "権限を許可する…")) {
                            PermissionService.openSettings()
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button(L10n.t("System Settings…", "システム設定…")) {
                            PermissionService.openSettings()
                        }
                    }
                }
                .padding(.top, 4)
                if !PermissionService.isGranted {
                    Text(L10n.t("The button opens System Settings and adds CapMark to the list. Turn the switch on, then restart CapMark.", "ボタンを押すとシステム設定が開き、一覧にCapMarkが追加されます。スイッチをオンにしたあと、CapMarkを再起動してください。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                        .padding(.top, 4)
                }
            }
        case 2:
            setupPage(L10n.t("Global Shortcut", "グローバルショートカット"), symbol: "command") {
                Text(L10n.t("Click the field and type a combination with modifier keys. Capture starts only from this shortcut.", "枠をクリックして、修飾キーを含む組み合わせを入力してください。撮影はこのショートカットからだけ開始します。"))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
                ShortcutRecorderView(
                    configuration: $model.settings.shortcut,
                    validationMessage: $shortcutMessage
                )
                .frame(width: 280, height: 40)
                if let shortcutMessage {
                    Label(shortcutMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
        case 3:
            setupPage(L10n.t("History & Temporary Display", "履歴と一時表示"), symbol: "clock.arrow.circlepath") {
                Text(L10n.t("Keep captures in history and hand them off from the corner temporary display.", "撮影した画像を履歴に残し、画面隅の一時表示からすぐ渡せます。"))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
                Form {
                    Picker(L10n.t("History limit", "履歴保持件数"), selection: $model.settings.historyLimit) {
                        ForEach([0, 5, 10, 20, 50, 100], id: \.self) { Text(L10n.tf("%d items", "%d件", $0)).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                .formStyle(.grouped)
                .frame(maxWidth: 360)
                Text(L10n.t("Temporary display shows the latest item until you dismiss it.", "一時表示は最新の1件を、閉じるまで表示します。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case 4:
            setupPage(L10n.t("Stay Resident", "常駐方法"), symbol: "menubar.rectangle") {
                Text(L10n.t("Open history and settings from the menu bar while CapMark waits in the background.", "メニューバーから履歴や設定を開き、バックグラウンドで待機できます。"))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
                Form {
                    Picker(L10n.t("Menu bar", "メニューバー"), selection: $model.settings.menuBarMode) {
                        ForEach(MenuBarMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    Toggle(L10n.t("Launch CapMark at login", "ログイン時にCapMarkを起動"), isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, value in
                            model.setLaunchAtLogin(value)
                        }
                }
                .formStyle(.grouped)
                .frame(maxWidth: 360)
            }
        default:
            setupPage(L10n.t("You're Ready", "準備完了"), symbol: "checkmark.circle.fill") {
                Text(L10n.tf("Leave CapMark running in the background and press %@ to select a region.", "CapMarkをバックグラウンドで起動しておき、%@ を押して範囲を選択してください。", model.settings.shortcut.display))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Text(L10n.t("After dragging, press Return to confirm. Press Esc anytime to cancel.", "ドラッグ後、Returnで確定します。Escでいつでもキャンセルできます。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("\(page + 1) / \(pageCount)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            if page > 0 {
                Button(L10n.t("Back", "戻る")) { withAnimation(.easeInOut(duration: 0.15)) { page -= 1 } }
                    .keyboardShortcut(.cancelAction)
            }
            if page < pageCount - 1 {
                Button(L10n.t("Next", "次へ")) { withAnimation(.easeInOut(duration: 0.15)) { page += 1 } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(L10n.t("Finish Setup", "セットアップを完了")) {
                    model.settings.hasCompletedSetup = true
                    model.persistSettings()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
    }

    private func setupPage<Content: View>(
        _ title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 48))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
            Text(title)
                .font(.title2.weight(.semibold))
            content()
        }
    }
}
