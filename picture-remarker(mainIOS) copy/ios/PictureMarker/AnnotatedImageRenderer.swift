import ImageIO
import UIKit
import UniformTypeIdentifiers

enum AnnotatedImageRenderer {
    private static let exportPreviewMaxPixelSize = 1_600

    private enum EditableRenderElement {
        case annotation(Annotation)
        case overlayImage(OverlayImageLayer)

        var layerOrder: Int {
            switch self {
            case let .annotation(annotation):
                annotation.layerOrder
            case let .overlayImage(overlayImage):
                overlayImage.layerOrder
            }
        }

        var stableID: String {
            switch self {
            case let .annotation(annotation):
                "annotation-\(annotation.id.uuidString)"
            case let .overlayImage(overlayImage):
                "overlay-\(overlayImage.id.uuidString)"
            }
        }
    }

    struct LayeredMosaicImages {
        let byAnnotationID: [UUID: [MosaicPixelSize: UIImage]]
        let topComposite: [MosaicPixelSize: UIImage]
    }

    static func render(
        imageAsset: EditableImageAsset,
        annotations: [Annotation],
        overlayImages: [OverlayImageLayer]
    ) -> ExportedImageArtifact? {
        guard !Task.isCancelled else { return nil }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Picture-Marker-Export-\(UUID().uuidString)")
            .appendingPathExtension("png")
        let imageSize = imageAsset.originalImageSize

        let didWriteImage = autoreleasepool {
            guard !Task.isCancelled,
                  let sourceImage = UIImage(
                    contentsOfFile: imageAsset.originalFileURL.path
                  ) else {
                return false
            }

            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = false

            let renderer = UIGraphicsImageRenderer(
                size: imageSize,
                format: format
            )
            let layeredMosaicImages =
                makeLayeredMosaicImages(
                    sourceImage: sourceImage,
                    imageSize: imageSize,
                    overlayImages: overlayImages,
                    annotations: annotations,
                    overlayImageProvider: { overlayImage in
                        UIImage(
                            contentsOfFile:
                                overlayImage.imageAsset.originalFileURL.path
                        )
                    }
                )
            let renderedImage = renderer.image { rendererContext in
                sourceImage.draw(
                    in: CGRect(origin: .zero, size: imageSize)
                )
                drawEditableElements(
                    annotations,
                    overlayImages: overlayImages,
                    mosaicLayerImages: layeredMosaicImages.byAnnotationID,
                    imageSize: imageSize,
                    in: rendererContext.cgContext
                )
            }

            guard !Task.isCancelled,
                  let renderedCGImage = renderedImage.cgImage,
                  let destination = CGImageDestinationCreateWithURL(
                    outputURL as CFURL,
                    UTType.png.identifier as CFString,
                    1,
                    nil
                  ) else {
                return false
            }

            CGImageDestinationAddImage(
                destination,
                renderedCGImage,
                nil
            )
            return CGImageDestinationFinalize(destination)
        }

        guard didWriteImage, !Task.isCancelled,
              let previewImage = ImageAssetLoader.downsample(
                fileURL: outputURL,
                maxPixelSize: exportPreviewMaxPixelSize
              ) else {
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        }

        return ExportedImageArtifact(
            fileURL: outputURL,
            previewImage: previewImage,
            pixelSize: imageSize
        )
    }

