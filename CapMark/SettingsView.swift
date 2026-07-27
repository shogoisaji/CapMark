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
            window?.title = "設定"
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
}

// MARK: - Navigation

private enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case general
    case shortcut
    case capture
    case history
    case export
    case annotation
    case privacy

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "一般"
        case .shortcut: "ショートカット"
        case .capture: "撮影とShelf"
        case .history: "履歴"
        case .export: "保存"
        case .annotation: "注釈"
        case .privacy: "プライバシー"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .shortcut: "command"
        case .capture: "viewfinder"
        case .history: "clock"
        case .export: "square.and.arrow.down"
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

    var body: some View {
        Group {
            if !model.settings.hasCompletedSetup {
                SetupView()
            } else {
                settingsShell
            }
        }
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
            "すべての履歴と関連ファイルを削除しますか？",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("すべて削除", role: .destructive) { model.deleteAllHistory() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("元画像・注釈・サムネイルもまとめて削除されます。この操作は取り消せません。")
        }
        .confirmationDialog(
            "設定を初期状態へ戻しますか？",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("初期化", role: .destructive) { model.resetSettings() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("ショートカットや保存先などの設定が既定値に戻ります。履歴データは削除されません。")
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
            historyPane
        case .export:
            exportPane
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
                Toggle("ログイン時に起動", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, value in
                        model.setLaunchAtLogin(value)
                    }
                settingsPicker("メニューバーアイコン", selection: $model.settings.menuBarMode) {
                    ForEach(MenuBarMode.allCases) { Text($0.rawValue).tag($0) }
                }
                settingsPicker("Dockアイコン", selection: $model.settings.dockMode) {
                    ForEach(DockMode.allCases) { Text($0.rawValue).tag($0) }
                }
                settingsPicker("起動時に開く画面", selection: $model.settings.startupScreen) {
                    ForEach(StartupScreen.allCases) { Text($0.rawValue).tag($0) }
                }
            } header: {
                Text("起動と表示")
            } footer: {
                Text("ログイン項目として登録すると、Macの起動後にCapMarkがバックグラウンドで待機します。")
            }

            Section {
                Toggle("効果音", isOn: $model.settings.soundEnabled)
                Toggle("macOS通知", isOn: $model.settings.notificationsEnabled)
                    .onChange(of: model.settings.notificationsEnabled) { _, enabled in
                        if enabled { FeedbackService.requestNotificationPermission() }
                    }
            } header: {
                Text("フィードバック")
            }

            Section {
                Button {
                    model.showHistory()
                } label: {
                    Label("履歴を開く", systemImage: "clock")
                }
            }

            Section {
                Button("すべての履歴を削除", role: .destructive) {
                    showDeleteConfirmation = true
                }
                Button("設定を初期化", role: .destructive) {
                    showResetConfirmation = true
                }
            } header: {
                Text("リセット")
            } footer: {
                Text("履歴の削除は関連ファイルもまとめて消去します。設定の初期化は履歴を残します。")
            }
        }
        .navigationTitle("一般")
    }

    // MARK: - Shortcut

    private var shortcutPane: some View {
        Form {
            Section {
                LabeledContent("現在のショートカット") {
                    Text(model.settings.shortcut.display)
                        .font(.body.weight(.medium).monospaced())
                        .foregroundStyle(model.settings.shortcut.isConfigured ? .primary : .secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }

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

                Toggle("ショートカットを有効にする", isOn: $model.settings.shortcut.enabled)
                    .disabled(!model.settings.shortcut.isConfigured)

                if model.shortcutRegistrationFailed {
                    Label(
                        "登録に失敗しました。ほかの組み合わせを試してください。",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .symbolRenderingMode(.hierarchical)
                }
            } header: {
                Text("グローバルショートカット")
            } footer: {
                Text("枠をクリックして、修飾キーを含む組み合わせを入力します。撮影開始の入口はこのショートカットだけです。")
            }

            Section {
                Button("デフォルト（⌘⇧2）へ戻す") {
                    model.settings.shortcut = ShortcutConfiguration()
                    shortcutValidationMessage = nil
                }
                .disabled(
                    model.settings.shortcut == ShortcutConfiguration()
                )
                Button("ショートカットを削除", role: .destructive) {
                    model.settings.shortcut.isConfigured = false
                    model.settings.shortcut.enabled = false
                    shortcutValidationMessage = nil
                }
                .disabled(!model.settings.shortcut.isConfigured)
            }
        }
        .navigationTitle("ショートカット")
    }

    // MARK: - Capture & Shelf

    private var capturePane: some View {
        Form {
            Section {
                Toggle("マウスカーソルを含める", isOn: $model.settings.includeCursor)
                settingsPicker("確定後の遅延", selection: $model.settings.selectionDelay) {
                    Text("なし").tag(0.0)
                    Text("0.5秒").tag(0.5)
                    Text("1秒").tag(1.0)
                    Text("2秒").tag(2.0)
                }
            } header: {
                Text("撮影")
            } footer: {
                Text("確定後の遅延は、範囲を決めてから実際に取り込むまでの待ち時間です。メニューやツールチップを写すときに使います。")
            }

            Section {
                percentSlider(
                    "背景暗度",
                    value: $model.settings.overlayDimness,
                    range: 0.2...0.85,
                    accessibilityLabel: "選択範囲外の背景暗度"
                )
                pointSlider(
                    "境界線の太さ",
                    value: $model.settings.selectionBorderWidth,
                    range: 1...6,
                    accessibilityLabel: "選択範囲の境界線幅"
                )
            } header: {
                Text("選択オーバーレイ")
            }

            Section {
                Toggle("Shelfを使用", isOn: $model.settings.shelfEnabled)
                settingsPicker("位置", selection: $model.settings.shelfPosition) {
                    ForEach(ShelfPosition.allCases) { Text($0.rawValue).tag($0) }
                }
                .disabled(!model.settings.shelfEnabled)
                settingsPicker("サムネイルサイズ", selection: $model.settings.shelfThumbnailSize) {
                    ForEach(ShelfThumbnailSize.allCases) { Text($0.rawValue).tag($0) }
                }
                .disabled(!model.settings.shelfEnabled)
                settingsPicker("表示アニメーション", selection: $model.settings.shelfAnimation) {
                    ForEach(ShelfAnimation.allCases) { Text($0.rawValue).tag($0) }
                }
                .disabled(!model.settings.shelfEnabled)
                settingsPicker("ドラッグ時の形式", selection: $model.settings.dragImageFormat) {
                    ForEach(DragImageFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                .disabled(!model.settings.shelfEnabled)
            } header: {
                Text("Shelf")
            } footer: {
                Text("最新の1件だけを画面隅に表示し、閉じるまで維持します。Finderやほかのアプリへそのままドラッグできます。")
            }
        }
        .navigationTitle("撮影とShelf")
    }

    // MARK: - History

    private var historyPane: some View {
        Form {
            Section {
                Toggle("履歴機能を使用", isOn: $model.settings.historyEnabled)
                settingsPicker("最大保持件数", selection: $model.settings.historyLimit) {
                    ForEach([0, 1, 5, 10, 20, 50, 100, 250, 500], id: \.self) {
                        Text("\($0)件").tag($0)
                    }
                }
                .disabled(!model.settings.historyEnabled)
                Stepper(
                    value: $model.settings.historyLimit,
                    in: 0...5000
                ) {
                    Text("カスタム件数: \(model.settings.historyLimit)件")
                }
                .disabled(!model.settings.historyEnabled)
                Toggle("ピン留めを上限対象外にする", isOn: $model.settings.pinnedItemsOutsideLimit)
                    .disabled(!model.settings.historyEnabled)
                settingsPicker("保存期間", selection: $model.settings.retentionPeriod) {
                    ForEach(RetentionPeriod.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!model.settings.historyEnabled)
            } header: {
                Text("保持")
            } footer: {
                Text("上限を超えると、最古のピン留めされていない項目から削除します。")
            }

            Section {
                Toggle("元画像を保持", isOn: $model.settings.keepOriginalImages)
                    .disabled(!model.settings.historyEnabled)
                Toggle("注釈済み画像をキャッシュ", isOn: $model.settings.cacheAnnotatedImages)
                    .disabled(!model.settings.historyEnabled)
                Toggle("アプリ終了時に履歴を削除", isOn: $model.settings.deleteHistoryOnExit)
                    .disabled(!model.settings.historyEnabled)
            } header: {
                Text("データ")
            } footer: {
                Text("元画像を保持すると注釈を後から編集しやすくなります。キャッシュは表示・書き出しを速くしますが、ディスクを使います。")
            }

            Section {
                LabeledContent("現在の履歴", value: "\(model.history.count)件")
                LabeledContent("ディスク使用量", value: model.diskUsageText)
                LabeledContent("保存場所") {
                    Text(StoragePaths.root.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Text("ストレージ")
            }
        }
        .navigationTitle("履歴")
    }

    // MARK: - Export

    private var exportPane: some View {
        Form {
            Section {
                settingsPicker("デフォルト形式", selection: $model.settings.exportFormat) {
                    ForEach(ExportFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                if model.settings.exportFormat == .jpeg {
                    percentSlider(
                        "JPEG品質",
                        value: $model.settings.jpegQuality,
                        range: 0.1...1,
                        accessibilityLabel: "JPEG品質"
                    )
                }
                Toggle("画像メタデータを保持", isOn: $model.settings.preserveExportMetadata)
            } header: {
                Text("形式")
            } footer: {
                Text("既定ではメタデータを除去します。保持をオンにすると撮影時の情報が残る場合があります。")
            }

            Section {
                TextField("ファイル名テンプレート", text: $model.settings.filenameTemplate)
                settingsPicker("同名ファイル", selection: $model.settings.fileCollisionPolicy) {
                    ForEach(FileCollisionPolicy.allCases) { Text($0.rawValue).tag($0) }
                }
            } header: {
                Text("ファイル名")
            } footer: {
                Text("使用可能: {date} {time} {datetime} {width} {height} {display} {uuid}")
            }

            Section {
                settingsPicker("自動保存先", selection: $model.settings.saveDestination) {
                    ForEach(SaveDestination.allCases) { Text($0.rawValue).tag($0) }
                }
                if model.settings.saveDestination == .custom {
                    LabeledContent("フォルダ") {
                        HStack(spacing: 8) {
                            if let name = model.settings.customSaveFolderName {
                                Text(name)
                                    .lineLimit(1)
                            } else {
                                Text("未選択")
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Button("選択…") {
                                if let folder = SecurityScopedBookmarkService.chooseFolder() {
                                    model.settings.customSaveFolderBookmark = folder.data
                                    model.settings.customSaveFolderName = folder.name
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("保存先")
            }
        }
        .navigationTitle("保存")
    }

    // MARK: - Annotation

    private var annotationPane: some View {
        Form {
            Section {
                settingsPicker("デフォルトツール", selection: $model.settings.defaultAnnotationTool) {
                    ForEach(AnnotationTool.allCases) { Text($0.rawValue).tag($0) }
                }
                RGBAColorPicker(title: "デフォルト色", color: $model.settings.defaultAnnotationColor)
                pointSlider(
                    "線幅",
                    value: $model.settings.defaultAnnotationLineWidth,
                    range: 1...30,
                    accessibilityLabel: "デフォルトの線幅"
                )
                percentSlider(
                    "マーカー不透明度",
                    value: $model.settings.defaultMarkerOpacity,
                    range: 0.1...0.9,
                    accessibilityLabel: "デフォルトのマーカー不透明度"
                )
            } header: {
                Text("ツール")
            }

            Section {
                settingsPicker("フォント", selection: $model.settings.defaultFontName) {
                    ForEach(["Helvetica", "Avenir Next", "Menlo", "Hiragino Sans"], id: \.self) {
                        Text($0).tag($0)
                    }
                }
                pointSlider(
                    "フォントサイズ",
                    value: $model.settings.defaultFontSize,
                    range: 12...96,
                    unit: "pt",
                    accessibilityLabel: "デフォルトのフォントサイズ"
                )
                settingsPicker("テキスト揃え", selection: $model.settings.defaultTextAlignment) {
                    ForEach(AnnotationTextAlignment.allCases) { Text($0.rawValue).tag($0) }
                }
            } header: {
                Text("テキスト")
            }

            Section {
                settingsPicker("完了後のアクション", selection: $model.settings.annotationCompletionAction) {
                    ForEach(AnnotationCompletionAction.allCases) { Text($0.rawValue).tag($0) }
                }
                settingsPicker("起動時のズーム", selection: $model.settings.editorInitialZoom) {
                    ForEach(EditorInitialZoom.allCases) { Text($0.rawValue).tag($0) }
                }
            } header: {
                Text("エディタ")
            }
        }
        .navigationTitle("注釈")
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
                              ? "画面キャプチャ権限は許可済みです"
                              : "画面キャプチャ権限が必要です")
                            .font(.body.weight(.medium))
                        Text(PermissionService.isGranted
                              ? "選択した範囲の撮影が利用できます。"
                              : "下のボタンで権限を要求すると、システム設定の一覧にCapMarkが現れます。オンにしたらCapMarkを再起動してください。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    if !PermissionService.isGranted {
                        Button("権限を許可する…") {
                            PermissionService.openSettings()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    } else {
                        Button("システム設定…") {
                            PermissionService.openSettings()
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            } header: {
                Text("権限")
            }

            Section {
                Label {
                    Text("画像は外部へ送信されません")
                } icon: {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.secondary)
                }
                Label {
                    Text("クリップボードは監視しません")
                } icon: {
                    Image(systemName: "eye.slash.fill")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("プライバシー")
            } footer: {
                Text("撮影・注釈・履歴はすべてこのMac内にのみ保存されます。")
            }

            Section {
                Button {
                    model.clearCache()
                } label: {
                    Label("キャッシュを削除", systemImage: "internaldrive")
                }
                Button {
                    model.clearLogs()
                } label: {
                    Label("ログを削除", systemImage: "doc.text")
                }
                Button("履歴をすべて削除", role: .destructive) {
                    showDeleteConfirmation = true
                }
            } header: {
                Text("データ管理")
            } footer: {
                Text("キャッシュ削除はサムネイルや一時ファイルを消去します。履歴削除は元画像と注釈も含みます。")
            }
        }
        .navigationTitle("プライバシー")
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
                    .accessibilityValue("\(Int(value.wrappedValue * 100))パーセント")
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
                    .accessibilityValue("\(Int(value.wrappedValue))ポイント")
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
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "viewfinder.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 2) {
                Text("CapMarkへようこそ")
                    .font(.title2.weight(.semibold))
                Text("ショートカットで切り取り、すぐ次の作業へ渡せます。")
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
        .accessibilityLabel("セットアップ \(page + 1) / \(pageCount)")
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case 0:
            setupPage("完全にローカル", symbol: "lock.shield.fill") {
                Text("撮影画像や注釈は、このMacの中だけに保存されます。外部サーバーへの送信やクリップボード監視は行いません。")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
            }
        case 1:
            setupPage("画面キャプチャ権限", symbol: "rectangle.dashed.badge.record") {
                Text("選択した範囲を撮影するため、macOSの画面キャプチャ権限が必要です。")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
                HStack(spacing: 12) {
                    Label(
                        PermissionService.isGranted ? "許可済み" : "未許可",
                        systemImage: PermissionService.isGranted
                            ? "checkmark.circle.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(PermissionService.isGranted ? .green : .orange)
                    .symbolRenderingMode(.hierarchical)
                    if !PermissionService.isGranted {
                        Button("権限を許可する…") {
                            PermissionService.openSettings()
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button("システム設定…") {
                            PermissionService.openSettings()
                        }
                    }
                }
                .padding(.top, 4)
                if !PermissionService.isGranted {
                    Text("ボタンを押すとシステム設定が開き、一覧にCapMarkが追加されます。スイッチをオンにしたあと、CapMarkを再起動してください。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                        .padding(.top, 4)
                }
            }
        case 2:
            setupPage("グローバルショートカット", symbol: "command") {
                Text("枠をクリックして、修飾キーを含む組み合わせを入力してください。撮影はこのショートカットからだけ開始します。")
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
            setupPage("履歴とShelf", symbol: "clock.arrow.circlepath") {
                Text("撮影した画像を履歴に残し、画面隅のShelfからすぐ渡せます。")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
                Form {
                    Picker("履歴保持件数", selection: $model.settings.historyLimit) {
                        ForEach([0, 5, 10, 20, 50, 100], id: \.self) { Text("\($0)件").tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                .formStyle(.grouped)
                .frame(maxWidth: 360)
                Text("Shelfは最新の1件を、閉じるまで表示します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case 4:
            setupPage("常駐方法", symbol: "menubar.rectangle") {
                Text("メニューバーから履歴や設定を開き、バックグラウンドで待機できます。")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
                Form {
                    Picker("メニューバー", selection: $model.settings.menuBarMode) {
                        ForEach(MenuBarMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    Toggle("ログイン時にCapMarkを起動", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, value in
                            model.setLaunchAtLogin(value)
                        }
                }
                .formStyle(.grouped)
                .frame(maxWidth: 360)
            }
        default:
            setupPage("準備完了", symbol: "checkmark.circle.fill") {
                Text("CapMarkをバックグラウンドで起動しておき、\(model.settings.shortcut.display) を押して範囲を選択してください。")
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Text("ドラッグ後、Returnで確定します。Escでいつでもキャンセルできます。")
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
                Button("戻る") { withAnimation(.easeInOut(duration: 0.15)) { page -= 1 } }
                    .keyboardShortcut(.cancelAction)
            }
            if page < pageCount - 1 {
                Button("次へ") { withAnimation(.easeInOut(duration: 0.15)) { page += 1 } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("セットアップを完了") {
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
