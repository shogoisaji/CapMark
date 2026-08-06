import SwiftUI
import AppKit

struct EditorCanvasLayout: Equatable {
    let canvasSize: CGSize
    let scale: CGFloat

    static func make(
        viewport: CGSize, imageSize: CGSize, requestedScale: CGFloat?
    ) -> EditorCanvasLayout {
        guard imageSize.width > 0, imageSize.height > 0,
              viewport.width > 0, viewport.height > 0 else {
            return EditorCanvasLayout(canvasSize: viewport, scale: 1)
        }
        if let requestedScale {
            let scale = min(max(requestedScale, 0.25), 4)
            return EditorCanvasLayout(
                canvasSize: CGSize(
                    width: max(viewport.width, imageSize.width * scale + 40),
                    height: max(viewport.height, imageSize.height * scale + 40)
                ),
                scale: scale
            )
        }
        return EditorCanvasLayout(
            canvasSize: viewport,
            scale: min(viewport.width / imageSize.width, viewport.height / imageSize.height) * 0.94
        )
    }
}

@MainActor
final class AnnotationEditorController: NSObject, NSWindowDelegate {
    private var windows: [UUID: NSWindow] = [:]
    private var drafts: [UUID: CaptureDocument] = [:]
    private var dirtyIDs: Set<UUID> = []
    private weak var model: AppModel?