    static func makeLayeredMosaicImages(
        sourceImage: UIImage,
        imageSize: CGSize,
        overlayImages: [OverlayImageLayer],
        annotations: [Annotation],
        overlayImageProvider: (OverlayImageLayer) -> UIImage?
    ) -> LayeredMosaicImages {
        let annotationElements = annotations.map {
            EditableRenderElement.annotation($0)
        }
        let overlayElements = overlayImages.map {
            EditableRenderElement.overlayImage($0)
        }
        let elements = (annotationElements + overlayElements).sorted {
            if $0.layerOrder == $1.layerOrder {
                return $0.stableID < $1.stableID
            }
            return $0.layerOrder < $1.layerOrder
        }

        var currentImage = sourceImage
        var mosaicImages: [UUID: [MosaicPixelSize: UIImage]] = [:]

        for element in elements {
            guard !Task.isCancelled else { break }

            switch element {
            case let .annotation(annotation):
                if annotation.type == .mosaic {
                    let strokes = annotation.mosaicStrokes.filter {
                        $0.target == .compositedCanvas
                    }
                    let requiredSizes = Set(strokes.map(\.pixelSize))
                    let pixelatedImages = Dictionary(
                        uniqueKeysWithValues: requiredSizes.compactMap { size in
                            MosaicPixelation.lowResolutionImage(
                                from: currentImage,
                                originalImageSize: imageSize,
                                pixelSize: size
                            ).map { (size, $0) }
                        }
                    )
                    mosaicImages[annotation.id] = pixelatedImages

                    let source = currentImage
                    currentImage = composite(
                        over: source,
                        imageSize: imageSize
                    ) { context in
                        drawMosaicStrokes(
                            strokes,
                            sourceImage: source,
                            sourceImageSize: imageSize,
                            destinationRect: CGRect(
                                origin: .zero,
                                size: imageSize
                            ),
                            precomputedPixelatedImages: pixelatedImages,
                            in: context
                        )
                    }
                } else {
                    currentImage = composite(
                        over: currentImage,
                        imageSize: imageSize
                    ) { context in
                        drawAnnotation(
                            annotation,
                            imageSize: imageSize,
                            in: context
                        )
                    }
                }

            case let .overlayImage(overlayImage):
                guard let overlaySource = overlayImageProvider(overlayImage) else {
                    continue
                }
                currentImage = composite(
                    over: currentImage,
                    imageSize: imageSize
                ) { context in
                    drawOverlayImage(
                        overlayImage,
                        sourceImage: overlaySource,
                        annotations: annotations,
                        in: context
                    )
                }
            }
        }

        let topComposite = Dictionary(
            uniqueKeysWithValues: MosaicPixelSize.allCases.compactMap { size in
                MosaicPixelation.lowResolutionImage(
                    from: currentImage,
                    originalImageSize: imageSize,
                    pixelSize: size
                ).map { (size, $0) }
            }
        )
        return LayeredMosaicImages(
            byAnnotationID: mosaicImages,
            topComposite: topComposite
        )
    }

    private static func composite(
        over sourceImage: UIImage,
        imageSize: CGSize,
        drawing: (CGContext) -> Void
    ) -> UIImage {
        let canvasSize = sourceImage.size
        guard canvasSize.width > 0, canvasSize.height > 0,
              imageSize.width > 0, imageSize.height > 0 else {
            return sourceImage
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: canvasSize, format: format).image {
            rendererContext in
            sourceImage.draw(in: CGRect(origin: .zero, size: canvasSize))
            let context = rendererContext.cgContext
            context.saveGState()
            context.scaleBy(
                x: canvasSize.width / imageSize.width,
                y: canvasSize.height / imageSize.height
            )
            drawing(context)
            context.restoreGState()
        }
    }

    private static func drawEditableElements(
        _ annotations: [Annotation],
        overlayImages: [OverlayImageLayer],
        mosaicLayerImages: [UUID: [MosaicPixelSize: UIImage]],
        imageSize: CGSize,
        in context: CGContext
    ) {
        let annotationElements = annotations.map { annotation in
            EditableRenderElement.annotation(annotation)
        }
        let overlayElements = overlayImages.map {
            EditableRenderElement.overlayImage($0)
        }
        let elements = (annotationElements + overlayElements).sorted {
            if $0.layerOrder == $1.layerOrder {
                return $0.stableID < $1.stableID
            }
            return $0.layerOrder < $1.layerOrder
        }

        for element in elements {
            guard !Task.isCancelled else { return }

            switch element {
            case let .annotation(annotation):
                if annotation.type == .mosaic {
                    drawMosaicStrokes(
                        annotation.mosaicStrokes.filter {
                            $0.target == .compositedCanvas
                        },
                        sourceImage: nil,
                        sourceImageSize: imageSize,
                        destinationRect: CGRect(origin: .zero, size: imageSize),
                        precomputedPixelatedImages:
                            mosaicLayerImages[annotation.id] ?? [:],
                        in: context
                    )
                } else {
                    drawAnnotation(
                        annotation,
                        imageSize: imageSize,
                        in: context
                    )
                }

            case let .overlayImage(overlayImage):
                drawOverlayImage(
                    overlayImage,
                    annotations: annotations,
                    in: context
                )
            }
        }
    }

