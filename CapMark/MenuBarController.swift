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
            statusItem?.button?.image = Self.menuBarImage()
        } else if !shouldShow, let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
        statusItem?.menu = buildMenu()
    }

    /// Menu bar icon: 18pt template image from the CapMark logo asset.
    private static func menuBarImage() -> NSImage? {
        guard let image = NSImage(named: "MenuBarIcon")?.copy() as? NSImage else {
            return NSImage(systemSymbolName: "viewfinder.circle", accessibilityDescription: "CapMark")
        }
        // Standard menu bar glyph size; 18pt keeps the CM logo legible.
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = "CapMark"
        return image
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item(L10n.t("Open History", "履歴を開く"), action: #selector(showHistory)))
        menu.addItem(.separator())
        let notSet = L10n.t("Not set", "未設定")
        let shortcut = NSMenuItem(
            title: L10n.tf("Current: %@", "現在: %@", model?.settings.shortcut.display ?? notSet),
            action: nil,
            keyEquivalent: ""
        )
        shortcut.isEnabled = false
        menu.addItem(shortcut)
        menu.addItem(item(L10n.t("Settings…", "設定…"), action: #selector(showSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item(L10n.t("Quit CapMark", "CapMarkを終了"), action: #selector(quit), key: "q"))
        return menu
    }

    private func item(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let value = NSMenuItem(title: title, action: action, keyEquivalent: key)
        value.target = self
        return value
    }

    @objc private func showHistory() { model?.showHistory() }
    @objc private func showSettings() { model?.showSettings() }
    @objc private func quit() { model?.quit() }
}
