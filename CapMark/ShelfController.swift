import AppKit
import SwiftUI

enum ShelfGeometry {
    static func origin(
        panelSize: CGSize, visibleFrame: CGRect,
        position: ShelfPosition, margin: CGFloat = 18
    ) -> CGPoint {
        let x = switch position {
        case .bottomRight, .topRight: visibleFrame.maxX - panelSize.width - margin
        case .bottomLeft, .topLeft: visibleFrame.minX + margin
        }
        let y = switch position {
        case .bottomRight, .bottomLeft: visibleFrame.minY + margin
        case .topRight, .topLeft: visibleFrame.maxY - panelSize.height - margin
        }
        return CGPoint(x: x, y: y)
    }
}

@MainActor
final class ShelfController {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private weak var model: AppModel?

    func show(items: [CaptureItem], model: AppModel) {
        self.model = model
        guard let latest = items.first else { hide(); return }
        hideTask?.cancel()
        hideTask = nil

        let content = ShelfView(item: latest)
            .environmentObject(model)
            // コンテンツ固有サイズを確定させ、パネル下端で角が欠けないようにする
            .fixedSize()
        let hosting = NSHostingView(rootView: content)
        let fitted = hosting.fittingSize
        // 影の描画余白（中身は中央配置）
        let shadowPad: CGFloat = 16
        let panelSize = CGSize(
            width: ceil(fitted.width) + shadowPad * 2,
            height: ceil(fitted.height) + shadowPad * 2
        )

        if panel == nil {
            panel = NSPanel(
                contentRect: CGRect(origin: .zero, size: panelSize),
                styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
                backing: .buffered, defer: false
            )
            panel?.level = .floating
            panel?.isOpaque = false
            panel?.backgroundColor = .clear
            // 角の欠け防止のためウィンドウ影は使わず、SwiftUI側で影を描く
            panel?.hasShadow = false
            panel?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }

        hosting.frame = CGRect(
            x: shadowPad,
            y: shadowPad,
            width: fitted.width,
            height: fitted.height
        )
        let container = NSView(frame: CGRect(origin: .zero, size: panelSize))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.addSubview(hosting)
        panel?.contentView = container
        panel?.setContentSize(panelSize)

        let targetScreen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == latest.displayID
        } ?? NSScreen.main
        position(
            panel: panel!, mode: model.settings.shelfPosition,
            visibleFrame: targetScreen?.visibleFrame
        )
        present(
            panel: panel!,
            animation: model.settings.shelfAnimation,
            position: model.settings.shelfPosition
        )
        scheduleAutoHide(after: model.settings.shelfDuration)
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
        model?.shelfDidHide()
    }

    func pauseAutoHide() {
        hideTask?.cancel()
        hideTask = nil
    }

    func resumeAutoHide(model: AppModel) {
        _ = model
    }

    private func position(
        panel: NSPanel, mode: ShelfPosition, visibleFrame: CGRect?
    ) {
        guard let visibleFrame else { return }
        panel.setFrameOrigin(
            ShelfGeometry.origin(
                panelSize: panel.frame.size,
                visibleFrame: visibleFrame,
                position: mode
            )
        )
    }

    private func present(panel: NSPanel, animation: ShelfAnimation, position: ShelfPosition) {
        guard animation != .none, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            return
        }
        let finalOrigin = panel.frame.origin
        panel.alphaValue = 0
        if animation == .slide {
            let direction: CGFloat = position == .bottomLeft || position == .bottomRight ? -18 : 18
            panel.setFrameOrigin(CGPoint(x: finalOrigin.x, y: finalOrigin.y + direction))
        }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            if animation == .slide {
                panel.animator().setFrameOrigin(finalOrigin)
            }
        }
    }

    private func scheduleAutoHide(after duration: Double) {
        hideTask?.cancel()
        guard duration > 0 else {
            hideTask = nil
            return
        }
        hideTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(duration))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }
}

/// 撮影直後に画面の四隅へ表示する一時プレビュー。
/// 構造: [画像（枠1本）] → [操作アイコン] を1枚の角丸カードに収める。
struct ShelfView: View {
    @EnvironmentObject private var model: AppModel
    let item: CaptureItem

    private var thumb: ShelfThumbnailSize { model.settings.shelfThumbnailSize }
    private let corner: CGFloat = 14
    private let imageCorner: CGFloat = 8

    var body: some View {
        shelfContent
            .observesLanguage()
    }

    private var shelfContent: some View {
        VStack(spacing: 0) {
            AsyncImageView(url: item.thumbnailURL)
                .frame(width: thumb.width, height: thumb.height)
                .background(Color.black.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: imageCorner, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: imageCorner, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 8)
                .onDrag {
                    DragExportService.itemProvider(for: item, model: model)
                }
                .accessibilityLabel(
                    L10n.tf("%d×%d screenshot", "%d×%dのスクリーンショット", item.pixelWidth, item.pixelHeight)
                )
                .accessibilityHint(L10n.t("Drag to hand off to other apps.", "ドラッグして他のアプリへ渡せます。"))

            HStack(spacing: 6) {
                ShelfIconButton(systemImage: "doc.on.clipboard", help: L10n.t("Copy to Clipboard", "クリップボードへコピー")) {
                    model.copy(item)
                }
                ShelfIconButton(systemImage: "square.and.arrow.down", help: L10n.t("Save to File", "ファイルへ保存")) {
                    model.save(item)
                }
                ShelfIconButton(systemImage: "xmark", help: L10n.t("Close", "閉じる")) {
                    model.dismissShelf()
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .frame(width: thumb.width + 20)
        .background {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(.regularMaterial)
        }
        // 四隅を同じRでクリップ（下端だけ角が消えるのを防ぐ）
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
        .contextMenu {
            Button(L10n.t("Copy", "コピー")) { model.copy(item) }
            Button(L10n.t("Save…", "保存…")) { model.save(item) }
            Button(L10n.t("Edit", "編集")) { model.edit(item) }
            Divider()
            Button(L10n.t("Close", "閉じる")) { model.dismissShelf() }
            Button(L10n.t("Delete", "削除"), role: .destructive) { model.delete(item) }
        }
    }
}

private struct ShelfIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct AsyncImageView: View {
    let url: URL
    var contentMode: ContentMode = .fit
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(L10n.t("Loading image", "画像を読み込み中"))
            }
        }
        .task(id: url) {
            if let cached = ThumbnailImageCache.shared.image(for: url) {
                image = cached
                return
            }
            guard !Task.isCancelled,
                  let data = await ImageLoadingService.readData(from: url),
                  !Task.isCancelled,
                  let loaded = NSImage(data: data) else { return }
            ThumbnailImageCache.shared.insert(loaded, for: url)
            image = loaded
        }
    }
}
