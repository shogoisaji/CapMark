import AppKit

enum MenuBarVisibilityPolicy {
    static func shouldShow(
        mode: MenuBarMode, isProcessing: Bool, hasHistory: Bool
    ) -> Bool {
        switch mode {
        case .always: true
        case .duringProcessing: isProcessing
        case .whenHistoryExists: hasHistory
        case .never: false
        }
    }
}

@MainActor
final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private weak var model: AppModel?

    func attach(model: AppModel) {
        self.model = model
        update()
    }

    func update() {
        guard let model else { return }
        let shouldShow = MenuBarVisibilityPolicy.shouldShow(
            mode: model.settings.menuBarMode,
            isProcessing: model.isProcessing,
            hasHistory: !model.history.isEmpty
        )
        if shouldShow, statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            statusItem?.button?.image = NSImage(systemSymbolName: "viewfinder.circle", accessibilityDescription: "CapMark")
        } else if !shouldShow, let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
        statusItem?.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("履歴を開く", action: #selector(showHistory)))
        menu.addItem(item("Shelfを表示", action: #selector(showShelf)))
        if model?.history.first != nil {
            let submenu = NSMenu()
            submenu.addItem(item("クリップボードへコピー", action: #selector(copyLatest)))
            submenu.addItem(item("保存…", action: #selector(saveLatest)))
            submenu.addItem(item("編集", action: #selector(editLatest)))
            submenu.addItem(item("削除", action: #selector(deleteLatest)))
            let latestItem = NSMenuItem(title: "最新画像", action: nil, keyEquivalent: "")
            latestItem.submenu = submenu
            menu.addItem(latestItem)
        }
        menu.addItem(.separator())
        let shortcut = NSMenuItem(title: "現在: \(model?.settings.shortcut.display ?? "未設定")", action: nil, keyEquivalent: "")
        shortcut.isEnabled = false
        menu.addItem(shortcut)
        let pause = item(model?.settings.shortcut.enabled == true ? "ショートカットを一時停止" : "ショートカットを再開", action: #selector(toggleShortcut))
        menu.addItem(pause)
        menu.addItem(item("画面キャプチャ権限を確認", action: #selector(openPermission)))
        menu.addItem(item("設定…", action: #selector(showSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("CapMarkを終了", action: #selector(quit), key: "q"))
        return menu
    }

    private func item(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let value = NSMenuItem(title: title, action: action, keyEquivalent: key)
        value.target = self
        return value
    }

    @objc private func showHistory() { model?.showHistory() }
    @objc private func showShelf() { model?.showShelf() }
    @objc private func showSettings() { model?.showSettings() }
    @objc private func quit() { model?.quit() }
    @objc private func openPermission() { PermissionService.openSettings() }
    @objc private func copyLatest() { if let item = model?.history.first { model?.copy(item) } }
    @objc private func saveLatest() { if let item = model?.history.first { model?.save(item) } }
    @objc private func editLatest() { if let item = model?.history.first { model?.edit(item) } }
    @objc private func deleteLatest() { if let item = model?.history.first { model?.delete(item) } }
    @objc private func toggleShortcut() {
        model?.settings.shortcut.enabled.toggle()
        model?.persistSettings()
    }
}
