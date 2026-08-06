import AppKit

enum SelectionGeometry {
    static func clamped(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        guard rect.width <= bounds.width, rect.height <= bounds.height else {
            return rect.intersection(bounds)
        }
        var result = rect
        result.origin.x = min(max(bounds.minX, result.origin.x), bounds.maxX - result.width)
        result.origin.y = min(max(bounds.minY, result.origin.y), bounds.maxY - result.height)
        return result
    }
}

@MainActor
final class SelectionOverlayController {
    private var windows: [SelectionOverlayWindow] = []
    private weak var activeWindow: SelectionOverlayWindow?
    private var completion: ((NSScreen, CGRect) -> Void)?
    private var cancellation: (() -> Void)?

    func begin(
        dimness: CGFloat, borderWidth: CGFloat,
        onComplete: @escaping (NSScreen, CGRect) -> Void, onCancel: @escaping () -> Void
    ) {
        completion = onComplete
        cancellation = onCancel
        windows = NSScreen.screens.map { screen in
            let window = SelectionOverlayWindow(
                screen: screen, dimness: dimness, borderWidth: borderWidth
            )
            window.overlayView.onComplete = { [weak self] rect in self?.finish(screen: screen, rect: rect) }
            window.overlayView.onCancel = { [weak self] in self?.cancel() }
            window.orderFrontRegardless()
            return window
        }
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKey()
    }

    private func finish(screen: NSScreen, rect: CGRect) {
        guard let selectedWindow = windows.first(where: {
            $0.screen?.frame == screen.frame
        }) else {
            cancel()
            return
        }
        activeWindow = selectedWindow
        windows.filter { $0 !== selectedWindow }.forEach { $0.orderOut(nil) }
        selectedWindow.overlayView.showCaptureProgress()
        completion?(screen, rect)
        completion = nil
    }

    func beginQuickAnnotation(
        image: CGImage, item: CaptureItem, settings: AppSettings,
        onComplete: @escaping (CaptureDocument) -> Void,
        onCancel: @escaping () -> Void
    ) {
        guard let activeWindow else {
            onCancel()
            return
        }
        activeWindow.overlayView.beginQuickAnnotation(
            image: image, item: item, settings: settings,
            onComplete: { [weak self] document in
                // 装飾完了と同時にオーバーレイ（モーダル）を閉じる
                self?.closeAll()
                self?.cancellation = nil
                onComplete(document)
            },
            onCancel: { [weak self] in
                self?.closeAll()
                self?.cancellation = nil
                onCancel()
            }
        )
        activeWindow.makeKey()
    }

    func cancel() {
        closeAll()
        cancellation?()
        completion = nil
        cancellation = nil
    }

    private func closeAll() {
        windows.forEach { window in
            window.overlayView.endAnnotationSession()
            window.orderOut(nil)
        }
        windows.removeAll()
        activeWindow = nil
    }
}

final class SelectionOverlayWindow: NSWindow {
    let overlayView: SelectionOverlayView

    init(screen: NSScreen, dimness: CGFloat, borderWidth: CGFloat) {
        overlayView = SelectionOverlayView(
            frame: CGRect(origin: .zero, size: screen.frame.size),
            dimness: dimness, borderWidth: borderWidth
        )
        super.init(
            contentRect: screen.frame, styleMask: .borderless,
            backing: .buffered, defer: false
        )
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = overlayView
    }

    override var canBecomeKey: Bool { true }
}

final class SelectionOverlayView: NSView {
    private enum Mode {
        case selecting
        case captureProgress
        case annotating
    }

    private enum QuickAction: CaseIterable {
        case pen
        case rectangle
        case ellipse
        case text
        case undo
        case cancel
        case done

        var title: String {
            switch self {
            case .pen: L10n.t("Pen", "ペン")
            case .rectangle: L10n.t("Rectangle", "矩形")
            case .ellipse: L10n.t("Ellipse", "楕円")
            case .text: L10n.t("Text", "テキスト")
            case .undo: L10n.t("Undo", "戻す")
            case .cancel: L10n.t("Cancel", "キャンセル")
            case .done: L10n.t("Done", "完了")
            }
        }

