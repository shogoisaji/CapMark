import AppKit
import CoreImage

enum ImageRenderer {
    static func latestPNG(for item: CaptureItem) throws -> Data {
        if let renderedURL = item.renderedFilename.map({
            StoragePaths.rendered.appendingPathComponent($0)
        }), FileManager.default.fileExists(atPath: renderedURL.path) {
            return try Data(contentsOf: renderedURL)
        }
        if let documentURL = item.documentURL {
            let document = try AnnotationDocumentService.load(from: documentURL)
            return try render(sourceURL: item.originalURL, document: document)
        }
        return try Data(contentsOf: item.originalURL)
    }

    static func render(sourceURL: URL, document: CaptureDocument) throws -> Data {
        guard let source = NSImage(contentsOf: sourceURL),
              let sourceCG = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let crop = document.cropRect.isEmpty
            ? CGRect(x: 0, y: 0, width: sourceCG.width, height: sourceCG.height)
            : document.cropRect.integral.intersection(CGRect(x: 0, y: 0, width: sourceCG.width, height: sourceCG.height))
        guard crop.width > 0, crop.height > 0,
              let context = CGContext(
                data: nil, width: Int(crop.width), height: Int(crop.height),
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { throw CocoaError(.fileWriteUnknown) }

        context.translateBy(x: -crop.minX, y: -crop.minY)
        context.draw(sourceCG, in: CGRect(x: 0, y: 0, width: sourceCG.width, height: sourceCG.height))
        for annotation in document.annotations {
            draw(annotation, source: sourceCG, context: context)
        }
        guard let output = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: output).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    private static func draw(_ annotation: Annotation, source: CGImage, context: CGContext) {
        guard let first = annotation.points.first else { return }
        let last = annotation.points.last ?? first
        context.saveGState()
        context.setStrokeColor(annotation.color.nsColor.cgColor)
        context.setFillColor(annotation.color.nsColor.cgColor)
        context.setLineWidth(annotation.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        switch annotation.tool {
        case .pen, .marker:
            if annotation.tool == .marker { context.setBlendMode(.multiply) }
            context.beginPath()
            context.move(to: first)
            for point in annotation.points.dropFirst() { context.addLine(to: point) }
            context.strokePath()
        case .line:
            context.move(to: first); context.addLine(to: last); context.strokePath()
        case .arrow:
            let arrowStart = annotation.arrowAtStart == true ? last : first
            let arrowEnd = annotation.arrowAtStart == true ? first : last
            context.move(to: arrowStart); context.addLine(to: arrowEnd); context.strokePath()
            let angle = atan2(arrowEnd.y - arrowStart.y, arrowEnd.x - arrowStart.x)
            let length = max(12, annotation.lineWidth * 4)
            context.move(to: arrowEnd)
            context.addLine(to: CGPoint(x: arrowEnd.x - length * cos(angle - .pi / 6), y: arrowEnd.y - length * sin(angle - .pi / 6)))
            context.move(to: arrowEnd)
            context.addLine(to: CGPoint(x: arrowEnd.x - length * cos(angle + .pi / 6), y: arrowEnd.y - length * sin(angle + .pi / 6)))
            context.strokePath()
        case .rectangle, .blackout:
            let rect = rect(first, last)
            if annotation.tool == .blackout { context.setFillColor(NSColor.black.cgColor); context.fill(rect) }
            else {
                if let fill = annotation.fillColor {
                    context.setFillColor(fill.nsColor.cgColor)
                    context.fill(rect)
                }
                context.stroke(rect)
            }
        case .ellipse:
            if let fill = annotation.fillColor {
                context.setFillColor(fill.nsColor.cgColor)
                context.fillEllipse(in: rect(first, last))
            }
            context.strokeEllipse(in: rect(first, last))
        case .mosaic:
            let region = rect(first, last).integral
            if let cropped = source.cropping(to: region),
               let filter = CIFilter(name: "CIPixellate") {
                filter.setValue(CIImage(cgImage: cropped), forKey: kCIInputImageKey)
                filter.setValue(max(8, annotation.lineWidth * 3), forKey: kCIInputScaleKey)
                let ciContext = CIContext()
                if let output = filter.outputImage,
                   let image = ciContext.createCGImage(output, from: output.extent) {
                    context.draw(image, in: region)
                }
            }
        case .text:
            let string = NSAttributedString(
                string: annotation.text ?? "",
                attributes: [.font: NSFont(name: annotation.fontName ?? "", size: annotation.fontSize)
                                ?? NSFont.systemFont(ofSize: annotation.fontSize, weight: .semibold),
                             .foregroundColor: annotation.color.nsColor]
            )
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            let size = string.size()
            let x = AnnotationTextLayout.originX(
                anchorX: first.x,
                textWidth: size.width,
                alignment: annotation.textAlignment ?? .left
            )
            string.draw(
                in: CGRect(
                    x: x, y: first.y,
                    width: max(1, size.width + 2),
                    height: max(annotation.fontSize * 1.4, size.height + 2)
                )
            )
            NSGraphicsContext.restoreGraphicsState()
        case .select, .crop:
            break
        }
        context.restoreGState()
    }

    private static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
