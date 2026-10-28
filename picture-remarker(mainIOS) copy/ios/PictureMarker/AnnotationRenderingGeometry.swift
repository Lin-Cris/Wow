import CoreGraphics

enum AnnotationRenderingGeometry {
    static let arrowHeadAngle = CGFloat.pi / 7
    private static let referenceImageLongEdge: CGFloat = 360
    private static let strokeWidthScale: CGFloat = 2.0 / 3.0

    static func lineWidth(
        for strokeWidth: AnnotationStrokeWidth,
        imageSize: CGSize
    ) -> CGFloat {
        let imageLongEdge = max(imageSize.width, imageSize.height)
        guard imageLongEdge > 0 else {
            return strokeWidth.value * strokeWidthScale
        }

        return strokeWidth.value *
            strokeWidthScale *
            imageLongEdge /
            referenceImageLongEdge
    }

    static func arrowHeadLength(
        for annotation: Annotation,
        imageSize: CGSize
    ) -> CGFloat {
        let arrowLength = hypot(
            annotation.endX - annotation.startX,
            annotation.endY - annotation.startY
        )
        let maximumHeadLength = max(imageSize.width, imageSize.height) * 0.04
        let minimumHeadLength = lineWidth(
            for: annotation.strokeWidth,
            imageSize: imageSize
        ) * 4

        return max(
            minimumHeadLength,
            min(arrowLength * 0.2, maximumHeadLength)
        )
    }

    static func arrowHeadPoints(
        start: CGPoint,
        end: CGPoint,
        headLength: CGFloat
    ) -> (first: CGPoint, second: CGPoint)? {
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        guard hypot(deltaX, deltaY) > 0 else {
            return nil
        }

        let angle = atan2(deltaY, deltaX)
        return (
            CGPoint(
                x: end.x - headLength * cos(angle - arrowHeadAngle),
                y: end.y - headLength * sin(angle - arrowHeadAngle)
            ),
            CGPoint(
                x: end.x - headLength * cos(angle + arrowHeadAngle),
                y: end.y - headLength * sin(angle + arrowHeadAngle)
            )
        )
    }
}