        var symbolName: String {
            switch self {
            case .pen: "pencil.tip"
            case .rectangle: "rectangle"
            case .ellipse: "oval"
            case .text: "textformat"
            case .undo: "arrow.uturn.backward"
            case .cancel: "xmark"
            case .done: "checkmark"
            }
        }

        var isTool: Bool {
            switch self {
            case .pen, .rectangle, .ellipse, .text: true
            case .undo, .cancel, .done: false
            }
        }

        func matches(tool: AnnotationTool) -> Bool {
            switch self {
            case .pen: tool == .pen
            case .rectangle: tool == .rectangle
            case .ellipse: tool == .ellipse
            case .text: tool == .text
            case .undo, .cancel, .done: false
            }
        }
    }

    private enum ResizeHandle { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left }
    var onComplete: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    private var mode = Mode.selecting
    private var startPoint: CGPoint?
    private var selection: CGRect?
    private var tracking: NSTrackingArea?
    private var movingSelection = false
    private var moveOffset: CGPoint = .zero
    private var spaceIsDown = false
    private var resizeHandle: ResizeHandle?
    private var resizeOriginal: CGRect?
    private let dimness: CGFloat
    private let borderWidth: CGFloat
    private var capturedImage: NSImage?
    private var capturedPixelSize: CGSize = .zero
    private var quickDocument: CaptureDocument?
    private var quickTool: AnnotationTool = .pen
    private var quickColor = RGBAColor.red
    private var quickLineWidth: CGFloat = 6
    private var quickDraftPoints: [CGPoint] = []
    private var quickCompletion: ((CaptureDocument) -> Void)?
    private var quickCancellation: (() -> Void)?
    private var quickToolbar: NSVisualEffectView?
    private var quickButtons: [QuickAction: NSButton] = [:]
    private var textField: NSTextField?
    private var pendingTextPoint: CGPoint?

    init(frame frameRect: NSRect, dimness: CGFloat, borderWidth: CGFloat) {
        self.dimness = dimness
        self.borderWidth = borderWidth
        super.init(frame: frameRect)
        configureAccessibility()
    }