    func show(item: CaptureItem, document: CaptureDocument, model: AppModel) {
        self.model = model
        if let existing = windows[item.id] {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let view = AnnotationEditorView(
            item: item, initialDocument: document, settings: model.settings,
            onDocumentChange: { [weak self] draft in
                self?.drafts[item.id] = draft
                self?.dirtyIDs.insert(item.id)
            }
        ) { [weak self] result, action in
            Task { @MainActor [weak self] in
                guard let updated = await model.finishEditing(item: item, document: result) else { return }
                self?.dirtyIDs.remove(item.id)
                self?.drafts[item.id] = result
                switch action {
                case .copy:
                    model.copy(updated)
                case .save:
                    model.save(updated)
                case .done:
                    model.editorDidFinish(updated)
                    model.annotationDidClose()
                    self?.windows[item.id]?.close()
                    self?.windows.removeValue(forKey: item.id)
                }
            }
        } onCancel: { [weak self] in
            model.editorDidCancel(item.id)
            model.annotationDidClose()
            self?.dirtyIDs.remove(item.id)
            self?.windows[item.id]?.close()
            self?.windows.removeValue(forKey: item.id)
        }
        .environmentObject(model)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = L10n.t("CapMark Annotation", "CapMark 注釈")
        window.setContentSize(CGSize(width: 1100, height: 760))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        windows[item.id] = window
        drafts[item.id] = document
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func applyLocalization() {
        let title = L10n.t("CapMark Annotation", "CapMark 注釈")
        for window in windows.values {
            window.title = title
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        if let id = windows.first(where: { $0.value === closing })?.key {
            windows.removeValue(forKey: id)
            drafts.removeValue(forKey: id)
            dirtyIDs.remove(id)
        }
        if windows.isEmpty {
            Task { @MainActor [weak model] in
                await Task.yield()
                model?.applyActivationPolicy(windowIsOpen: false)
            }
        }
        if windows.isEmpty { model?.annotationDidClose() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let id = windows.first(where: { $0.value === sender })?.key,
              dirtyIDs.contains(id) else { return true }
        let alert = NSAlert()
        alert.messageText = L10n.t("Save changes?", "変更を保存しますか？")
        alert.informativeText = L10n.t("This annotation has unsaved changes.", "この注釈には未保存の変更があります。")
        alert.addButton(withTitle: L10n.t("Save", "保存"))
        alert.addButton(withTitle: L10n.t("Discard", "破棄"))
        alert.addButton(withTitle: L10n.t("Cancel", "キャンセル"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            guard let draft = drafts[id],
                  let item = model?.captureItem(id: id) else { return false }
            Task { @MainActor [weak self, weak sender] in
                guard let self,
                      let updated = await model?.finishEditing(item: item, document: draft) else { return }
                model?.editorDidFinish(updated)
                dirtyIDs.remove(id)
                sender?.close()
            }
            return false
        case .alertSecondButtonReturn:
            model?.editorDidCancel(id)
            dirtyIDs.remove(id)
            return true
        default:
            return false
        }
    }
}

struct AnnotationEditorView: View {
    enum CommitAction { case copy, save, done }
    let item: CaptureItem
    let initialDocument: CaptureDocument
    let settings: AppSettings
    let onDocumentChange: (CaptureDocument) -> Void
    let onComplete: (CaptureDocument, CommitAction) -> Void
    let onCancel: () -> Void

    @State private var document: CaptureDocument
    @State private var undoStack: [CaptureDocument] = []
    @State private var redoStack: [CaptureDocument] = []
    @State private var tool: AnnotationTool = .arrow
    @State private var lineWidth: CGFloat = 6
    @State private var color = RGBAColor.red
    @State private var draftPoints: [CGPoint] = []
    @State private var showTextEntry = false
    @State private var pendingTextPoint: CGPoint = .zero
    @State private var textValue = ""
    @State private var selectedID: UUID?
    @State private var selectionOriginalPoints: [CGPoint]?
    @State private var selectionDragOrigin: CGPoint?
    @State private var fontSize: CGFloat = 28
    @State private var fontName = "Helvetica"
    @State private var fillEnabled = false
    @State private var fillColor = RGBAColor(red: 1, green: 0.16, blue: 0.12, alpha: 0.15)
    @State private var arrowAtStart = false
    @State private var textAlignment = AnnotationTextAlignment.left
    @State private var zoomScale: CGFloat?
    @State private var sourceImage: NSImage?

    init(
         item: CaptureItem, initialDocument: CaptureDocument, settings: AppSettings,
         onDocumentChange: @escaping (CaptureDocument) -> Void,
         onComplete: @escaping (CaptureDocument, CommitAction) -> Void, onCancel: @escaping () -> Void) {
        self.item = item
        self.initialDocument = initialDocument
        self.settings = settings
        self.onDocumentChange = onDocumentChange
        self.onComplete = onComplete
        self.onCancel = onCancel
        _document = State(initialValue: initialDocument)
        _tool = State(initialValue: settings.defaultAnnotationTool)
        _lineWidth = State(initialValue: settings.defaultAnnotationLineWidth)
        _color = State(initialValue: settings.defaultAnnotationColor)
        _fontSize = State(initialValue: settings.defaultFontSize)
        _fontName = State(initialValue: settings.defaultFontName)
        _textAlignment = State(initialValue: settings.defaultTextAlignment)
        _zoomScale = State(initialValue: settings.editorInitialZoom.scale)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(L10n.t("Cancel", "キャンセル"), action: onCancel).keyboardShortcut(.cancelAction)
                Divider().frame(height: 20)
                Button { undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .disabled(undoStack.isEmpty).keyboardShortcut("z", modifiers: .command)
                Button { redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                    .disabled(redoStack.isEmpty).keyboardShortcut("z", modifiers: [.command, .shift])
                Button(role: .destructive) { deleteSelectionOrLast() } label: { Label(L10n.t("Delete", "削除"), systemImage: "trash") }
                    .disabled(document.annotations.isEmpty)
                    .keyboardShortcut(.delete, modifiers: [])
                Button { sendBackward() } label: { Label(L10n.t("Send Backward", "背面へ"), systemImage: "square.2.layers.3d.bottom.filled") }
                    .disabled(selectedID == nil)
                Button { bringForward() } label: { Label(L10n.t("Bring Forward", "前面へ"), systemImage: "square.2.layers.3d.top.filled") }
                    .disabled(selectedID == nil)
                Menu(L10n.t("Select", "選択")) {
                    Button(L10n.t("Next Annotation", "次の注釈")) { selectAnnotation(movesForward: true) }
                        .keyboardShortcut("]", modifiers: .option)
                    Button(L10n.t("Previous Annotation", "前の注釈")) { selectAnnotation(movesForward: false) }
                        .keyboardShortcut("[", modifiers: .option)
                }
                .disabled(document.annotations.isEmpty)
                .accessibilityLabel(L10n.t("Select annotation", "注釈を選択"))
                Menu(L10n.t("Move", "移動")) {
                    Button(L10n.t("Up 1 px", "上へ1ピクセル")) { moveSelected(dx: 0, dy: -1) }
                        .keyboardShortcut(.upArrow, modifiers: [])
                    Button(L10n.t("Down 1 px", "下へ1ピクセル")) { moveSelected(dx: 0, dy: 1) }
                        .keyboardShortcut(.downArrow, modifiers: [])
                    Button(L10n.t("Left 1 px", "左へ1ピクセル")) { moveSelected(dx: -1, dy: 0) }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                    Button(L10n.t("Right 1 px", "右へ1ピクセル")) { moveSelected(dx: 1, dy: 0) }
                        .keyboardShortcut(.rightArrow, modifiers: [])
                    Divider()
                    Button(L10n.t("Up 10 px", "上へ10ピクセル")) { moveSelected(dx: 0, dy: -10) }
                        .keyboardShortcut(.upArrow, modifiers: .shift)
                    Button(L10n.t("Down 10 px", "下へ10ピクセル")) { moveSelected(dx: 0, dy: 10) }
                        .keyboardShortcut(.downArrow, modifiers: .shift)
                    Button(L10n.t("Left 10 px", "左へ10ピクセル")) { moveSelected(dx: -10, dy: 0) }
                        .keyboardShortcut(.leftArrow, modifiers: .shift)
                    Button(L10n.t("Right 10 px", "右へ10ピクセル")) { moveSelected(dx: 10, dy: 0) }
                        .keyboardShortcut(.rightArrow, modifiers: .shift)
                }
                .disabled(selectedID == nil)
                .accessibilityLabel(L10n.t("Move selected annotation", "選択した注釈を移動"))
                Spacer()
                Button(L10n.t("Fit", "全体表示")) { zoomScale = nil }
                    .help(L10n.t("Fit the whole image to the window", "画像全体をウィンドウに合わせる"))
                Menu {
                    Button("50%") { zoomScale = 0.5 }
                    Button("100%") { zoomScale = 1 }
                    Button("200%") { zoomScale = 2 }
                } label: {
                    Text(zoomScale.map { "\(Int($0 * 100))%" } ?? "Fit")
                        .monospacedDigit()
                }
                .accessibilityLabel(L10n.t("Zoom level", "表示倍率"))
                Button(L10n.t("Copy", "コピー")) { saveThenCopy() }
                    .keyboardShortcut("c", modifiers: .command)
                Button(L10n.t("Save…", "保存…")) { saveThenExport() }
                    .keyboardShortcut("s", modifiers: .command)
                Button(L10n.t("Done", "完了")) { onComplete(document, .done) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }.padding(10)
            Divider()
            HStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(AnnotationTool.allCases) { candidate in
                            AnnotationToolChip(
                                tool: candidate,
                                selected: tool == candidate
                            ) {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                    tool = candidate
                                }
                            }
                            .keyboardShortcut(shortcut(for: candidate), modifiers: .option)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 12)
                }
                .frame(width: 108)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
                Divider()
                GeometryReader { geometry in
                    let imageSize = CGSize(width: item.pixelWidth, height: item.pixelHeight)
                    let layout = EditorCanvasLayout.make(
                        viewport: geometry.size,
                        imageSize: imageSize,
                        requestedScale: zoomScale
                    )
                    ScrollView([.horizontal, .vertical]) {
                        editorCanvas(size: layout.canvasSize, scale: layout.scale)
                            .frame(
                                width: layout.canvasSize.width,
                                height: layout.canvasSize.height
                            )
                    }
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }
            Divider()
            HStack {
                ColorPicker(L10n.t("Color", "色"), selection: colorBinding, supportsOpacity: true).frame(width: 120)
                Slider(value: $lineWidth, in: 1...30)
                    .accessibilityLabel(L10n.t("Line width", "線幅"))
                    .accessibilityValue(L10n.tf("%d points", "%dポイント", Int(lineWidth)))
                Text(L10n.tf("Width %d", "線幅 %d", Int(lineWidth))).monospacedDigit().frame(width: 70)
                Slider(value: Binding(
                    get: { color.alpha },
                    set: { color.alpha = $0 }
                ), in: 0.1...1)
                .accessibilityLabel(L10n.t("Opacity", "不透明度"))
                .accessibilityValue(L10n.tf("%d percent", "%dパーセント", Int(color.alpha * 100)))
                Text(L10n.tf("Opacity %d%%", "不透明度 %d%%", Int(color.alpha * 100))).monospacedDigit().frame(width: 100)
                if tool == .text {
                    Picker(L10n.t("Font", "フォント"), selection: $fontName) {
                        ForEach(["Helvetica", "Avenir Next", "Menlo", "Hiragino Sans"], id: \.self) {
                            Text($0).tag($0)
                        }
                    }.frame(width: 150)
                    Picker(L10n.t("Align", "揃え"), selection: $textAlignment) {
                        ForEach(AnnotationTextAlignment.allCases) { Text($0.title).tag($0) }
                    }.frame(width: 100)
                    Slider(value: $fontSize, in: 12...96)
                        .accessibilityLabel(L10n.t("Font size", "フォントサイズ"))
                        .accessibilityValue(L10n.tf("%d points", "%dポイント", Int(fontSize)))
                    Text("\(Int(fontSize))pt").monospacedDigit().frame(width: 55)
                }
                if tool == .rectangle || tool == .ellipse {
                    Toggle(L10n.t("Fill", "塗り"), isOn: $fillEnabled).toggleStyle(.checkbox)
                    if fillEnabled {
                        ColorPicker(L10n.t("Fill Color", "塗り色"), selection: fillColorBinding, supportsOpacity: true)
                            .frame(width: 100)
                    }
                }
                if tool == .arrow {
                    Toggle(L10n.t("Arrow at start", "始点に矢印"), isOn: $arrowAtStart).toggleStyle(.checkbox)
                }
                Spacer()
                Text(L10n.tf("%d annotations", "%d個の注釈", document.annotations.count))
                    .foregroundStyle(.secondary)
            }.padding(10)
        }
        .sheet(isPresented: $showTextEntry) {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.t("Add Text", "テキストを追加")).font(.headline)
                TextField(L10n.t("Text", "テキスト"), text: $textValue).textFieldStyle(.roundedBorder)
                    .onSubmit(addText)
                HStack {
                    Spacer()
                    Button(L10n.t("Cancel", "キャンセル")) { showTextEntry = false }
                    Button(L10n.t("Add", "追加"), action: addText).buttonStyle(.borderedProminent)
                }
            }.padding(22).frame(width: 380)
        }
        .onChange(of: document) { _, value in
            onDocumentChange(value)
        }
        .observesLanguage()
        .task(id: item.originalURL) {
            guard let data = await ImageLoadingService.readData(from: item.originalURL),
                  !Task.isCancelled else { return }
            sourceImage = NSImage(data: data)
        }
    }

    private func editorCanvas(size: CGSize, scale: CGFloat) -> some View {
        let imageSize = CGSize(width: item.pixelWidth, height: item.pixelHeight)
        let fitted = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2)
        return Canvas { context, _ in
            if let image = sourceImage {
                context.draw(Image(nsImage: image), in: CGRect(origin: origin, size: fitted))
            }
            context.clip(to: Path(CGRect(origin: origin, size: fitted)))
            for annotation in document.annotations {
                draw(annotation, context: &context, origin: origin, scale: scale)
                if selectedID == annotation.id {
                    let box = annotationBounds(annotation).insetBy(dx: -6, dy: -6)
                    context.stroke(
                        Path(transformed(box, origin: origin, scale: scale)),
                        with: .color(.accentColor),
                        style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                    )
                }
            }
            if !draftPoints.isEmpty {
                let draft = Annotation(tool: tool, points: draftPoints, color: activeColor, lineWidth: lineWidth)
                draw(draft, context: &context, origin: origin, scale: scale)
            }
            if tool == .crop {
                let crop = transformed(document.cropRect, origin: origin, scale: scale)
                context.stroke(Path(crop), with: .color(.white), style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: tool == .text ? 0 : 2)
                .onChanged { value in
                    let point = imagePoint(value.location, origin: origin, scale: scale, imageSize: imageSize)
                    guard point.x >= 0, point.y >= 0, point.x <= imageSize.width, point.y <= imageSize.height else { return }
                    if tool == .select {
                        moveSelection(to: point, dragStart: imagePoint(value.startLocation, origin: origin, scale: scale, imageSize: imageSize))
                        return
                    }
                    if draftPoints.isEmpty { draftPoints = [point] }
                    if tool == .pen || tool == .marker { draftPoints.append(point) }
                    else if draftPoints.count == 1 { draftPoints.append(point) }
                    else { draftPoints[draftPoints.count - 1] = point }
                }
                .onEnded { _ in
                    if tool == .select {
                        selectionOriginalPoints = nil
                        selectionDragOrigin = nil
                    } else {
                        finishDraft()
                    }
                }
        )
    }

    private func shortcut(for tool: AnnotationTool) -> KeyEquivalent {
        switch tool {
        case .select: "v"
        case .pen: "p"
        case .marker: "m"
        case .line: "l"
        case .arrow: "a"
        case .rectangle: "r"
        case .ellipse: "e"
        case .text: "t"
        case .blackout: "b"
        case .mosaic: "x"
        case .crop: "c"
        }
    }

    private var activeColor: RGBAColor {
        switch tool {
        case .marker:
            RGBAColor(red: 1, green: 0.85, blue: 0, alpha: settings.defaultMarkerOpacity)
        case .blackout: .black
        default: color
        }
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: color.nsColor) },
            set: {
                let converted = NSColor($0).usingColorSpace(.deviceRGB) ?? .red
                color = RGBAColor(red: converted.redComponent, green: converted.greenComponent,
                                  blue: converted.blueComponent, alpha: converted.alphaComponent)
            }
        )
    }

    private func finishDraft() {
        guard let first = draftPoints.first else { return }
        if tool == .text {
            pendingTextPoint = first
            textValue = ""
            showTextEntry = true
        } else if tool == .crop, let last = draftPoints.last {
            checkpoint()
            document.cropRect = rect(first, last)
        } else if tool != .select {
            checkpoint()
            document.annotations.append(Annotation(
                tool: tool, points: draftPoints, color: activeColor, lineWidth: lineWidth,
                fillColor: fillEnabled ? fillColor : nil,
                arrowAtStart: tool == .arrow ? arrowAtStart : nil
            ))
        }
        draftPoints = []
    }

    private func addText() {
        guard !textValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showTextEntry = false; return
        }
        checkpoint()
        document.annotations.append(Annotation(
            tool: .text, points: [pendingTextPoint], color: color,
            lineWidth: lineWidth, text: textValue, fontSize: fontSize,
            fontName: fontName, textAlignment: textAlignment
        ))
        showTextEntry = false
    }

    private func checkpoint() {
        undoStack.append(document)
        redoStack.removeAll()
        document.updatedAt = Date()
    }

    private func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(document)
        document = previous
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(document)
        document = next
    }

    private func deleteSelectionOrLast() {
        checkpoint()
        if let selectedID {
            document.annotations.removeAll { $0.id == selectedID }
            self.selectedID = nil
        } else {
            _ = document.annotations.popLast()
        }
    }

    private func moveSelection(to point: CGPoint, dragStart: CGPoint) {
        if selectionOriginalPoints == nil {
            selectedID = hitTest(dragStart)
            guard let index = selectedIndex else { return }
            checkpoint()
            selectionOriginalPoints = document.annotations[index].points
            selectionDragOrigin = dragStart
        }
        guard let index = selectedIndex,
              let original = selectionOriginalPoints,
              let origin = selectionDragOrigin else { return }
        let delta = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        document.annotations[index].points = original.map {
            CGPoint(x: $0.x + delta.x, y: $0.y + delta.y)
        }
    }

    private var selectedIndex: Int? {
        guard let selectedID else { return nil }
        return document.annotations.firstIndex { $0.id == selectedID }
    }

    private func hitTest(_ point: CGPoint) -> UUID? {
        document.annotations.reversed().first {
            annotationBounds($0).insetBy(dx: -12, dy: -12).contains(point)
        }?.id
    }

    private func annotationBounds(_ annotation: Annotation) -> CGRect {
        guard let first = annotation.points.first else { return .zero }
        if annotation.tool == .text {
            let width = CGFloat(annotation.text?.count ?? 1) * annotation.fontSize * 0.65
            let x = AnnotationTextLayout.originX(
                anchorX: first.x,
                textWidth: width,
                alignment: annotation.textAlignment ?? .left
            )
            return CGRect(
                x: x, y: first.y,
                width: width, height: annotation.fontSize * 1.3
            )
        }
        let xs = annotation.points.map(\.x)
        let ys = annotation.points.map(\.y)
        return CGRect(
            x: xs.min() ?? first.x, y: ys.min() ?? first.y,
            width: max(1, (xs.max() ?? first.x) - (xs.min() ?? first.x)),
            height: max(1, (ys.max() ?? first.y) - (ys.min() ?? first.y))
        )
    }

    private func bringForward() {
        guard let index = selectedIndex, index < document.annotations.count - 1 else { return }
        checkpoint()
        document.annotations.swapAt(index, index + 1)
    }

    private func sendBackward() {
        guard let index = selectedIndex, index > 0 else { return }
        checkpoint()
        document.annotations.swapAt(index, index - 1)
    }

    private func selectAnnotation(movesForward: Bool) {
        let current = selectedIndex
        guard let index = AnnotationSelectionCycle.index(
            count: document.annotations.count,
            current: current,
            movesForward: movesForward
        ) else {
            selectedID = nil
            return
        }
        tool = .select
        selectedID = document.annotations[index].id
    }

    private func moveSelected(dx: CGFloat, dy: CGFloat) {
        guard let index = selectedIndex else { return }
        let annotation = document.annotations[index]
        let delta = AnnotationMovementGeometry.clampedDelta(
            bounds: annotationBounds(annotation),
            imageSize: CGSize(width: item.pixelWidth, height: item.pixelHeight),
            requested: CGPoint(x: dx, y: dy)
        )
        guard delta != .zero else { return }
        checkpoint()
        document.annotations[index].points = annotation.points.map {
            CGPoint(x: $0.x + delta.x, y: $0.y + delta.y)
        }
    }

    private func saveThenCopy() {
        onComplete(document, .copy)
    }

    private func saveThenExport() {
        onComplete(document, .save)
    }

    private var fillColorBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: fillColor.nsColor) },
            set: {
                let converted = NSColor($0).usingColorSpace(.deviceRGB) ?? .red
                fillColor = RGBAColor(
                    red: converted.redComponent, green: converted.greenComponent,
                    blue: converted.blueComponent, alpha: converted.alphaComponent
                )
            }
        )
    }

    private func imagePoint(_ point: CGPoint, origin: CGPoint, scale: CGFloat, imageSize: CGSize) -> CGPoint {
        CGPoint(x: (point.x - origin.x) / scale, y: imageSize.height - ((point.y - origin.y) / scale))
    }

    private func transformed(_ rect: CGRect, origin: CGPoint, scale: CGFloat) -> CGRect {
        CGRect(x: origin.x + rect.minX * scale,
               y: origin.y + (CGFloat(item.pixelHeight) - rect.maxY) * scale,
               width: rect.width * scale, height: rect.height * scale)
    }

    private func draw(_ annotation: Annotation, context: inout GraphicsContext, origin: CGPoint, scale: CGFloat) {
        guard let first = annotation.points.first else { return }
        let points = annotation.points.map {
            CGPoint(x: origin.x + $0.x * scale, y: origin.y + (CGFloat(item.pixelHeight) - $0.y) * scale)
        }
        let last = points.last ?? points[0]
        let style = StrokeStyle(lineWidth: annotation.lineWidth * scale, lineCap: .round, lineJoin: .round)
        let drawColor = Color(nsColor: annotation.color.nsColor)
        switch annotation.tool {
        case .pen, .marker:
            var path = Path(); path.move(to: points[0])
            for point in points.dropFirst() { path.addLine(to: point) }
            context.stroke(path, with: .color(drawColor), style: style)
        case .line, .arrow:
            let arrowStart = annotation.arrowAtStart == true ? last : points[0]
            let arrowEnd = annotation.arrowAtStart == true ? points[0] : last
            var path = Path(); path.move(to: arrowStart); path.addLine(to: arrowEnd)
            if annotation.tool == .arrow {
                let angle = atan2(arrowEnd.y - arrowStart.y, arrowEnd.x - arrowStart.x)
                let length = max(12, annotation.lineWidth * scale * 4)
                path.move(to: arrowEnd)
                path.addLine(to: CGPoint(x: arrowEnd.x - length * cos(angle - .pi / 6), y: arrowEnd.y - length * sin(angle - .pi / 6)))
                path.move(to: arrowEnd)
                path.addLine(to: CGPoint(x: arrowEnd.x - length * cos(angle + .pi / 6), y: arrowEnd.y - length * sin(angle + .pi / 6)))
            }
            context.stroke(path, with: .color(drawColor), style: style)
        case .rectangle, .blackout, .mosaic:
            let value = rect(points[0], last)
            if annotation.tool == .blackout { context.fill(Path(value), with: .color(.black)) }
            else if annotation.tool == .mosaic {
                context.fill(Path(value), with: .color(.gray.opacity(0.65)))
                context.stroke(Path(value), with: .color(.white.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            } else {
                if let fill = annotation.fillColor {
                    context.fill(Path(value), with: .color(Color(nsColor: fill.nsColor)))
                }
                context.stroke(Path(value), with: .color(drawColor), style: style)
            }
        case .ellipse:
            if let fill = annotation.fillColor {
                context.fill(Path(ellipseIn: rect(points[0], last)), with: .color(Color(nsColor: fill.nsColor)))
            }
            context.stroke(Path(ellipseIn: rect(points[0], last)), with: .color(drawColor), style: style)
        case .text:
            let anchor: UnitPoint = switch annotation.textAlignment ?? .left {
            case .left: .bottomLeading
            case .center: .bottom
            case .right: .bottomTrailing
            }
            context.draw(
                Text(annotation.text ?? "")
                    .font(.custom(annotation.fontName ?? "Helvetica", size: annotation.fontSize * scale))
                    .foregroundStyle(drawColor),
                at: points[0], anchor: anchor
            )
        case .select, .crop:
            break
        }
        _ = first
    }

    private func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

/// 注釈ツール選択チップ。
/// アイコンとラベルを縦に分離し、幅いっぱい中央寄せで並べる。
private struct AnnotationToolChip: View {
    let tool: AnnotationTool
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: tool.symbol)
                    .font(.system(size: 16, weight: selected ? .semibold : .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.88))
                    .frame(width: 40, height: 32)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(iconPlateFill)
                    }

                Text(tool.title)
                    .font(.system(size: 10, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 8)
            .padding(.bottom, 7)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(chipBackground)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(chipBorder, lineWidth: selected ? 1.5 : 1)
            }
            .animation(.easeOut(duration: 0.14), value: selected)
            .animation(.easeOut(duration: 0.1), value: hovering)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .onHover { hovering = $0 }
        .help(tool.title)
        .accessibilityLabel(tool.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(selected ? L10n.t("Selected", "選択中") : L10n.t("Not selected", "未選択"))
    }

    private var iconPlateFill: some ShapeStyle {
        if selected {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [Color.accentColor, Color.accentColor.opacity(0.8)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        return AnyShapeStyle(Color.primary.opacity(hovering ? 0.1 : 0.06))
    }

    private var chipBackground: Color {
        if selected { return Color.accentColor.opacity(0.1) }
        return Color.primary.opacity(hovering ? 0.045 : 0.02)
    }

    private var chipBorder: Color {
        if selected { return Color.accentColor.opacity(0.5) }
        return Color.primary.opacity(hovering ? 0.12 : 0.07)
    }
}
