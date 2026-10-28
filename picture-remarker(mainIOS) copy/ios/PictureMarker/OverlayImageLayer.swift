import CoreGraphics
import Foundation

struct OverlayImageLayer: Identifiable {
    let id: UUID
    let imageAsset: EditableImageAsset
    var centerX: CGFloat
    var centerY: CGFloat
    var width: CGFloat
    var height: CGFloat
    var rotation: CGFloat
    var layerOrder: Int

    init(
        id: UUID = UUID(),
        imageAsset: EditableImageAsset,
        centerX: CGFloat,
        centerY: CGFloat,
        width: CGFloat,
        height: CGFloat,
        rotation: CGFloat = 0,
        layerOrder: Int = 0
    ) {
        self.id = id
        self.imageAsset = imageAsset
        self.centerX = centerX
        self.centerY = centerY
        self.width = width
        self.height = height
        self.rotation = rotation
        self.layerOrder = layerOrder
    }

    func localImagePoint(from canvasPoint: CGPoint) -> CGPoint? {
        let imageSize = imageAsset.originalImageSize
        guard width > 0, height > 0,
              imageSize.width > 0, imageSize.height > 0 else {
            return nil
        }

        let deltaX = canvasPoint.x - centerX
        let deltaY = canvasPoint.y - centerY
        let cosine = cos(rotation)
        let sine = sin(rotation)
        let unrotatedX = deltaX * cosine + deltaY * sine
        let unrotatedY = -deltaX * sine + deltaY * cosine

        return CGPoint(
            x: (unrotatedX / width + 0.5) * imageSize.width,
            y: (unrotatedY / height + 0.5) * imageSize.height
        )
    }

    func contains(localImagePoint point: CGPoint) -> Bool {
        let imageSize = imageAsset.originalImageSize
        return point.x >= 0 &&
            point.y >= 0 &&
            point.x <= imageSize.width &&
            point.y <= imageSize.height
    }

    func displayScale(in canvasScale: CGFloat) -> CGFloat {
        let imageSize = imageAsset.originalImageSize
        guard imageSize.width > 0, imageSize.height > 0 else { return 0 }

        let horizontalScale = width * canvasScale / imageSize.width
        let verticalScale = height * canvasScale / imageSize.height
        return (abs(horizontalScale) + abs(verticalScale)) / 2
    }
}
