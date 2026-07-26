import Foundation
import CoreGraphics
import AppKit

enum AnnotationTool: String, Codable, CaseIterable, Identifiable, Sendable {
    case select = "選択"
    case pen = "ペン"
    case marker = "マーカー"
    case line = "直線"
    case arrow = "矢印"
    case rectangle = "四角形"
    case ellipse = "楕円"
    case text = "テキスト"
    case blackout = "黒塗り"
    case mosaic = "モザイク"
    case crop = "Crop"

    var id: Self { self }
    var symbol: String {
        switch self {
        case .select: "arrow.up.left"
        case .pen: "pencil.tip"
        case .marker: "highlighter"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "oval"
        case .text: "textformat"
        case .blackout: "rectangle.fill"
        case .mosaic: "square.grid.3x3.fill"
        case .crop: "crop"
        }
    }

    /// 撮影直後の簡易注釈ツールバーで使えるツールか
    var isQuickTool: Bool {
        switch self {
        case .pen, .rectangle, .ellipse, .text: true
        default: false
        }
    }
}

enum AnnotationTextAlignment: String, Codable, CaseIterable, Identifiable, Sendable {
    case left = "左揃え"
    case center = "中央"
    case right = "右揃え"
    var id: Self { self }
}

struct RGBAColor: Codable, Hashable, Sendable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat

    static let red = RGBAColor(red: 1, green: 0.16, blue: 0.12, alpha: 1)
    static let yellowMarker = RGBAColor(red: 1, green: 0.85, blue: 0, alpha: 0.4)
    static let black = RGBAColor(red: 0, green: 0, blue: 0, alpha: 1)
    var nsColor: NSColor { NSColor(red: red, green: green, blue: blue, alpha: alpha) }
}

struct Annotation: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var tool: AnnotationTool
    var points: [CGPoint]
    var color: RGBAColor
    var lineWidth: CGFloat
    var text: String?
    var fontSize: CGFloat
    var fontName: String?
    var fillColor: RGBAColor?
    var arrowAtStart: Bool?
    var textAlignment: AnnotationTextAlignment?

    init(
        tool: AnnotationTool, points: [CGPoint], color: RGBAColor,
        lineWidth: CGFloat, text: String? = nil, fontSize: CGFloat = 28,
        fontName: String? = nil, fillColor: RGBAColor? = nil,
        arrowAtStart: Bool? = nil, textAlignment: AnnotationTextAlignment? = nil
    ) {
        self.id = UUID()
        self.tool = tool
        self.points = points
        self.color = color
        self.lineWidth = lineWidth
        self.text = text
        self.fontSize = fontSize
        self.fontName = fontName
        self.fillColor = fillColor
        self.arrowAtStart = arrowAtStart
        self.textAlignment = textAlignment
    }
}

struct CaptureDocument: Codable, Equatable, Sendable {
    var version = 1
    var cropRect: CGRect
    var annotations: [Annotation]
    var updatedAt: Date
}

struct AnnotationDocumentReadError: LocalizedError, UnderlyingErrorProviding {
    let underlyingError: Error

    var errorDescription: String? {
        "注釈データを読み込めません。元画像は変更せず保持されています。\n\(underlyingError.localizedDescription)"
    }
}

enum AnnotationDocumentService {
    static func load(from url: URL) throws -> CaptureDocument {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(CaptureDocument.self, from: data)
        } catch {
            throw AnnotationDocumentReadError(underlyingError: error)
        }
    }
}

enum AnnotationTextLayout {
    static func originX(
        anchorX: CGFloat, textWidth: CGFloat,
        alignment: AnnotationTextAlignment
    ) -> CGFloat {
        switch alignment {
        case .left: anchorX
        case .center: anchorX - textWidth / 2
        case .right: anchorX - textWidth
        }
    }
}

enum AnnotationSelectionCycle {
    static func index(
        count: Int, current: Int?, movesForward: Bool
    ) -> Int? {
        guard count > 0 else { return nil }
        guard let current, (0..<count).contains(current) else {
            return movesForward ? 0 : count - 1
        }
        return movesForward
            ? (current + 1) % count
            : (current - 1 + count) % count
    }
}

enum AnnotationMovementGeometry {
    static func clampedDelta(
        bounds: CGRect, imageSize: CGSize, requested: CGPoint
    ) -> CGPoint {
        CGPoint(
            x: min(max(requested.x, -bounds.minX), imageSize.width - bounds.maxX),
            y: min(max(requested.y, -bounds.minY), imageSize.height - bounds.maxY)
        )
    }
}