    private static func drawOverlayImage(
        _ overlayImage: OverlayImageLayer,
        annotations: [Annotation],
        in context: CGContext
    ) {
        guard !Task.isCancelled,
              let sourceImage = UIImage(
                contentsOfFile: overlayImage.imageAsset.originalFileURL.path
              ) else {
            return
        }

        drawOverlayImage(
            overlayImage,
            sourceImage: sourceImage,
            annotations: annotations,
            in: context
        )
    }

    private static func drawOverlayImage(
        _ overlayImage: OverlayImageLayer,
        sourceImage: UIImage,
        annotations: [Annotation],
        in context: CGContext
    ) {

        context.saveGState()
        context.translateBy(
            x: overlayImage.centerX,
            y: overlayImage.centerY
        )
        context.rotate(by: overlayImage.rotation)
        sourceImage.draw(
            in: CGRect(
                x: -overlayImage.width / 2,
                y: -overlayImage.height / 2,
                width: overlayImage.width,
                height: overlayImage.height
            )
        )
        drawMosaics(
            annotations,
            target: .overlayImage(overlayImage.id),
            sourceImage: sourceImage,
            sourceImageSize: overlayImage.imageAsset.originalImageSize,
            destinationRect: CGRect(
                x: -overlayImage.width / 2,
                y: -overlayImage.height / 2,
                width: overlayImage.width,
                height: overlayImage.height
            ),
            in: context
        )
        context.restoreGState()
    }

    private static func drawAnnotation(
        _ annotation: Annotation,
        imageSize: CGSize,
        in context: CGContext
    ) {
        context.setLineCap(.round)
        context.setLineJoin(.round)
        guard !Task.isCancelled else { return }

        context.saveGState()
        context.setStrokeColor(uiColor(for: annotation.color).cgColor)
        context.setLineWidth(
            AnnotationRenderingGeometry.lineWidth(
                for: annotation.strokeWidth,
                imageSize: imageSize
            )
        )

        switch annotation.type {
        case .rectangle:
            context.stroke(
                CGRect(
                    x: annotation.x,
                    y: annotation.y,
                    width: annotation.width,
                    height: annotation.height
                )
            )

        case .line:
            context.beginPath()
            context.move(
                to: CGPoint(x: annotation.startX, y: annotation.startY)
            )
            context.addLine(
                to: CGPoint(x: annotation.endX, y: annotation.endY)
            )
            context.strokePath()

        case .arrow:
            drawArrow(
                annotation,
                imageSize: imageSize,
                in: context
            )

        case .ellipse:
            context.strokeEllipse(
                in: CGRect(
                    x: annotation.x,
                    y: annotation.y,
                    width: annotation.width,
                    height: annotation.height
                )
            )

        case .mosaic:
            break
        }

        context.restoreGState()
    }

    private static func drawMosaics(
        _ annotations: [Annotation],
        target: MosaicTarget,
        sourceImage: UIImage,
        sourceImageSize: CGSize,
        destinationRect: CGRect,
        precomputedPixelatedImages: [MosaicPixelSize: UIImage] = [:],
        in context: CGContext
    ) {
        let strokes = annotations.flatMap { annotation in
            annotation.type == .mosaic ? annotation.mosaicStrokes : []
        }.filter { $0.target == target }
        drawMosaicStrokes(
            strokes,
            sourceImage: sourceImage,
            sourceImageSize: sourceImageSize,
            destinationRect: destinationRect,
            precomputedPixelatedImages: precomputedPixelatedImages,
            in: context
        )
    }

