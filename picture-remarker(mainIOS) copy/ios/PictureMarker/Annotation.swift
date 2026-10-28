import SwiftUI

enum AnnotationType: String {
    case rectangle
    case line
    case arrow
    case ellipse
    case mosaic
}

enum MosaicPixelSize: String, CaseIterable, Identifiable {
    case small
    case medium
    case large

    var id: Self { self }

    var shortTitle: String {
        switch self {
        case .small: "S"
        case .medium: "M"
        case .large: "L"
        }
    }

    func blockSize(for imageSize: CGSize) -> CGFloat {
        let shortEdge = min(imageSize.width, imageSize.height)
        let ratio: CGFloat

        switch self {
        case .small: ratio = 0.016
        case .medium: ratio = 0.03
        case .large: ratio = 0.055
        }

        return min(max(shortEdge * ratio, 10), 240)
    }
}

enum MosaicTarget: Equatable {
    case baseImage
    case overlayImage(UUID)
    case compositedCanvas
}

struct MosaicStroke: Identifiable {
    let id: UUID
    var points: [CGPoint]
    var brushSize: CGFloat
    var pixelSize: MosaicPixelSize
    var target: MosaicTarget

    init(
        id: UUID = UUID(),
        points: [CGPoint],
        brushSize: CGFloat,
        pixelSize: MosaicPixelSize,
        target: MosaicTarget = .compositedCanvas
    ) {
        self.id = id
        self.points = points
        self.brushSize = brushSize
        self.pixelSize = pixelSize
        self.target = target
    }
}

enum AnnotationColor: String, CaseIterable, Identifiable {
    case red
    case yellow
    case blue
    case green
    case white

    var id: Self { self }

    var swiftUIColor: Color {
        switch self {
        case .red: .red
        case .yellow: .yellow
        case .blue: .blue
        case .green: .green
        case .white: .white
        }
    }
}

enum AnnotationStrokeWidth: String, CaseIterable, Identifiable {
    case thin
    case medium
    case thick

    var id: Self { self }

    var value: CGFloat {
        switch self {
        case .thin: 2
        case .medium: 4
        case .thick: 7
        }
    }
}

struct Annotation: Identifiable {
    let id: UUID
    let type: AnnotationType
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
    var startX: CGFloat
    var startY: CGFloat
    var endX: CGFloat
    var endY: CGFloat
    var color: AnnotationColor
    var strokeWidth: AnnotationStrokeWidth
    var note: String
    var mosaicStrokes: [MosaicStroke]
    var layerOrder: Int

    init(
        id: UUID = UUID(),
        type: AnnotationType = .rectangle,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
        color: AnnotationColor = .red,
        strokeWidth: AnnotationStrokeWidth = .medium,
        note: String = "",
        layerOrder: Int = 0
    ) {
        self.id = id
        self.type = type
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.startX = 0
        self.startY = 0
        self.endX = 0
        self.endY = 0
        self.color = color
        self.strokeWidth = strokeWidth
        self.note = note
        self.mosaicStrokes = []
        self.layerOrder = layerOrder
    }

    init(
        id: UUID = UUID(),
        type: AnnotationType = .arrow,
        startX: CGFloat,
        startY: CGFloat,
        endX: CGFloat,
        endY: CGFloat,
        color: AnnotationColor = .red,
        strokeWidth: AnnotationStrokeWidth = .medium,
        note: String = "",
        layerOrder: Int = 0
    ) {
        self.id = id
        self.type = type
        self.x = 0
        self.y = 0
        self.width = 0
        self.height = 0
        self.startX = startX
        self.startY = startY
        self.endX = endX
        self.endY = endY
        self.color = color
        self.strokeWidth = strokeWidth
        self.note = note
        self.mosaicStrokes = []
        self.layerOrder = layerOrder
    }

    init(
        id: UUID = UUID(),
        mosaicStrokes: [MosaicStroke],
        layerOrder: Int = 0
    ) {
        self.id = id
        self.type = .mosaic
        self.x = 0
        self.y = 0
        self.width = 0
        self.height = 0
        self.startX = 0
        self.startY = 0
        self.endX = 0
        self.endY = 0
        self.color = .red
        self.strokeWidth = .medium
        self.note = ""
        self.mosaicStrokes = mosaicStrokes
        self.layerOrder = layerOrder
    }
}