    required init?(coder: NSCoder) {
        self.dimness = 0.55
        self.borderWidth = 2
        super.init(coder: coder)
        configureAccessibility()
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        window?.makeFirstResponder(self)
        window?.acceptsMouseMovedEvents = true
        window?.invalidateCursorRects(for: self)
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved], owner: self)
        addTrackingArea(tracking!)
        super.updateTrackingAreas()
    }

    override func layout() {
        super.layout()
        quickToolbar?.frame = toolbarFrame
        for (action, frame) in quickActionFrames() {
            quickButtons[action]?.frame = frame.offsetBy(
                dx: -toolbarFrame.minX, dy: -toolbarFrame.minY
            )
        }
        layoutQuickToolbarDivider()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if mode == .captureProgress { return }
        if mode == .annotating {
            handleQuickMouseDown(at: point)
            return
        }
        if event.clickCount == 2, let selection, selection.contains(point) {
            complete(selection)
            return
        }
        if let selection, let handle = hitHandle(at: point, selection: selection) {
            resizeHandle = handle
            resizeOriginal = selection
            return
        }
        if let selection, selection.contains(point), spaceIsDown {
            movingSelection = true
            moveOffset = CGPoint(x: point.x - selection.minX, y: point.y - selection.minY)
            return
        }
        movingSelection = false
        startPoint = point
        selection = nil
        announceSelection()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if mode == .captureProgress { return }
        if mode == .annotating {
            handleQuickMouseDragged(at: convert(event.locationInWindow, from: nil))
            return
        }
        if let handle = resizeHandle, let original = resizeOriginal {
            resize(original, handle: handle, to: convert(event.locationInWindow, from: nil))
            return
        }
        if movingSelection, var selection {
            let point = convert(event.locationInWindow, from: nil)
            selection.origin = CGPoint(x: point.x - moveOffset.x, y: point.y - moveOffset.y)
            selection.origin.x = min(max(0, selection.origin.x), bounds.width - selection.width)
            selection.origin.y = min(max(0, selection.origin.y), bounds.height - selection.height)
            self.selection = selection
            announceSelection()
            needsDisplay = true
            return
        }
        guard let startPoint else { return }
        let current = convert(event.locationInWindow, from: nil)
        selection = CGRect(
            x: min(startPoint.x, current.x), y: min(startPoint.y, current.y),
            width: abs(current.x - startPoint.x), height: abs(current.y - startPoint.y)
        ).intersection(bounds)
        announceSelection()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if mode == .captureProgress { return }
        if mode == .annotating {
            finishQuickDraft()
            return
        }
        if resizeHandle != nil {
            resizeHandle = nil
            resizeOriginal = nil
            return
        }
        if movingSelection {
            movingSelection = false
            return
        }
        guard let selection, selection.width >= 8, selection.height >= 8 else { return }
        complete(selection)
    }

    override func keyDown(with event: NSEvent) {
        if mode == .captureProgress {
            if event.keyCode == 53 { quickCancellation?() ?? onCancel?() }
            return
        }
        if mode == .annotating {
            if event.keyCode == 53 {
                if textField != nil { removeTextField() }
                else { performQuickAction(.cancel) }
                return
            }
            if event.keyCode == 36 {
                // テキスト入力中のReturnはフィールド側で処理する
                if textField != nil { return }
                performQuickAction(.done)
                return
            }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" {
                undoQuickAnnotation()
                return
            }
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 49 {
            spaceIsDown = true
            return
        }
        if event.keyCode == 53 { onCancel?(); return }
        if event.keyCode == 36, let selection, selection.width >= 8, selection.height >= 8 {
            complete(selection)
            return
        }
        guard var selection else { return }
        let amount: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 123: selection.origin.x -= amount
        case 124: selection.origin.x += amount
        case 125: selection.origin.y -= amount
        case 126: selection.origin.y += amount
        default: super.keyDown(with: event); return
        }
        self.selection = SelectionGeometry.clamped(selection, to: bounds)
        announceSelection()
        needsDisplay = true
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            spaceIsDown = false
            return
        }
        super.keyUp(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(dimness).setFill()
        bounds.fill()
        guard let selection else { return }
        if mode == .annotating, let capturedImage {
            capturedImage.draw(
                in: selection, from: .zero,
                operation: .sourceOver, fraction: 1
            )
            drawQuickAnnotations(in: selection)
            return
        }
        NSGraphicsContext.current?.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .clear
        selection.fill()
        NSGraphicsContext.current?.restoreGraphicsState()
        NSColor.systemBlue.setStroke()
        let path = NSBezierPath(rect: selection)
        path.lineWidth = borderWidth
        path.stroke()
        if mode == .captureProgress {
            let progress = L10n.t("Capturing…", "撮影中…")
            let progressAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
            let size = progress.size(withAttributes: progressAttributes)
            progress.draw(
                at: CGPoint(
                    x: selection.midX - size.width / 2,
                    y: selection.midY - size.height / 2
                ),
                withAttributes: progressAttributes
            )
        }
    }

    func showCaptureProgress() {
        mode = .captureProgress
        startPoint = nil
        resizeHandle = nil
        movingSelection = false
        needsDisplay = true
        setAccessibilityLabel(L10n.t("Capturing screenshot", "スクリーンショットを撮影中"))
        setAccessibilityHelp(L10n.t("When capture finishes, you can add annotations on this screen.", "撮影が完了すると、この画面で注釈を追加できます。"))
    }

    func beginQuickAnnotation(
        image: CGImage, item: CaptureItem, settings: AppSettings,
        onComplete: @escaping (CaptureDocument) -> Void,
        onCancel: @escaping () -> Void
    ) {
        capturedImage = NSImage(cgImage: image, size: selection?.size ?? .zero)
        capturedPixelSize = CGSize(width: item.pixelWidth, height: item.pixelHeight)
        quickDocument = CaptureDocument(
            cropRect: CGRect(origin: .zero, size: capturedPixelSize),
            annotations: [], updatedAt: Date()
        )
        quickTool = settings.defaultAnnotationTool.isQuickTool
            ? settings.defaultAnnotationTool
            : .pen
        quickColor = settings.defaultAnnotationColor
        quickLineWidth = settings.defaultAnnotationLineWidth
        quickCompletion = onComplete
        quickCancellation = onCancel
        mode = .annotating
        configureQuickToolbar()
        needsDisplay = true
        setAccessibilityLabel(L10n.t("Quick annotation", "簡易注釈"))
        setAccessibilityHelp(
            L10n.t(
                "Add pen, rectangle, ellipse, or text. Press Return to finish, Esc to cancel.",
                "ペン、矩形、楕円、テキストを追加できます。Returnで完了、Escでキャンセルします。"
            )
        )
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    /// オーバーレイを閉じる前に注釈セッションを片付ける
    func endAnnotationSession() {
        removeTextField()
        quickToolbar?.removeFromSuperview()
        quickToolbar = nil
        quickButtons.removeAll()
        quickCompletion = nil
        quickCancellation = nil
        quickDocument = nil
        quickDraftPoints = []
        capturedImage = nil
        mode = .selecting
    }

    private func complete(_ localRect: CGRect) {
        guard mode == .selecting else { return }
        mode = .captureProgress
        guard let screen = window?.screen else { return }
        let global = CGRect(
            x: screen.frame.minX + localRect.minX,
            y: screen.frame.minY + localRect.minY,
            width: localRect.width, height: localRect.height
        )
        onComplete?(global)
    }

    private func handlePoints(_ rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.minX, y: rect.midY)
        ]
    }

    private func hitHandle(at point: CGPoint, selection: CGRect) -> ResizeHandle? {
        let handles: [ResizeHandle] = [.topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left]
        for (index, candidate) in handlePoints(selection).enumerated()
            where hypot(candidate.x - point.x, candidate.y - point.y) <= 10 {
            return handles[index]
        }
        return nil
    }

    private func resize(_ original: CGRect, handle: ResizeHandle, to point: CGPoint) {
        var minX = original.minX
        var maxX = original.maxX
        var minY = original.minY
        var maxY = original.maxY
        switch handle {
        case .topLeft: minX = point.x; maxY = point.y
        case .top: maxY = point.y
        case .topRight: maxX = point.x; maxY = point.y
        case .right: maxX = point.x
        case .bottomRight: maxX = point.x; minY = point.y
        case .bottom: minY = point.y
        case .bottomLeft: minX = point.x; minY = point.y
        case .left: minX = point.x
        }
        minX = min(max(minX, bounds.minX), bounds.maxX)
        maxX = min(max(maxX, bounds.minX), bounds.maxX)
        minY = min(max(minY, bounds.minY), bounds.maxY)
        maxY = min(max(maxY, bounds.minY), bounds.maxY)
        let value = CGRect(x: min(minX, maxX), y: min(minY, maxY),
                           width: abs(maxX - minX), height: abs(maxY - minY))
        if value.width >= 8, value.height >= 8 { selection = value }
        announceSelection()
        needsDisplay = true
    }

    override func accessibilityValue() -> Any? {
        guard let selection else { return L10n.t("No selection", "範囲未選択") }
        return L10n.tf("Width %d points, height %d points", "幅%dポイント、高さ%dポイント", Int(selection.width), Int(selection.height))
    }

    private func configureAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L10n.t("Screenshot region selection", "スクリーンショット範囲選択"))
        setAccessibilityHelp(
            L10n.t(
                "Drag to select a region. Release to confirm, Esc to cancel.",
                "ドラッグで範囲を選択します。マウスを離すと確定し、Escでキャンセルします。"
            )
        )
    }

    private func announceSelection() {
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    private var toolbarFrame: CGRect {
        guard let selection else { return .zero }
        // アイコンチップ7個 + 仕切り + 余白を収める固定幅
        let width: CGFloat = 372
        let height: CGFloat = 60
        let x = min(max(12, selection.midX - width / 2), bounds.width - width - 12)
        let below = selection.minY - height - 12
        let y = below >= 12 ? below : min(bounds.height - height - 12, selection.maxY + 10)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func quickActionFrames() -> [(QuickAction, CGRect)] {
        let toolbar = toolbarFrame
        // アイコンのみの等幅チップを、ツールバー中央に整列
        let chip: CGFloat = 44
        let gap: CGFloat = 8
        let dividerExtra: CGFloat = 4
        // 7チップ + 6ギャップ + 仕切り分
        let contentWidth = chip * 7 + gap * 6 + dividerExtra
        var x = toolbar.midX - contentWidth / 2
        let y = toolbar.midY - chip / 2
        var frames: [(QuickAction, CGRect)] = []
        frames.reserveCapacity(QuickAction.allCases.count)
        for action in QuickAction.allCases {
            if action == .undo {
                x += dividerExtra
            }
            frames.append((action, CGRect(x: x, y: y, width: chip, height: chip)))
            x += chip + gap
        }
        return frames
    }

    private func handleQuickMouseDown(at point: CGPoint) {
        guard let selection, selection.contains(point) else { return }
        let imagePoint = quickImagePoint(from: point, in: selection)
        if quickTool == .text {
            beginTextEntry(at: point, imagePoint: imagePoint)
        } else {
            quickDraftPoints = [imagePoint]
        }
    }

    private func handleQuickMouseDragged(at point: CGPoint) {
        guard !quickDraftPoints.isEmpty, let selection else { return }
        let clamped = CGPoint(
            x: min(max(point.x, selection.minX), selection.maxX),
            y: min(max(point.y, selection.minY), selection.maxY)
        )
        let imagePoint = quickImagePoint(from: clamped, in: selection)
        if quickTool == .pen {
            quickDraftPoints.append(imagePoint)
        } else if quickDraftPoints.count == 1 {
            quickDraftPoints.append(imagePoint)
        } else {
            quickDraftPoints[quickDraftPoints.count - 1] = imagePoint
        }
        needsDisplay = true
    }

    private func finishQuickDraft() {
        guard !quickDraftPoints.isEmpty, quickTool != .text else { return }
        if quickTool == .pen || quickDraftPoints.count > 1 {
            quickDocument?.annotations.append(
                Annotation(
                    tool: quickTool, points: quickDraftPoints,
                    color: quickColor, lineWidth: quickLineWidth
                )
            )
            quickDocument?.updatedAt = Date()
        }
        quickDraftPoints = []
        updateQuickButtonStates()
        needsDisplay = true
    }

    private func performQuickAction(_ action: QuickAction) {
        switch action {
        case .pen: quickTool = .pen
        case .rectangle: quickTool = .rectangle
        case .ellipse: quickTool = .ellipse
        case .text: quickTool = .text
        case .undo:
            undoQuickAnnotation()
            updateQuickButtonStates()
            needsDisplay = true
            return
        case .cancel:
            guard let cancel = quickCancellation else { return }
            endAnnotationSession()
            cancel()
            return
        case .done:
            // 二重完了を防ぐ（Return とボタンの keyEquivalent など）
            guard let document = quickDocument, let complete = quickCompletion else { return }
            // 完了時は先にコールバックへ渡し、呼び出し側でオーバーレイを閉じる
            endAnnotationSession()
            complete(document)
            return
        }
        updateQuickButtonStates()
        needsDisplay = true
    }

    private func configureQuickToolbar() {
        quickToolbar?.removeFromSuperview()
        quickButtons.removeAll()
        let toolbar = NSVisualEffectView(frame: toolbarFrame)
        toolbar.material = .hudWindow
        toolbar.blendingMode = .withinWindow
        toolbar.state = .active
        toolbar.wantsLayer = true
        toolbar.layer?.cornerRadius = 16
        toolbar.layer?.masksToBounds = true
        toolbar.layer?.borderWidth = 1
        toolbar.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor

        let divider = NSView(frame: .zero)
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        divider.identifier = NSUserInterfaceItemIdentifier("quickToolbarDivider")
        toolbar.addSubview(divider)

        for (index, action) in QuickAction.allCases.enumerated() {
            // アイコンのみ（タイトルは toolTip / a11y に）。狭い枠での文字重なりを避ける。
            let button = NSButton(
                image: NSImage(),
                target: self,
                action: #selector(quickToolbarButtonPressed(_:))
            )
            button.tag = index
            button.isBordered = false
            button.setButtonType(.momentaryChange)
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.focusRingType = .exterior
            button.wantsLayer = true
            button.layer?.cornerRadius = 12
            button.layer?.masksToBounds = true
            button.toolTip = action.title
            button.setAccessibilityLabel(action.title)
            button.setAccessibilityHelp(quickActionHelp(action))
            button.setAccessibilityRole(.button)
            toolbar.addSubview(button)
            quickButtons[action] = button
        }
        addSubview(toolbar)
        quickToolbar = toolbar
        updateQuickButtonStates()
        needsLayout = true
    }

    @objc private func quickToolbarButtonPressed(_ sender: NSButton) {
        guard QuickAction.allCases.indices.contains(sender.tag) else { return }
        performQuickAction(QuickAction.allCases[sender.tag])
    }

    private func updateQuickButtonStates() {
        for (action, button) in quickButtons {
            let selected = action.matches(tool: quickTool)
            applyQuickButtonAppearance(button, action: action, selected: selected)
            if action == .undo {
                button.isEnabled = quickDocument?.annotations.isEmpty == false
                button.alphaValue = button.isEnabled ? 1 : 0.4
            }
            if action == .done {
                button.keyEquivalent = "\r"
            }
        }
        layoutQuickToolbarDivider()
    }

    private func applyQuickButtonAppearance(
        _ button: NSButton, action: QuickAction, selected: Bool
    ) {
        let iconColor: NSColor
        let fill: NSColor
        let border: NSColor

        switch action {
        case .pen, .rectangle, .ellipse, .text:
            if selected {
                fill = .controlAccentColor
                border = NSColor.white.withAlphaComponent(0.4)
                iconColor = .white
            } else {
                fill = NSColor.white.withAlphaComponent(0.1)
                border = NSColor.white.withAlphaComponent(0.14)
                iconColor = NSColor.labelColor.withAlphaComponent(0.92)
            }
            button.setAccessibilityValue(selected ? L10n.t("Selected", "選択中") : L10n.t("Not selected", "未選択"))
        case .done:
            fill = NSColor.systemGreen.withAlphaComponent(0.95)
            border = NSColor.white.withAlphaComponent(0.3)
            iconColor = .white
        case .cancel, .undo:
            fill = NSColor.white.withAlphaComponent(0.1)
            border = NSColor.white.withAlphaComponent(0.14)
            iconColor = NSColor.labelColor.withAlphaComponent(0.92)
        }

        button.layer?.backgroundColor = fill.cgColor
        button.layer?.borderWidth = selected && action.isTool ? 2 : 1
        button.layer?.borderColor = border.cgColor
        button.contentTintColor = iconColor
        button.title = ""
        if let symbol = NSImage(
            systemSymbolName: action.symbolName,
            accessibilityDescription: action.title
        ) {
            let config = NSImage.SymbolConfiguration(
                pointSize: selected && action.isTool ? 17 : 16,
                weight: .semibold
            ).applying(NSImage.SymbolConfiguration(paletteColors: [iconColor]))
            button.image = symbol.withSymbolConfiguration(config)
        }
    }

    private func layoutQuickToolbarDivider() {
        guard let toolbar = quickToolbar,
              let textButton = quickButtons[.text],
              let undoButton = quickButtons[.undo],
              let divider = toolbar.subviews.first(where: {
                  $0.identifier?.rawValue == "quickToolbarDivider"
              }) else { return }
        let gapMid = (textButton.frame.maxX + undoButton.frame.minX) / 2
        divider.frame = CGRect(
            x: gapMid - 0.5,
            y: 14,
            width: 1,
            height: max(0, toolbar.bounds.height - 28)
        )
    }

    private func quickActionHelp(_ action: QuickAction) -> String {
        switch action {
        case .pen: L10n.t("Drag on the image to draw a freehand line.", "画像上をドラッグして自由線を描きます。")
        case .rectangle: L10n.t("Drag on the image to draw a rectangle.", "画像上をドラッグして矩形を描きます。")
        case .ellipse: L10n.t("Drag on the image to draw an ellipse.", "画像上をドラッグして楕円を描きます。")
        case .text: L10n.t("Click on the image to enter text.", "画像上をクリックしてテキストを入力します。")
        case .undo: L10n.t("Undo the last annotation.", "最後に追加した注釈を取り消します。")
        case .cancel: L10n.t("Discard this capture.", "今回の撮影を破棄します。")
        case .done: L10n.t("Save annotations and move to the temporary display.", "注釈を保存して一時表示へ移動します。")
        }
    }

    private func undoQuickAnnotation() {
        guard quickDocument?.annotations.isEmpty == false else { return }
        _ = quickDocument?.annotations.popLast()
        quickDocument?.updatedAt = Date()
        updateQuickButtonStates()
        needsDisplay = true
    }

    private func quickImagePoint(from point: CGPoint, in selection: CGRect) -> CGPoint {
        guard selection.width > 0, selection.height > 0 else { return .zero }
        return CGPoint(
            x: (point.x - selection.minX) * capturedPixelSize.width / selection.width,
            y: (point.y - selection.minY) * capturedPixelSize.height / selection.height
        )
    }

    private func quickViewPoint(from point: CGPoint, in selection: CGRect) -> CGPoint {
        guard capturedPixelSize.width > 0, capturedPixelSize.height > 0 else { return .zero }
        return CGPoint(
            x: selection.minX + point.x * selection.width / capturedPixelSize.width,
            y: selection.minY + point.y * selection.height / capturedPixelSize.height
        )
    }

    private func drawQuickAnnotations(in selection: CGRect) {
        guard let quickDocument else { return }
        for annotation in quickDocument.annotations {
            drawQuickAnnotation(annotation, in: selection)
        }
        if !quickDraftPoints.isEmpty {
            drawQuickAnnotation(
                Annotation(
                    tool: quickTool, points: quickDraftPoints,
                    color: quickColor, lineWidth: quickLineWidth
                ),
                in: selection
            )
        }
    }

    private func drawQuickAnnotation(_ annotation: Annotation, in selection: CGRect) {
        guard let first = annotation.points.first else { return }
        let points = annotation.points.map { quickViewPoint(from: $0, in: selection) }
        let last = points.last ?? points[0]
        let scale = selection.width / max(1, capturedPixelSize.width)
        annotation.color.nsColor.setStroke()
        annotation.color.nsColor.setFill()
        let path = NSBezierPath()
        path.lineWidth = max(1, annotation.lineWidth * scale)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        switch annotation.tool {
        case .pen:
            path.move(to: points[0])
            for point in points.dropFirst() { path.line(to: point) }
            path.stroke()
        case .rectangle:
            path.appendRect(
                CGRect(
                    x: min(points[0].x, last.x), y: min(points[0].y, last.y),
                    width: abs(last.x - points[0].x), height: abs(last.y - points[0].y)
                )
            )
            path.stroke()
        case .ellipse:
            path.appendOval(
                in: CGRect(
                    x: min(points[0].x, last.x), y: min(points[0].y, last.y),
                    width: abs(last.x - points[0].x), height: abs(last.y - points[0].y)
                )
            )
            path.stroke()
        case .text:
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: max(10, annotation.fontSize * scale), weight: .semibold),
                .foregroundColor: annotation.color.nsColor
            ]
            (annotation.text ?? "").draw(at: quickViewPoint(from: first, in: selection), withAttributes: attributes)
        default:
            break
        }
    }

    private func beginTextEntry(at viewPoint: CGPoint, imagePoint: CGPoint) {
        removeTextField()
        pendingTextPoint = imagePoint
        let field = NSTextField(frame: CGRect(x: viewPoint.x, y: viewPoint.y - 2, width: 220, height: 28))
        field.placeholderString = L10n.t("Type text and press Return", "テキストを入力してReturn")
        field.target = self
        field.action = #selector(commitTextEntry)
        field.focusRingType = .default
        addSubview(field)
        textField = field
        window?.makeFirstResponder(field)
    }

    @objc private func commitTextEntry() {
        guard let field = textField, let point = pendingTextPoint else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty {
            quickDocument?.annotations.append(
                Annotation(
                    tool: .text, points: [point], color: quickColor,
                    lineWidth: quickLineWidth, text: value, fontSize: 28,
                    fontName: "Helvetica", textAlignment: .left
                )
            )
            quickDocument?.updatedAt = Date()
            updateQuickButtonStates()
        }
        removeTextField()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    private func removeTextField() {
        textField?.removeFromSuperview()
        textField = nil
        pendingTextPoint = nil
    }
}
