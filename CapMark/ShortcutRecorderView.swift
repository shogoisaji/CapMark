import SwiftUI
import AppKit

struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var configuration: ShortcutConfiguration
    @Binding var validationMessage: String?

    func makeNSView(context: Context) -> ShortcutRecorderNSView {
        let view = ShortcutRecorderNSView()
        view.onShortcut = { newValue in
            if !newValue.command && !newValue.shift && !newValue.option && !newValue.control {
                validationMessage = L10n.t("Include at least one modifier key.", "修飾キーを1つ以上指定してください。")
            } else if [36, 53, 123, 124, 125, 126].contains(newValue.keyCode) {
                validationMessage = L10n.t("Return, Esc, and arrow keys are not allowed.", "Return、Esc、矢印キーは使用できません。")
            } else if ShortcutConflictValidator.isReserved(newValue) {
                validationMessage = L10n.t("This may conflict with a reserved macOS shortcut.", "macOSの予約済みショートカットと競合する可能性があります。")
            } else {
                validationMessage = nil
                configuration = newValue
            }
        }
        return view
    }

    func updateNSView(_ view: ShortcutRecorderNSView, context: Context) {
        view.display = configuration.display
        view.isUnset = !configuration.isConfigured
    }
}

final class ShortcutRecorderNSView: NSView {
    var onShortcut: ((ShortcutConfiguration) -> Void)?
    var display = "" {
        didSet {
            if display != oldValue {
                needsDisplay = true
                NSAccessibility.post(element: self, notification: .valueChanged)
            }
        }
    }
    var isUnset = false {
        didSet {
            if isUnset != oldValue { needsDisplay = true }
        }
    }
    private var recording = false
    private var isHighlighted = false

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        focusRingType = .exterior
        configureAccessibility()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        focusRingType = .exterior
        configureAccessibility()
    }

    private func configureAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(L10n.t("Record global shortcut", "グローバルショートカットを記録"))
        setAccessibilityHelp(L10n.t("After pressing, type a key combination with modifiers.", "押した後、修飾キーを含むキーの組み合わせを入力します。"))
    }

    override func mouseDown(with event: NSEvent) {
        beginRecording()
    }

    override func mouseEntered(with event: NSEvent) {
        isHighlighted = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHighlighted = false
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func keyDown(with event: NSEvent) {
        guard recording else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 { // Esc cancels recording
            recording = false
            needsDisplay = true
            NSAccessibility.post(element: self, notification: .valueChanged)
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var value = ShortcutConfiguration()
        value.keyCode = UInt32(event.keyCode)
        value.command = flags.contains(.command)
        value.shift = flags.contains(.shift)
        value.option = flags.contains(.option)
        value.control = flags.contains(.control)
        value.isConfigured = true
        recording = false
        onShortcut?(value)
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    override func resignFirstResponder() -> Bool {
        if recording {
            recording = false
            needsDisplay = true
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
        return super.resignFirstResponder()
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)

        let fill: NSColor
        if recording {
            fill = NSColor.controlAccentColor.withAlphaComponent(0.14)
        } else if isHighlighted {
            fill = NSColor.controlBackgroundColor.blended(withFraction: 0.08, of: .labelColor)
                ?? NSColor.controlBackgroundColor
        } else {
            fill = NSColor.controlBackgroundColor
        }
        fill.setFill()
        path.fill()

        let stroke: NSColor
        if recording {
            stroke = NSColor.controlAccentColor
        } else if window?.firstResponder === self {
            stroke = NSColor.keyboardFocusIndicatorColor
        } else {
            stroke = NSColor.separatorColor.withAlphaComponent(0.85)
        }
        stroke.setStroke()
        path.lineWidth = recording ? 1.5 : 1
        path.stroke()

        let string = recording ? L10n.t("Type a key combination…", "キーの組み合わせを入力…") : (display.isEmpty ? L10n.t("Click to record", "クリックして記録") : display)
        let weight: NSFont.Weight = recording ? .regular : .semibold
        let color: NSColor = recording
            ? .secondaryLabelColor
            : (isUnset || display.isEmpty ? .secondaryLabelColor : .labelColor)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: weight),
            .foregroundColor: color
        ]
        let size = string.size(withAttributes: attributes)
        string.draw(
            at: CGPoint(
                x: (self.bounds.width - size.width) / 2,
                y: (self.bounds.height - size.height) / 2
            ),
            withAttributes: attributes
        )
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 260, height: 36) }

    override func accessibilityValue() -> Any? {
        recording ? L10n.t("Waiting for input", "入力待ち") : display
    }

    override func accessibilityPerformPress() -> Bool {
        beginRecording()
        return true
    }

    private func beginRecording() {
        recording = true
        window?.makeFirstResponder(self)
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .valueChanged)
    }
}

enum ShortcutConflictValidator {
    static func isReserved(_ value: ShortcutConfiguration) -> Bool {
        // Finder/システムで一般的に予約される代表的な組み合わせ。
        if value.command && value.shift && [20, 21, 23, 22].contains(value.keyCode) { return true } // ⌘⇧3〜6
        if value.command && !value.shift && !value.option && !value.control &&
            [0, 1, 2, 3, 7, 8, 9, 12, 13, 15, 16, 17, 31, 35, 45].contains(value.keyCode) { return true }
        return false
    }
}