    private static func drawMosaicStrokes(
        _ strokes: [MosaicStroke],
        sourceImage: UIImage?,
        sourceImageSize: CGSize,
        destinationRect: CGRect,
        precomputedPixelatedImages: [MosaicPixelSize: UIImage] = [:],
        in context: CGContext
    ) {
        guard !strokes.isEmpty else { return }
        guard sourceImageSize.width > 0, sourceImageSize.height > 0 else { return }

        let horizontalScale = destinationRect.width / sourceImageSize.width
        let verticalScale = destinationRect.height / sourceImageSize.height
        let brushScale = (abs(horizontalScale) + abs(verticalScale)) / 2

        var pixelatedImages = precomputedPixelatedImages

        for stroke in strokes {
            guard !Task.isCancelled, !stroke.points.isEmpty else { continue }

            let pixelatedImage: UIImage
            if let cachedImage = pixelatedImages[stroke.pixelSize] {
                pixelatedImage = cachedImage
            } else if let sourceImage,
                      let generatedImage = MosaicPixelation.lowResolutionImage(
                from: sourceImage,
                originalImageSize: sourceImageSize,
                pixelSize: stroke.pixelSize
            ) {
                pixelatedImages[stroke.pixelSize] = generatedImage
                pixelatedImage = generatedImage
            } else {
                continue
            }

            context.saveGState()
            context.clip(to: destinationRect)

            if stroke.points.count == 1, let point = stroke.points.first {
                let mappedPoint = CGPoint(
                    x: destinationRect.minX + point.x * horizontalScale,
                    y: destinationRect.minY + point.y * verticalScale
                )
                let brushSize = stroke.brushSize * brushScale
                context.addEllipse(
                    in: CGRect(
                        x: mappedPoint.x - brushSize / 2,
                        y: mappedPoint.y - brushSize / 2,
                        width: brushSize,
                        height: brushSize
                    )
                )
                context.clip()
            } else if let firstPoint = stroke.points.first {
                context.beginPath()
                context.move(
                    to: CGPoint(
                        x: destinationRect.minX + firstPoint.x * horizontalScale,
                        y: destinationRect.minY + firstPoint.y * verticalScale
                    )
                )

                for point in stroke.points.dropFirst() {
                    context.addLine(
                        to: CGPoint(
                            x: destinationRect.minX + point.x * horizontalScale,
                            y: destinationRect.minY + point.y * verticalScale
                        )
                    )
                }

                context.setLineWidth(stroke.brushSize * brushScale)
                context.setLineCap(.round)
                context.setLineJoin(.round)
                context.replacePathWithStrokedPath()
                context.clip()
            }

            context.interpolationQuality = .none
            pixelatedImage.draw(
                in: destinationRect
            )
            context.restoreGState()
        }
    }

    private static func drawArrow(
        _ annotation: Annotation,
        imageSize: CGSize,
        in context: CGContext
    ) {
        let start = CGPoint(
            x: annotation.startX,
            y: annotation.startY
        )
        let end = CGPoint(
            x: annotation.endX,
            y: annotation.endY
        )
        let headLength = AnnotationRenderingGeometry.arrowHeadLength(
            for: annotation,
            imageSize: imageSize
        )

        guard let headPoints = AnnotationRenderingGeometry.arrowHeadPoints(
            start: start,
            end: end,
            headLength: headLength
        ) else {
            return
        }

        context.beginPath()
        context.move(to: start)
        context.addLine(to: end)
        context.move(to: end)
        context.addLine(to: headPoints.first)
        context.move(to: end)
        context.addLine(to: headPoints.second)
        context.strokePath()
    }

    private static func uiColor(for color: AnnotationColor) -> UIColor {
        switch color {
        case .red: .systemRed
        case .yellow: .systemYellow
        case .blue: .systemBlue
        case .green: .systemGreen
        case .white: .white
        }
    }
}
