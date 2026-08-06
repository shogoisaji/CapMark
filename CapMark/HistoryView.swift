import SwiftUI
import AppKit

enum HistoryDisplayMode: String, CaseIterable, Identifiable {
    case grid
    case list
    var id: Self { self }
    var title: String {
        switch self {
        case .grid: L10n.t("Grid", "グリッド")
        case .list: L10n.t("List", "リスト")
        }
    }
}

@MainActor
final class HistoryWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private weak var model: AppModel?

    func show(model: AppModel) {
        self.model = model
        if window == nil {
            let view = HistoryView().environmentObject(model)
            let controller = NSHostingController(rootView: view)
            window = NSWindow(contentViewController: controller)
            window?.title = L10n.t("CapMark History", "CapMark 履歴")
            window?.setContentSize(CGSize(width: 840, height: 580))
            window?.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window?.isReleasedWhenClosed = false
            window?.delegate = self
            window?.setFrameAutosaveName("CapMark.HistoryWindow")
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
        window?.title = L10n.t("CapMark History", "CapMark 履歴")
    }
}

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: Set<UUID> = []
    @State private var confirmBulkDelete = false
    @State private var displayMode = HistoryDisplayMode.grid

    private var isOverLimit: Bool {
        model.settings.historyEnabled
            && HistoryLimitPolicy.exceedsLimit(
                totalCount: model.history.count,
                unpinnedCount: model.history.lazy.filter { !$0.isPinned }.count,
                limit: model.settings.historyLimit,
                pinnedItemsOutsideLimit: model.settings.pinnedItemsOutsideLimit
            )
    }

    var body: some View {
        historyContent
            .observesLanguage()
    }

    private var historyContent: some View {
        VStack(spacing: 0) {
            headerBar
            if !selection.isEmpty {
                selectionBar
            }
            Divider()
            if model.history.isEmpty {
                ContentUnavailableView(
                    L10n.t("No History", "履歴はありません"),
                    systemImage: "photo.on.rectangle.angled",
                    description: Text(
                        L10n.t(
                            "Capture with your shortcut to see items here.",
                            "設定したショートカットから撮影すると、ここに表示されます。"
                        )
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    if displayMode == .grid {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 14)],
                            spacing: 14
                        ) {
                            ForEach(model.history) { item in
                                HistoryCard(item: item, selected: selection.contains(item.id)) {
                                    updateSelection(item)
                                }
                            }
                        }
                        .padding(16)
                    } else {
                        LazyVStack(spacing: 8) {
                            ForEach(model.history) { item in
                                HistoryListRow(
                                    item: item,
                                    selected: selection.contains(item.id)
                                ) {
                                    updateSelection(item)
                                }
                            }
                        }
                        .padding(16)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(minWidth: 640, minHeight: 420, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: model.history.map(\.id)) { _, historyIDs in
            selection.formIntersection(historyIDs)
        }
        .confirmationDialog(
            L10n.tf(
                "Delete %d history items and related files?",
                "%d件の履歴と関連ファイルを削除しますか？",
                selection.count
            ),
            isPresented: $confirmBulkDelete
        ) {
            Button(L10n.t("Delete", "削除"), role: .destructive) {
                model.delete(model.history.filter { selection.contains($0.id) })
                selection.removeAll()
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("History", "履歴"))
                    .font(.title2.bold())
                if isOverLimit {
                    Label(
                        L10n.t("Over limit due to pinned items", "ピン留めにより上限超過"),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Picker(L10n.t("View", "表示"), selection: $displayMode) {
                Label(L10n.t("Grid", "グリッド"), systemImage: "square.grid.2x2")
                    .tag(HistoryDisplayMode.grid)
                Label(L10n.t("List", "リスト"), systemImage: "list.bullet")
                    .tag(HistoryDisplayMode.list)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 104)
            .fixedSize()
            .accessibilityLabel(L10n.t("History display mode", "履歴の表示形式"))

            HStack {
                if !model.history.isEmpty {
                    Button(L10n.t("Select All", "すべて選択")) {
                        selection = Set(model.history.map(\.id))
                    }
                    .keyboardShortcut("a", modifiers: .command)
                    .controlSize(.regular)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var selectionBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.tint)
            Text(L10n.tf("%d selected", "%d件を選択", selection.count))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Button(L10n.t("Save Selected", "一括保存")) {
                model.save(model.history.filter { selection.contains($0.id) })
            }
            .controlSize(.small)

            Button(L10n.t("Delete Selected", "一括削除"), role: .destructive) {
                confirmBulkDelete = true
            }
            .controlSize(.small)

            Button(L10n.t("Clear Selection", "選択解除")) {
                selection.removeAll()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5))
    }

    private func updateSelection(_ item: CaptureItem) {
        if NSEvent.modifierFlags.contains(.command) {
            if selection.contains(item.id) { selection.remove(item.id) }
            else { selection.insert(item.id) }
        } else {
            selection = selection == Set([item.id]) ? [] : Set([item.id])
        }
    }
}

// MARK: - List Row

struct HistoryListRow: View {
    @EnvironmentObject private var model: AppModel
    let item: CaptureItem
    let selected: Bool
    let onSelect: () -> Void
    @State private var showInfo = false

    var body: some View {
        HStack(spacing: 12) {
            thumbnail

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.createdAt.formatted(.dateTime.locale(L10n.locale)))
                        .font(.headline)
                        .lineLimit(1)
                    if item.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityLabel(L10n.t("Pinned", "ピン留め"))
                    }
                }
                Text("\(item.pixelWidth) × \(item.pixelHeight) • \(item.displayName)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(L10n.tf("%d annotations", "%d個の注釈", item.annotationCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            actionButtons
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(selected ? Color.accentColor : .clear, lineWidth: 2)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture(perform: onSelect)
        .accessibilityValue(selected ? L10n.t("Selected", "選択済み") : L10n.t("Not selected", "未選択"))
        .accessibilityAction(named: Text(selected ? L10n.t("Deselect", "選択を解除") : L10n.t("Select", "選択"))) {
            onSelect()
        }
        .contextMenu { historyContextMenu }
        .sheet(isPresented: $showInfo) {
            CaptureInfoView(item: item, isPresented: $showInfo)
        }
    }

    private var thumbnail: some View {
        ZStack(alignment: .topTrailing) {
            AsyncImageView(url: item.thumbnailURL, contentMode: .fill)
                .frame(width: 112, height: 72)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .onDrag { DragExportService.itemProvider(for: item, model: model) }

            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .font(.system(size: 16))
                    .padding(4)
                    .accessibilityHidden(true)
            }
        }
        .fixedSize()
    }

    private var actionButtons: some View {
        HStack(spacing: 2) {
            iconButton("doc.on.doc", help: L10n.t("Copy", "コピー"), label: L10n.t("Copy to Clipboard", "クリップボードへコピー")) {
                model.copy(item)
            }
            iconButton("square.and.arrow.down", help: L10n.t("Save", "保存"), label: L10n.t("Save to File", "ファイルへ保存")) {
                model.save(item)
            }
            iconButton("pencil.and.outline", help: L10n.t("Edit", "編集"), label: L10n.t("Edit Annotations", "注釈を編集")) {
                model.edit(item)
            }
            iconButton("rectangle.stack", help: L10n.t("Show in Temporary Display", "一時表示へ表示"), label: L10n.t("Show in Temporary Display", "一時表示へ表示")) {
                model.sendToShelf(item)
            }
            iconButton("trash", help: L10n.t("Delete", "削除"), label: L10n.t("Delete from History", "履歴を削除"), role: .destructive) {
                model.delete(item)
            }
        }
        .buttonStyle(.borderless)
        .fixedSize()
    }

    private func iconButton(
        _ systemImage: String,
        help: String,
        label: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .help(help)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var historyContextMenu: some View {
        Button(L10n.t("Copy Annotated Image", "注釈済み画像をコピー")) { model.copy(item) }
        Button(L10n.t("Copy Original Image", "元画像をコピー")) { model.copyOriginal(item) }
        Button(L10n.t("Copy as File", "ファイルとしてコピー")) { model.copyFile(item) }
        Button(L10n.t("Copy as Image Data", "画像データとしてコピー")) { model.copyImageData(item) }
        Divider()
        Button(L10n.t("Save…", "保存…")) { model.save(item) }
        Button(L10n.t("Edit Annotations", "注釈を編集")) { model.edit(item) }
        Button(L10n.t("Show in Temporary Display", "一時表示へ表示")) { model.sendToShelf(item) }
        Button(L10n.t("Duplicate", "複製")) { model.duplicate(item) }
        Divider()
        Button(L10n.t("Reveal Annotated Image in Finder", "Finderで注釈済み画像を表示")) { model.reveal(item) }
        Button(L10n.t("Reveal Original in Finder", "Finderで元画像を表示")) { model.reveal(item, rendered: false) }
        Button(L10n.t("Get Info", "情報を見る")) { showInfo = true }
        Button(item.isPinned ? L10n.t("Unpin", "ピン留めを外す") : L10n.t("Pin", "ピン留め")) {
            model.togglePin(item)
        }
        Divider()
        Button(L10n.t("Delete", "削除"), role: .destructive) { model.delete(item) }
    }
}

// MARK: - Grid Card

struct HistoryCard: View {
    @EnvironmentObject private var model: AppModel
    let item: CaptureItem
    let selected: Bool
    let onSelect: () -> Void
    @State private var showInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                AsyncImageView(url: item.thumbnailURL, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: 130)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onDrag { DragExportService.itemProvider(for: item, model: model) }

                HStack(spacing: 4) {
                    if item.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .padding(5)
                            .background(.regularMaterial, in: Circle())
                            .foregroundStyle(.orange)
                            .accessibilityLabel(L10n.t("Pinned", "ピン留め"))
                    }
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .font(.system(size: 18))
                            .accessibilityHidden(true)
                    }
                }
                .padding(6)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(
                        item.createdAt.formatted(
                            .dateTime.year().month().day().locale(L10n.locale)
                        )
                    )
                    Text(
                        item.createdAt.formatted(
                            .dateTime.hour().minute().locale(L10n.locale)
                        )
                    )
                }
                .font(.caption)
                .lineLimit(1)

                Text("\(item.pixelWidth) × \(item.pixelHeight) • \(item.displayName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 2) {
                iconButton("doc.on.doc", help: L10n.t("Copy", "コピー"), label: L10n.t("Copy to Clipboard", "クリップボードへコピー")) {
                    model.copy(item)
                }
                iconButton("square.and.arrow.down", help: L10n.t("Save", "保存"), label: L10n.t("Save to File", "ファイルへ保存")) {
                    model.save(item)
                }
                iconButton("pencil.and.outline", help: L10n.t("Edit", "編集"), label: L10n.t("Edit Annotations", "注釈を編集")) {
                    model.edit(item)
                }
                iconButton(
                    item.isPinned ? "pin.slash" : "pin",
                    help: L10n.t("Pin", "ピン留め"),
                    label: item.isPinned ? L10n.t("Unpin", "ピン留めを外す") : L10n.t("Pin", "ピン留め")
                ) {
                    model.togglePin(item)
                }
                Spacer(minLength: 0)
                iconButton("trash", help: L10n.t("Delete", "削除"), label: L10n.t("Delete from History", "履歴を削除"), role: .destructive) {
                    model.delete(item)
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(selected ? Color.accentColor : .clear, lineWidth: 2)
        }
        .contentShape(RoundedRectangle(cornerRadius: 11))
        .onTapGesture(perform: onSelect)
        .accessibilityValue(selected ? L10n.t("Selected", "選択済み") : L10n.t("Not selected", "未選択"))
        .accessibilityAction(named: Text(selected ? L10n.t("Deselect", "選択を解除") : L10n.t("Select", "選択"))) {
            onSelect()
        }
        .contextMenu { historyContextMenu }
        .sheet(isPresented: $showInfo) {
            CaptureInfoView(item: item, isPresented: $showInfo)
        }
    }

    private func iconButton(
        _ systemImage: String,
        help: String,
        label: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .help(help)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var historyContextMenu: some View {
        Button(L10n.t("Copy Annotated Image", "注釈済み画像をコピー")) { model.copy(item) }
        Button(L10n.t("Copy Original Image", "元画像をコピー")) { model.copyOriginal(item) }
        Button(L10n.t("Copy as File", "ファイルとしてコピー")) { model.copyFile(item) }
        Button(L10n.t("Copy as Image Data", "画像データとしてコピー")) { model.copyImageData(item) }
        Divider()
        Button(L10n.t("Save…", "保存…")) { model.save(item) }
        Button(L10n.t("Edit Annotations", "注釈を編集")) { model.edit(item) }
        Button(L10n.t("Show in Temporary Display", "一時表示へ表示")) { model.sendToShelf(item) }
        Button(L10n.t("Duplicate", "複製")) { model.duplicate(item) }
        Divider()
        Button(L10n.t("Reveal Annotated Image in Finder", "Finderで注釈済み画像を表示")) { model.reveal(item) }
        Button(L10n.t("Reveal Original in Finder", "Finderで元画像を表示")) { model.reveal(item, rendered: false) }
        Button(L10n.t("Get Info", "情報を見る")) { showInfo = true }
        Button(item.isPinned ? L10n.t("Unpin", "ピン留めを外す") : L10n.t("Pin", "ピン留め")) {
            model.togglePin(item)
        }
        Divider()
        Button(L10n.t("Delete", "削除"), role: .destructive) { model.delete(item) }
    }
}

// MARK: - Info Sheet

struct CaptureInfoView: View {
    let item: CaptureItem
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("Capture Info", "撮影情報")).font(.title2.bold())
            LabeledContent(
                L10n.t("Captured", "撮影日時"),
                value: item.createdAt.formatted(.dateTime.locale(L10n.locale))
            )
            LabeledContent(L10n.t("Pixel size", "ピクセルサイズ"), value: "\(item.pixelWidth) × \(item.pixelHeight)")
            LabeledContent(L10n.t("Display", "ディスプレイ"), value: item.displayName)
            LabeledContent(L10n.t("Display ID", "ディスプレイID"), value: "\(item.displayID)")
            LabeledContent(L10n.t("Scale", "スケール"), value: "\(item.scale)x")
            LabeledContent(L10n.t("Selection", "選択範囲"), value: NSStringFromRect(item.selectionRect))
            if let displayLocalRect = item.displayLocalRect {
                LabeledContent(
                    L10n.t("Display-local rect", "ディスプレイ内範囲"),
                    value: NSStringFromRect(displayLocalRect)
                )
            }
            LabeledContent(L10n.t("Annotations", "注釈数"), value: "\(item.annotationCount)")
            LabeledContent(
                L10n.t("Last copy", "最終コピー"),
                value: item.lastCopiedAt?.formatted(.dateTime.locale(L10n.locale))
                    ?? L10n.t("Never", "未実行")
            )
            LabeledContent(
                L10n.t("Last save", "最終保存"),
                value: item.lastSavedAt?.formatted(.dateTime.locale(L10n.locale))
                    ?? L10n.t("Never", "未実行")
            )
            HStack {
                Spacer()
                Button(L10n.t("Close", "閉じる")) { isPresented = false }
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
