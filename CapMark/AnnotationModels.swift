import Foundation
import CoreGraphics
import AppKit

enum AnnotationTool: String, Codable, CaseIterable, Identifiable, Sendable {
    case select
    case pen
    case marker
    case line
    case arrow
    case rectangle
    case ellipse
    case text
    case blackout
    case mosaic
    case crop

    var id: Self { self }

    var title: String {
        switch self {
        case .select: L10n.t("Select", "選択")
        case .pen: L10n.t("Pen", "ペン")
        case .marker: L10n.t("Marker", "マーカー")
        case .line: L10n.t("Line", "直線")
        case .arrow: L10n.t("Arrow", "矢印")
        case .rectangle: L10n.t("Rectangle", "四角形")
        case .ellipse: L10n.t("Ellipse", "楕円")
        case .text: L10n.t("Text", "テキスト")
        case .blackout: L10n.t("Blackout", "黒塗り")
        case .mosaic: L10n.t("Pixelate", "モザイク")
        case .crop: L10n.t("Crop", "切り抜き")
        }
    }

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

    /// Whether the tool is available on the post-capture quick toolbar.
    var isQuickTool: Bool {
        switch self {
        case .pen, .rectangle, .ellipse, .text: true
        default: false
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        let legacy: [String: Self] = [
            "選択": .select, "ペン": .pen, "マーカー": .marker, "直線": .line,
            "矢印": .arrow, "四角形": .rectangle, "楕円": .ellipse,
            "テキスト": .text, "黒塗り": .blackout, "モザイク": .mosaic,
            "Crop": .crop,
        ]
        if let value = Self(rawValue: raw) {
            self = value
        } else if let value = legacy[raw] {
            self = value
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown AnnotationTool: \(raw)"
            )
        }
    }
}

enum AnnotationTextAlignment: String, Codable, CaseIterable, Identifiable, Sendable {
    case left
    case center
    case right
    var id: Self { self }
    var title: String {
        switch self {
        case .left: L10n.t("Left", "左揃え")
        case .center: L10n.t("Center", "中央")
        case .right: L10n.t("Right", "右揃え")
        }
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        let legacy: [String: Self] = [
            "左揃え": .left, "中央": .center, "右揃え": .right,
        ]
        if let value = Self(rawValue: raw) {
            self = value
        } else if let value = legacy[raw] {
            self = value
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown AnnotationTextAlignment: \(raw)"
            )
        }
    }
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
        L10n.t(
            "Could not load annotation data. The original image was left unchanged.\n",
            "注釈データを読み込めません。元画像は変更せず保持されています。\n"
        ) + underlyingError.localizedDescription
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
