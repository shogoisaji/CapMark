import SwiftUI
import AppKit

enum HistoryDisplayMode: String, CaseIterable, Identifiable {
    case grid = "グリッド"
    case list = "リスト"
    var id: Self { self }
}

enum HistorySearch {
    static func matches(_ item: CaptureItem, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let dimensions = [
            "\(item.pixelWidth)x\(item.pixelHeight)",
            "\(item.pixelWidth)×\(item.pixelHeight)",
            "\(item.pixelWidth) × \(item.pixelHeight)"
        ]
        return item.displayName.localizedCaseInsensitiveContains(query)
            || dimensions.contains { $0.localizedCaseInsensitiveContains(query) }
            || item.createdAt.formatted().localizedCaseInsensitiveContains(query)
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
            window?.title = "CapMark 履歴"
            window?.setContentSize(CGSize(width: 840, height: 580))
            window?.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window?.isReleasedWhenClosed = false
            window?.delegate = self
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        Task { @MainActor [weak model] in
            await Task.yield()
            model?.applyActivationPolicy(windowIsOpen: false)
        }
    }
}

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    @State private var selection: Set<UUID> = []
    @State private var confirmBulkDelete = false
    @State private var displayMode = HistoryDisplayMode.grid

    private var filtered: [CaptureItem] {
        model.history.filter { HistorySearch.matches($0, query: search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("履歴").font(.title2.bold())
                if model.settings.historyEnabled,
                   HistoryLimitPolicy.exceedsLimit(
                    totalCount: model.history.count,
                    unpinnedCount: model.history.lazy.filter { !$0.isPinned }.count,
                    limit: model.settings.historyLimit,
                    pinnedItemsOutsideLimit: model.settings.pinnedItemsOutsideLimit
                   ) {
                    Label("ピン留めにより上限超過", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                if !selection.isEmpty {
                    Text("\(selection.count)件を選択").foregroundStyle(.secondary)
                    Button("一括保存") {
                        model.save(model.history.filter { selection.contains($0.id) })
                    }
                    Button("一括削除", role: .destructive) { confirmBulkDelete = true }
                    Button("選択解除") { selection.removeAll() }
                }
                Spacer()
                if !filtered.isEmpty {
                    Button("すべて選択") {
                        selection = Set(filtered.map(\.id))
                    }
                    .keyboardShortcut("a", modifiers: .command)
                }
                TextField("検索", text: $search).textFieldStyle(.roundedBorder).frame(width: 220)
                Picker("表示", selection: $displayMode) {
                    Label("グリッド", systemImage: "square.grid.2x2")
                        .tag(HistoryDisplayMode.grid)
                    Label("リスト", systemImage: "list.bullet")
                        .tag(HistoryDisplayMode.list)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 92)
                .accessibilityLabel("履歴の表示形式")
            }.padding()
            Divider()
            if filtered.isEmpty {
                ContentUnavailableView("履歴はありません", systemImage: "photo.on.rectangle.angled",
                                       description: Text("設定したショートカットから撮影すると、ここに表示されます。"))
            } else {
                ScrollView {
                    if displayMode == .grid {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 14)], spacing: 14) {
                            ForEach(filtered) { item in
                                HistoryCard(item: item, selected: selection.contains(item.id)) {
                                    updateSelection(item)
                                }
                            }
                        }.padding()
                    } else {
                        LazyVStack(spacing: 8) {
                            ForEach(filtered) { item in
                                HistoryListRow(
                                    item: item, selected: selection.contains(item.id)
                                ) {
                                    updateSelection(item)
                                }
                            }
                        }.padding()
                    }
                }
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .confirmationDialog("\(selection.count)件の履歴と関連ファイルを削除しますか？",
                            isPresented: $confirmBulkDelete) {
            Button("削除", role: .destructive) {
                model.delete(model.history.filter { selection.contains($0.id) })
                selection.removeAll()
            }
        }
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

struct HistoryListRow: View {
    @EnvironmentObject private var model: AppModel
    let item: CaptureItem
    let selected: Bool
    let onSelect: () -> Void
    @State private var showInfo = false

    var body: some View {
        HStack(spacing: 12) {
            AsyncImageView(url: item.thumbnailURL)
                .frame(width: 112, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .onDrag { DragExportService.itemProvider(for: item, model: model) }
            VStack(alignment: .leading, spacing: 5) {
                Text(item.createdAt.formatted()).font(.headline)
                Text("\(item.pixelWidth) × \(item.pixelHeight) • \(item.displayName)")
                    .foregroundStyle(.secondary)
                Text("\(item.annotationCount)個の注釈")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if item.isPinned {
                Label("ピン留め", systemImage: "pin.fill")
                    .labelStyle(.iconOnly).foregroundStyle(.orange)
            }
            if selected {
                Label("選択済み", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button { model.copy(item) } label: { Image(systemName: "doc.on.doc") }
                .help("コピー").accessibilityLabel("クリップボードへコピー")
            Button { model.save(item) } label: { Image(systemName: "square.and.arrow.down") }
                .help("保存").accessibilityLabel("ファイルへ保存")
            Button { model.edit(item) } label: { Image(systemName: "pencil.and.outline") }
                .help("編集").accessibilityLabel("注釈を編集")
            Button { model.sendToShelf(item) } label: { Image(systemName: "rectangle.stack") }
                .help("Shelfへ表示").accessibilityLabel("Shelfへ表示")
            Button(role: .destructive) { model.delete(item) } label: { Image(systemName: "trash") }
                .help("削除").accessibilityLabel("履歴を削除")
        }
        .buttonStyle(.borderless)
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(selected ? Color.accentColor : .clear, lineWidth: 3)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture(perform: onSelect)
        .accessibilityValue(selected ? "選択済み" : "未選択")
        .accessibilityAction(named: selected ? "選択を解除" : "選択") {
            onSelect()
        }
        .contextMenu {
            Button("注釈済み画像をコピー") { model.copy(item) }
            Button("元画像をコピー") { model.copyOriginal(item) }
            Button("ファイルとしてコピー") { model.copyFile(item) }
            Button("画像データとしてコピー") { model.copyImageData(item) }
            Divider()
            Button("保存…") { model.save(item) }
            Button("注釈を編集") { model.edit(item) }
            Button("Shelfへ表示") { model.sendToShelf(item) }
            Button("複製") { model.duplicate(item) }
            Divider()
            Button("Finderで注釈済み画像を表示") { model.reveal(item) }
            Button("Finderで元画像を表示") { model.reveal(item, rendered: false) }
            Button("情報を見る") { showInfo = true }
            Button(item.isPinned ? "ピン留めを外す" : "ピン留め") {
                model.togglePin(item)
            }
            Divider()
            Button("削除", role: .destructive) { model.delete(item) }
        }
        .sheet(isPresented: $showInfo) {
            CaptureInfoView(item: item, isPresented: $showInfo)
        }
    }
}

struct HistoryCard: View {
    @EnvironmentObject private var model: AppModel
    let item: CaptureItem
    let selected: Bool
    let onSelect: () -> Void
    @State private var showInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncImageView(url: item.thumbnailURL)
                .frame(height: 125)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onDrag { DragExportService.itemProvider(for: item, model: model) }
            HStack {
                Text(item.createdAt, style: .date)
                Text(item.createdAt, style: .time)
                Spacer()
                if item.isPinned { Image(systemName: "pin.fill").foregroundStyle(.orange) }
                if selected {
                    Label("選択済み", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }.font(.caption)
            Text("\(item.pixelWidth) × \(item.pixelHeight) • \(item.displayName)")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            HStack {
                Button { model.copy(item) } label: { Image(systemName: "doc.on.doc") }
                    .help("コピー").accessibilityLabel("クリップボードへコピー")
                Button { model.save(item) } label: { Image(systemName: "square.and.arrow.down") }
                    .help("保存").accessibilityLabel("ファイルへ保存")
                Button { model.edit(item) } label: { Image(systemName: "pencil.and.outline") }
                    .help("編集").accessibilityLabel("注釈を編集")
                Button { model.togglePin(item) } label: { Image(systemName: item.isPinned ? "pin.slash" : "pin") }
                    .help("ピン留め").accessibilityLabel(item.isPinned ? "ピン留めを外す" : "ピン留め")
                Spacer()
                Button(role: .destructive) { model.delete(item) } label: { Image(systemName: "trash") }
                    .help("削除").accessibilityLabel("履歴を削除")
            }.buttonStyle(.borderless)
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(selected ? Color.accentColor : .clear, lineWidth: 3)
        }
        .contentShape(RoundedRectangle(cornerRadius: 11))
        .onTapGesture(perform: onSelect)
        .accessibilityValue(selected ? "選択済み" : "未選択")
        .accessibilityAction(named: selected ? "選択を解除" : "選択") {
            onSelect()
        }
        .contextMenu {
            Button("注釈済み画像をコピー") { model.copy(item) }
            Button("元画像をコピー") { model.copyOriginal(item) }
            Button("ファイルとしてコピー") { model.copyFile(item) }
            Button("画像データとしてコピー") { model.copyImageData(item) }
            Divider()
            Button("保存…") { model.save(item) }
            Button("注釈を編集") { model.edit(item) }
            Button("Shelfへ表示") { model.sendToShelf(item) }
            Button("複製") { model.duplicate(item) }
            Divider()
            Button("Finderで注釈済み画像を表示") { model.reveal(item) }
            Button("Finderで元画像を表示") { model.reveal(item, rendered: false) }
            Button("情報を見る") { showInfo = true }
            Button(item.isPinned ? "ピン留めを外す" : "ピン留め") { model.togglePin(item) }
            Divider()
            Button("削除", role: .destructive) { model.delete(item) }
        }
        .sheet(isPresented: $showInfo) {
            CaptureInfoView(item: item, isPresented: $showInfo)
        }
    }
}

struct CaptureInfoView: View {
    let item: CaptureItem
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("撮影情報").font(.title2.bold())
            LabeledContent("撮影日時", value: item.createdAt.formatted())
            LabeledContent("ピクセルサイズ", value: "\(item.pixelWidth) × \(item.pixelHeight)")
            LabeledContent("ディスプレイ", value: item.displayName)
            LabeledContent("ディスプレイID", value: "\(item.displayID)")
            LabeledContent("スケール", value: "\(item.scale)x")
            LabeledContent("選択範囲", value: NSStringFromRect(item.selectionRect))
            if let displayLocalRect = item.displayLocalRect {
                LabeledContent(
                    "ディスプレイ内範囲",
                    value: NSStringFromRect(displayLocalRect)
                )
            }
            LabeledContent("注釈数", value: "\(item.annotationCount)")
            LabeledContent(
                "最終コピー",
                value: item.lastCopiedAt?.formatted() ?? "未実行"
            )
            LabeledContent(
                "最終保存",
                value: item.lastSavedAt?.formatted() ?? "未実行"
            )
            HStack { Spacer(); Button("閉じる") { isPresented = false } }
        }.padding(24).frame(width: 460)
    }
}
