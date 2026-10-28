import SwiftUI
import UIKit

/// Zooms the complete editing surface without changing original-image coordinates.
private struct ZoomableImageCanvas<Content: View>: UIViewControllerRepresentable {
    let imageID: ObjectIdentifier
    let resetID: Int
    let onScaleChange: (CGFloat) -> Void
    let onInteractionChange: (Bool) -> Void
    @ViewBuilder var content: () -> Content

    func makeUIViewController(context: Context) -> ImageCanvasZoomController<Content> {
        ImageCanvasZoomController(content: content())
    }

    func updateUIViewController(
        _ controller: ImageCanvasZoomController<Content>, context: Context
    ) {
        controller.onScaleChange = onScaleChange
        controller.onInteractionChange = onInteractionChange
        controller.host.rootView = content()
        if controller.imageID != imageID || controller.resetID != resetID {
            controller.imageID = imageID
            controller.resetID = resetID
            controller.resetZoom()
        }
    }
}

final class ImageCanvasScrollView: UIScrollView, UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // SwiftUI's one-finger drawing/rotation recognizers must not block viewport pinch.
        // A native pinch on an image layer still belongs to that layer.
        (gestureRecognizer === pinchGestureRecognizer || gestureRecognizer === panGestureRecognizer) &&
            !(otherGestureRecognizer is UIPinchGestureRecognizer)
    }
}

final class ImageCanvasZoomController<Content: View>: UIViewController, UIScrollViewDelegate {
    let scrollView = ImageCanvasScrollView()
    let host: UIHostingController<Content>
    var imageID: ObjectIdentifier?
    var resetID = 0
    var onScaleChange: (CGFloat) -> Void = { _ in }
    var onInteractionChange: (Bool) -> Void = { _ in }
    private var viewportSize = CGSize.zero

    init(content: Content) {
        host = UIHostingController(rootView: content)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        scrollView.backgroundColor = .clear
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 8
        scrollView.bouncesZoom = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.delaysContentTouches = false
        // Leave one finger available for drawing, moving and resizing annotations.
        scrollView.panGestureRecognizer.minimumNumberOfTouches = 2
        scrollView.pinchGestureRecognizer?.delegate = scrollView
        scrollView.accessibilityIdentifier = "picture.canvas"
        view.addSubview(scrollView)
        addChild(host)
        host.view.backgroundColor = .clear
        host.safeAreaRegions = []
        scrollView.addSubview(host.view)
        host.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scrollView.frame = view.bounds
        guard viewportSize != view.bounds.size else { return }
        viewportSize = view.bounds.size
        resetZoom()
        host.view.frame = CGRect(origin: .zero, size: viewportSize)
        scrollView.contentSize = viewportSize
    }

    func resetZoom() {
        scrollView.setZoomScale(1, animated: false)
        scrollView.setContentOffset(.zero, animated: false)
        reportScale()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { host.view }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { reportScale() }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        onInteractionChange(true)
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        if !scrollView.isDragging { onInteractionChange(false) }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        onInteractionChange(true)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate && !scrollView.isZooming { onInteractionChange(false) }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        if !scrollView.isZooming { onInteractionChange(false) }
    }

    private func reportScale() {
        let scale = scrollView.zoomScale
        // Delegate callbacks also occur during SwiftUI's update/layout pass.
        DispatchQueue.main.async { [weak self] in self?.onScaleChange(scale) }
    }
}

private struct AnnotationMoveState {
    let annotationID: UUID
    let originalAnnotation: Annotation
}

private enum AnnotationResizeHandle {
    case topLeft
    case bottomRight
}

private struct AnnotationResizeState {
    let annotationID: UUID
    let handle: AnnotationResizeHandle
    let originalX: CGFloat
    let originalY: CGFloat
    let originalWidth: CGFloat
    let originalHeight: CGFloat
}

private struct OverlayTransformState {
    let overlayID: UUID
    let initialWidth: CGFloat
    let initialHeight: CGFloat
    let initialRotation: CGFloat
    let initialPointerDistance: CGFloat
    var previousPointerAngle: CGFloat
    var accumulatedAngleDelta: CGFloat
}

private struct OverlayCompositeSignature: Equatable {
    let id: UUID
    let centerX: CGFloat
    let centerY: CGFloat
    let width: CGFloat
    let height: CGFloat
    let rotation: CGFloat

    init(_ layer: OverlayImageLayer) {
        id = layer.id
        centerX = layer.centerX
        centerY = layer.centerY
        width = layer.width
        height = layer.height
        rotation = layer.rotation
    }
}

private struct MosaicStrokeCompositeSignature: Equatable {
    let id: UUID
    let points: [CGPoint]
    let brushSize: CGFloat
    let pixelSize: MosaicPixelSize
    let target: MosaicTarget

    init(_ stroke: MosaicStroke) {
        id = stroke.id
        points = stroke.points
        brushSize = stroke.brushSize
        pixelSize = stroke.pixelSize
        target = stroke.target
    }
}

private struct AnnotationCompositeSignature: Equatable {
    let id: UUID
    let type: AnnotationType
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
    let startX: CGFloat
    let startY: CGFloat
    let endX: CGFloat
    let endY: CGFloat
    let color: AnnotationColor
    let strokeWidth: AnnotationStrokeWidth
    let mosaicStrokes: [MosaicStrokeCompositeSignature]
    let layerOrder: Int

    init(_ annotation: Annotation) {
        id = annotation.id
        type = annotation.type
        x = annotation.x
        y = annotation.y
        width = annotation.width
        height = annotation.height
        startX = annotation.startX
        startY = annotation.startY
        endX = annotation.endX
        endY = annotation.endY
        color = annotation.color
        strokeWidth = annotation.strokeWidth
        mosaicStrokes = annotation.mosaicStrokes.map(
            MosaicStrokeCompositeSignature.init
        )
        layerOrder = annotation.layerOrder
    }
}

private enum EditableCanvasElementID: Hashable {
    case annotation(UUID)
    case overlayImage(UUID)
}

private struct EditableCanvasElement: Identifiable {
    let id: EditableCanvasElementID
    let layerOrder: Int
}

private let minimumAnnotationDisplaySize: CGFloat = 12
private let resizeHandleDisplaySize: CGFloat = 16
private let resizeHandleTouchSize: CGFloat = 44
private let minimumDisplaySizeForTwoResizeHandles: CGFloat = 60
private let annotationMoveActivationDistance: CGFloat = 10
private let minimumOverlayInteractionSize: CGFloat = 60
let minimumOverlayDisplayShortEdge: CGFloat = 14
private let overlaySelectionPadding: CGFloat = 4
private let overlayTransformHandleDisplaySize: CGFloat = 30
private let overlayTransformHandleTouchSize: CGFloat = 44
private let overlayTransformHandleOffset: CGFloat = 10
private let shapeHitPadding: CGFloat = 14

private struct RectangleOutlineHitShape: Shape {
    let hitWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        let width = min(hitWidth, min(rect.width, rect.height) / 2)
        var path = Path()
        path.addRect(CGRect(x: 0, y: 0, width: rect.width, height: width))
        path.addRect(
            CGRect(
                x: 0,
                y: rect.height - width,
                width: rect.width,
                height: width
            )
        )
        path.addRect(CGRect(x: 0, y: width, width: width, height: rect.height - width * 2))
        path.addRect(
            CGRect(
                x: rect.width - width,
                y: width,
                width: width,
                height: rect.height - width * 2
            )
        )
        return path
    }
}

private struct EllipseOutlineHitShape: Shape {
    let hitWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outerRadiusX = rect.width / 2
        let outerRadiusY = rect.height / 2
        let innerRadiusX = max(outerRadiusX - hitWidth, 0)
        let innerRadiusY = max(outerRadiusY - hitWidth, 0)
        let segmentCount = 64
        var path = Path()

        for index in 0..<segmentCount {
            let firstAngle = CGFloat(index) / CGFloat(segmentCount) * .pi * 2
            let secondAngle = CGFloat(index + 1) / CGFloat(segmentCount) * .pi * 2
            path.move(
                to: CGPoint(
                    x: center.x + cos(firstAngle) * outerRadiusX,
                    y: center.y + sin(firstAngle) * outerRadiusY
                )
            )
            path.addLine(
                to: CGPoint(
                    x: center.x + cos(secondAngle) * outerRadiusX,
                    y: center.y + sin(secondAngle) * outerRadiusY
                )
            )
            path.addLine(
                to: CGPoint(
                    x: center.x + cos(secondAngle) * innerRadiusX,
                    y: center.y + sin(secondAngle) * innerRadiusY
                )
            )
            path.addLine(
                to: CGPoint(
                    x: center.x + cos(firstAngle) * innerRadiusX,
                    y: center.y + sin(firstAngle) * innerRadiusY
                )
            )
            path.closeSubpath()
        }

        return path
    }
}

struct ImageCanvasGeometry {
    let originalImageSize: CGSize
    let displayImageSize: CGSize
    let scale: CGFloat
    let imageOrigin: CGPoint

    static func fitted(originalImageSize: CGSize, inside canvasSize: CGSize) -> ImageCanvasGeometry {
        guard originalImageSize.width > 0,
              originalImageSize.height > 0,
              canvasSize.width > 0,
              canvasSize.height > 0 else {
            return ImageCanvasGeometry(
                originalImageSize: originalImageSize,
                displayImageSize: .zero,
                scale: 0,
                imageOrigin: .zero
            )
        }

        let scale = min(
            canvasSize.width / originalImageSize.width,
            canvasSize.height / originalImageSize.height
        )
        let displayImageSize = CGSize(
            width: originalImageSize.width * scale,
            height: originalImageSize.height * scale
        )
        let imageOrigin = CGPoint(
            x: (canvasSize.width - displayImageSize.width) / 2,
            y: (canvasSize.height - displayImageSize.height) / 2
        )

        return ImageCanvasGeometry(
            originalImageSize: originalImageSize,
            displayImageSize: displayImageSize,
            scale: scale,
            imageOrigin: imageOrigin
        )
    }
}

struct ImageCanvasView: View {
    let image: UIImage
    let originalImageSize: CGSize
    @Binding var annotations: [Annotation]
    @Binding var overlayImages: [OverlayImageLayer]
    @Binding var pendingMosaicStrokes: [MosaicStroke]
    @Binding var nextLayerOrder: Int
    @Binding var selectedAnnotationID: UUID?
    @Binding var selectedOverlayImageID: UUID?
    let selectedTool: EditorTool
    let mosaicBrushSize: CGFloat
    let mosaicPixelSize: MosaicPixelSize
    let onEditAnnotation: (UUID) -> Void
    let onCommitMosaicStroke: (MosaicStroke) -> Void
    let onWillChange: () -> Void
    let overlayAccessibilityLabel: String
    let overlayAccessibilityHint: String
    @State private var imageRotation: Angle = .zero
    @State private var canvasZoomScale: CGFloat = 1
    @State private var zoomResetID = 0
    @State private var isNavigatingCanvas = false
    @AppStorage(AppLanguage.storageKey)
    private var languageRawValue = AppLanguage.defaultValue.rawValue
    @State private var draftAnnotation: Annotation?
    @State private var moveState: AnnotationMoveState?
    @State private var resizeState: AnnotationResizeState?
    @State private var overlayTransformState: OverlayTransformState?
    @State private var activeMosaicStrokeID: UUID?
    @State private var pixelatedPreviewImages: [MosaicPixelSize: UIImage] = [:]
    @State private var overlayPixelatedPreviewImages:
        [UUID: [MosaicPixelSize: UIImage]] = [:]
    @State private var compositedPixelatedPreviewImages:
        [MosaicPixelSize: UIImage] = [:]
    @State private var mosaicLayerPixelatedPreviewImages:
        [UUID: [MosaicPixelSize: UIImage]] = [:]

    var body: some View {
        GeometryReader { proxy in
            let geometry = ImageCanvasGeometry.fitted(
                originalImageSize: originalImageSize,
                inside: proxy.size
            )

            ZoomableImageCanvas(
                imageID: ObjectIdentifier(image),
                resetID: zoomResetID,
                onScaleChange: { canvasZoomScale = $0 },
                onInteractionChange: { active in
                    isNavigatingCanvas = active
                    if active {
                        draftAnnotation = nil
                        if let activeMosaicStrokeID {
                            pendingMosaicStrokes.removeAll { $0.id == activeMosaicStrokeID }
                        }
                        activeMosaicStrokeID = nil
                        moveState = nil
                        resizeState = nil
                        overlayTransformState = nil
                    }
                }
            ) {
                ZStack(alignment: .topLeading) {
                    Image(uiImage: image)
                        .resizable()
                        .frame(
                            width: geometry.displayImageSize.width,
                            height: geometry.displayImageSize.height
                        )
                        .contentShape(Rectangle())
                        .gesture(annotationCreationGesture(geometry: geometry))
                        .simultaneousGesture(
                            RotationGesture()
                                .onEnded { value in
                                    guard !isNavigatingCanvas, canvasZoomScale == 1,
                                          abs(value.degrees) >= 20 else { return }

                                    let rotationStep = value.degrees > 0 ? 90.0 : -90.0
                                    withAnimation(.easeInOut(duration: 0.25)) {
                                        imageRotation = .degrees(
                                            imageRotation.degrees + rotationStep
                                        )
                                    }
                                }
                        )
                        .rotationEffect(imageRotation)

                    baseMosaicLayer(scale: geometry.scale)

                    ForEach(orderedEditableElements) { element in
                        editableElementView(
                            element,
                            geometry: geometry
                        )
                    }

                    pendingMosaicLayer(scale: geometry.scale)

                    if let draftAnnotation {
                        annotationView(
                            draftAnnotation,
                            scale: geometry.scale,
                            isSelected: false
                        )
                            .opacity(0.7)
                    }

                    if selectedTool == .select {
                        ForEach(orderedEditableElements) { element in
                            editableElementHitArea(
                                element,
                                geometry: geometry
                            )
                        }

                        if let selectedAnnotation = annotations.first(
                            where: { $0.id == selectedAnnotationID }
                        ), selectedAnnotation.type == .rectangle ||
                            selectedAnnotation.type == .ellipse {
                            if shouldShowBothResizeHandles(
                                for: selectedAnnotation,
                                scale: geometry.scale
                            ) {
                                resizeHandle(
                                    for: selectedAnnotation,
                                    handle: .topLeft,
                                    scale: geometry.scale
                                )
                                .gesture(
                                    annotationResizeGesture(
                                        annotationID: selectedAnnotation.id,
                                        handle: .topLeft,
                                        geometry: geometry
                                    )
                                )
                            }

                            resizeHandle(
                                for: selectedAnnotation,
                                handle: .bottomRight,
                                scale: geometry.scale
                            )
                            .gesture(
                                annotationResizeGesture(
                                    annotationID: selectedAnnotation.id,
                                    handle: .bottomRight,
                                    geometry: geometry
                                )
                            )
                        }

                        if let selectedOverlay = overlayImages.first(
                            where: { $0.id == selectedOverlayImageID }
                        ) {
                            overlayTransformHandle(
                                for: selectedOverlay,
                                scale: geometry.scale
                            )
                            .gesture(
                                overlayTransformGesture(
                                    overlayID: selectedOverlay.id,
                                    geometry: geometry
                                )
                            )
                        }
                    }
                }
                .frame(
                    width: geometry.displayImageSize.width,
                    height: geometry.displayImageSize.height,
                    alignment: .topLeading
                )
                .coordinateSpace(name: "imageCanvas")
                .clipped()
                .position(
                    x: geometry.imageOrigin.x + geometry.displayImageSize.width / 2,
                    y: geometry.imageOrigin.y + geometry.displayImageSize.height / 2
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .overlay(alignment: .bottomTrailing) {
                Button {
                    zoomResetID += 1
                } label: {
                    Label("\(Int((canvasZoomScale * 100).rounded()))%", systemImage: "arrow.counterclockwise")
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppStrings(rawValue: languageRawValue).resetCanvasZoom)
                .accessibilityHint(AppStrings(rawValue: languageRawValue).canvasZoomHint)
                .accessibilityValue("\(Int((canvasZoomScale * 100).rounded()))%")
                .accessibilityIdentifier("picture.zoom.reset")
                .padding(8)
            }
            .clipped()
        }
        .onAppear {
            preparePixelatedPreviewImages()
            prepareOverlayPixelatedPreviewImages()
            prepareLayeredMosaicPreviewImages()
        }
        .onChange(of: overlayImages.map(OverlayCompositeSignature.init)) { _, _ in
            prepareOverlayPixelatedPreviewImages()
            prepareLayeredMosaicPreviewImages()
        }
        .onChange(of: annotations.map(AnnotationCompositeSignature.init)) { _, _ in
            prepareLayeredMosaicPreviewImages()
        }
        .onChange(of: selectedTool) { _, newTool in
            activeMosaicStrokeID = nil
            if newTool == .mosaic {
                prepareLayeredMosaicPreviewImages()
            }
            if newTool != .select {
                selectedAnnotationID = nil
                selectedOverlayImageID = nil
            }
        }
    }

    private var orderedEditableElements: [EditableCanvasElement] {
        let annotationElements = annotations.map { annotation in
            EditableCanvasElement(
                id: .annotation(annotation.id),
                layerOrder: annotation.layerOrder
            )
        }
        let overlayElements = overlayImages.map { overlayImage in
            EditableCanvasElement(
                id: .overlayImage(overlayImage.id),
                layerOrder: overlayImage.layerOrder
            )
        }

        return (annotationElements + overlayElements).sorted {
            if $0.layerOrder == $1.layerOrder {
                return String(describing: $0.id) < String(describing: $1.id)
            }
            return $0.layerOrder < $1.layerOrder
        }
    }

    @ViewBuilder
    private func editableElementView(
        _ element: EditableCanvasElement,
        geometry: ImageCanvasGeometry
    ) -> some View {
        switch element.id {
        case let .annotation(id):
            if let annotation = annotations.first(where: { $0.id == id }) {
                annotationView(
                    annotation,
                    scale: geometry.scale,
                    isSelected: annotation.id == selectedAnnotationID
                )
            }

        case let .overlayImage(id):
            if let index = overlayImages.firstIndex(where: { $0.id == id }) {
                let overlayImage = overlayImages[index]

                overlayImageVisual(
                    layer: $overlayImages[index],
                    scale: geometry.scale,
                    isSelected: overlayImage.id == selectedOverlayImageID
                )
                .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func editableElementHitArea(
        _ element: EditableCanvasElement,
        geometry: ImageCanvasGeometry
    ) -> some View {
        switch element.id {
        case let .annotation(id):
            if let annotation = annotations.first(where: { $0.id == id }) {
                annotationHitArea(annotation, geometry: geometry)
            }

        case let .overlayImage(id):
            if let index = overlayImages.firstIndex(where: { $0.id == id }) {
                overlayGestureTarget(
                    layer: $overlayImages[index],
                    scale: geometry.scale,
                    usesExpandedHitArea: true
                )
            }
        }
    }

    @ViewBuilder
    private func baseMosaicLayer(scale: CGFloat) -> some View {
        let strokes = mosaicStrokes(for: .baseImage)

        ForEach(strokes) { stroke in
            if let pixelatedImage = pixelatedPreviewImages[stroke.pixelSize] {
                Image(uiImage: pixelatedImage)
                    .resizable()
                    .interpolation(.none)
                    .frame(
                        width: originalImageSize.width * scale,
                        height: originalImageSize.height * scale
                    )
                    .mask {
                        MosaicStrokeMask(
                            stroke: stroke,
                            horizontalScale: scale,
                            verticalScale: scale
                        )
                    }
                    .allowsHitTesting(false)
            }
        }
    }

    private func preparePixelatedPreviewImages() {
        guard pixelatedPreviewImages.isEmpty else { return }

        pixelatedPreviewImages = Dictionary(
            uniqueKeysWithValues: MosaicPixelSize.allCases.compactMap { size in
                guard let image = MosaicPixelation.lowResolutionImage(
                    from: image,
                    originalImageSize: originalImageSize,
                    pixelSize: size
                ) else {
                    return nil
                }

                return (size, image)
            }
        )
    }

    private func prepareOverlayPixelatedPreviewImages() {
        let activeIDs = Set(overlayImages.map(\.id))
        overlayPixelatedPreviewImages = overlayPixelatedPreviewImages.filter {
            activeIDs.contains($0.key)
        }

        for overlayImage in overlayImages
        where overlayPixelatedPreviewImages[overlayImage.id] == nil {
            let images: [MosaicPixelSize: UIImage] = Dictionary(
                uniqueKeysWithValues: MosaicPixelSize.allCases.compactMap { size in
                    guard let image = MosaicPixelation.lowResolutionImage(
                        from: overlayImage.imageAsset.previewImage,
                        originalImageSize: overlayImage.imageAsset.originalImageSize,
                        pixelSize: size
                    ) else {
                        return nil
                    }

                    return (size, image)
                }
            )
            overlayPixelatedPreviewImages[overlayImage.id] = images
        }
    }

    @ViewBuilder
    private func pendingMosaicLayer(scale: CGFloat) -> some View {
        let strokes = pendingMosaicStrokes.filter {
            $0.target == .compositedCanvas
        }

        ForEach(strokes) { stroke in
            if let pixelatedImage =
                compositedPixelatedPreviewImages[stroke.pixelSize] {
                Image(uiImage: pixelatedImage)
                    .resizable()
                    .interpolation(.none)
                    .frame(
                        width: originalImageSize.width * scale,
                        height: originalImageSize.height * scale
                    )
                    .mask {
                        MosaicStrokeMask(
                            stroke: stroke,
                            horizontalScale: scale,
                            verticalScale: scale
                        )
                    }
                    .allowsHitTesting(false)
            }
        }
    }

    private func prepareLayeredMosaicPreviewImages() {
        guard selectedTool == .mosaic || annotations.contains(where: {
            $0.type == .mosaic
        }) else {
            mosaicLayerPixelatedPreviewImages = [:]
            compositedPixelatedPreviewImages = [:]
            return
        }

        let images = AnnotatedImageRenderer.makeLayeredMosaicImages(
            sourceImage: image,
            imageSize: originalImageSize,
            overlayImages: overlayImages,
            annotations: annotations,
            overlayImageProvider: {
                $0.imageAsset.previewImage
            }
        )
        mosaicLayerPixelatedPreviewImages = images.byAnnotationID
        compositedPixelatedPreviewImages = images.topComposite
    }

    private func mosaicStrokes(for target: MosaicTarget) -> [MosaicStroke] {
        let committedStrokes = annotations.flatMap { annotation in
            annotation.type == .mosaic ? annotation.mosaicStrokes : []
        }
        return (committedStrokes + pendingMosaicStrokes).filter {
            $0.target == target
        }
    }

    private func overlayImageVisual(
        layer: Binding<OverlayImageLayer>,
        scale: CGFloat,
        isSelected: Bool
    ) -> some View {
        let overlayImage = layer.wrappedValue
        let sourceSize = overlayImage.imageAsset.originalImageSize
        let horizontalScale = overlayImage.width * scale / sourceSize.width
        let verticalScale = overlayImage.height * scale / sourceSize.height
        let strokes = mosaicStrokes(for: .overlayImage(overlayImage.id))

        return ZStack {
            Image(uiImage: overlayImage.imageAsset.previewImage)
                .resizable()

            ForEach(strokes) { stroke in
                if let pixelatedImage =
                    overlayPixelatedPreviewImages[overlayImage.id]?[stroke.pixelSize] {
                    Image(uiImage: pixelatedImage)
                        .resizable()
                        .interpolation(.none)
                        .mask {
                            MosaicStrokeMask(
                                stroke: stroke,
                                horizontalScale: horizontalScale,
                                verticalScale: verticalScale
                            )
                        }
                        .allowsHitTesting(false)
                }
            }
        }
            .frame(
                width: overlayImage.width * scale,
                height: overlayImage.height * scale
            )
            .overlay {
                if isSelected {
                    Rectangle()
                        .stroke(
                            AppTheme.accent,
                            style: StrokeStyle(
                                lineWidth: 2,
                                dash: [6, 4]
                            )
                        )
                        .frame(
                            width: overlayImage.width * scale +
                                overlaySelectionPadding * 2,
                            height: overlayImage.height * scale +
                                overlaySelectionPadding * 2
                        )
                        .allowsHitTesting(false)
                }
            }
            .rotationEffect(.radians(overlayImage.rotation))
            .position(
                x: overlayImage.centerX * scale,
                y: overlayImage.centerY * scale
            )
            .allowsHitTesting(false)
    }

    private func overlayGestureTarget(
        layer: Binding<OverlayImageLayer>,
        scale: CGFloat,
        usesExpandedHitArea: Bool
    ) -> some View {
        let overlayImage = layer.wrappedValue
        let displayedWidth = overlayImage.width * scale
        let displayedHeight = overlayImage.height * scale
        let targetWidth = usesExpandedHitArea
            ? max(displayedWidth, minimumOverlayInteractionSize)
            : displayedWidth
        let targetHeight = usesExpandedHitArea
            ? max(displayedHeight, minimumOverlayInteractionSize)
            : displayedHeight

        return OverlayGestureSurface(
            layer: layer,
            displayScale: scale * canvasZoomScale,
            originalImageSize: originalImageSize,
            isAccessibilityElement: usesExpandedHitArea,
            accessibilityLabel: overlayAccessibilityLabel,
            accessibilityHint: overlayAccessibilityHint,
            onEditingBegan: onWillChange
        ) {
            selectedAnnotationID = nil
            selectedOverlayImageID = overlayImage.id
        }
        .frame(width: targetWidth, height: targetHeight)
        .contentShape(Rectangle())
        .rotationEffect(.radians(overlayImage.rotation))
        .position(
            x: overlayImage.centerX * scale,
            y: overlayImage.centerY * scale
        )
    }

    private func overlayTransformHandle(
        for overlayImage: OverlayImageLayer,
        scale: CGFloat
    ) -> some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.001))

            Circle()
                .fill(AppTheme.surface)
                .overlay {
                    Circle()
                        .stroke(AppTheme.accent, lineWidth: 2)
                }
                .overlay {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(AppTheme.accent)
                }
                .frame(
                    width: overlayTransformHandleDisplaySize,
                    height: overlayTransformHandleDisplaySize
                )
                .shadow(color: .black.opacity(0.13), radius: 4, y: 2)
        }
        .frame(
            width: overlayTransformHandleTouchSize,
            height: overlayTransformHandleTouchSize
        )
        .contentShape(Rectangle())
        .position(overlayTransformHandlePosition(for: overlayImage, scale: scale))
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(overlayAccessibilityLabel)
        .accessibilityHint(overlayAccessibilityHint)
    }

    private func overlayTransformHandlePosition(
        for overlayImage: OverlayImageLayer,
        scale: CGFloat
    ) -> CGPoint {
        let localX = overlayImage.width * scale / 2 + overlayTransformHandleOffset
        let localY = overlayImage.height * scale / 2 + overlayTransformHandleOffset
        let cosine = cos(overlayImage.rotation)
        let sine = sin(overlayImage.rotation)

        return CGPoint(
            x: overlayImage.centerX * scale + localX * cosine - localY * sine,
            y: overlayImage.centerY * scale + localX * sine + localY * cosine
        )
    }

    private func overlayTransformGesture(
        overlayID: UUID,
        geometry: ImageCanvasGeometry
    ) -> some Gesture {
        DragGesture(
            minimumDistance: 1,
            coordinateSpace: .named("imageCanvas")
        )
        .onChanged { value in
            guard geometry.scale > 0, !isNavigatingCanvas,
                  let index = overlayImages.firstIndex(
                    where: { $0.id == overlayID }
                  ) else {
                return
            }

            selectedAnnotationID = nil
            selectedOverlayImageID = overlayID

            let center = CGPoint(
                x: overlayImages[index].centerX * geometry.scale,
                y: overlayImages[index].centerY * geometry.scale
            )

            if overlayTransformState?.overlayID != overlayID {
                let initialDistance = hypot(
                    value.startLocation.x - center.x,
                    value.startLocation.y - center.y
                )
                guard initialDistance > 0.001 else { return }

                onWillChange()
                overlayTransformState = OverlayTransformState(
                    overlayID: overlayID,
                    initialWidth: overlayImages[index].width,
                    initialHeight: overlayImages[index].height,
                    initialRotation: overlayImages[index].rotation,
                    initialPointerDistance: initialDistance,
                    previousPointerAngle: atan2(
                        value.startLocation.y - center.y,
                        value.startLocation.x - center.x
                    ),
                    accumulatedAngleDelta: 0
                )
            }

            guard var state = overlayTransformState,
                  state.overlayID == overlayID else {
                return
            }

            let currentDistance = hypot(
                value.location.x - center.x,
                value.location.y - center.y
            )
            let currentAngle = atan2(
                value.location.y - center.y,
                value.location.x - center.x
            )
            state.accumulatedAngleDelta += normalizedAngle(
                currentAngle - state.previousPointerAngle
            )
            state.previousPointerAngle = currentAngle
            overlayTransformState = state

            let initialShortEdge = min(state.initialWidth, state.initialHeight)
            let initialLongEdge = max(state.initialWidth, state.initialHeight)
            guard initialShortEdge > 0, initialLongEdge > 0 else { return }

            let proposedScale = currentDistance / state.initialPointerDistance
            let minimumScale = minimumOverlayDisplayShortEdge /
                (initialShortEdge * geometry.scale)
            let maximumLongEdge = max(
                geometry.originalImageSize.width,
                geometry.originalImageSize.height
            ) * 3
            let maximumScale = maximumLongEdge / initialLongEdge
            let constrainedScale = min(
                max(proposedScale, minimumScale),
                maximumScale
            )

            overlayImages[index].width = state.initialWidth * constrainedScale
            overlayImages[index].height = state.initialHeight * constrainedScale
            overlayImages[index].rotation = normalizedAngle(
                state.initialRotation + state.accumulatedAngleDelta
            )
        }
        .onEnded { _ in
            overlayTransformState = nil
        }
    }

    private func normalizedAngle(_ angle: CGFloat) -> CGFloat {
        var result = angle.truncatingRemainder(dividingBy: .pi * 2)
        if result > .pi {
            result -= .pi * 2
        } else if result < -.pi {
            result += .pi * 2
        }
        return result
    }

    @ViewBuilder
    private func annotationView(
        _ annotation: Annotation,
        scale: CGFloat,
        isSelected: Bool
    ) -> some View {
        switch annotation.type {
        case .rectangle:
            annotationRectangle(
                annotation,
                scale: scale,
                isSelected: isSelected
            )
        case .line:
            annotationLine(
                annotation,
                scale: scale,
                isSelected: isSelected
            )
        case .arrow:
            annotationArrow(
                annotation,
                scale: scale,
                isSelected: isSelected
            )
        case .ellipse:
            annotationEllipse(
                annotation,
                scale: scale,
                isSelected: isSelected
            )
        case .mosaic:
            mosaicAnnotationView(annotation, scale: scale)
        }
    }

    @ViewBuilder
    private func mosaicAnnotationView(
        _ annotation: Annotation,
        scale: CGFloat
    ) -> some View {
        let strokes = annotation.mosaicStrokes.filter {
            $0.target == .compositedCanvas
        }

        ForEach(strokes) { stroke in
            if let pixelatedImage =
                mosaicLayerPixelatedPreviewImages[annotation.id]?[stroke.pixelSize] {
                Image(uiImage: pixelatedImage)
                    .resizable()
                    .interpolation(.none)
                    .frame(
                        width: originalImageSize.width * scale,
                        height: originalImageSize.height * scale
                    )
                    .mask {
                        MosaicStrokeMask(
                            stroke: stroke,
                            horizontalScale: scale,
                            verticalScale: scale
                        )
                    }
                    .allowsHitTesting(false)
            }
        }
    }

    private func annotationRectangle(
        _ annotation: Annotation,
        scale: CGFloat,
        isSelected: Bool
    ) -> some View {
        let lineWidth = AnnotationRenderingGeometry.lineWidth(
            for: annotation.strokeWidth,
            imageSize: originalImageSize
        ) * scale

        return ZStack {
            Rectangle()
                .stroke(
                    annotation.color.swiftUIColor,
                    lineWidth: lineWidth
                )

            if isSelected {
                Rectangle()
                    .stroke(
                        .blue,
                        style: StrokeStyle(
                            lineWidth: 2,
                            dash: [6, 4]
                        )
                    )
            }
        }
        .frame(
            width: annotation.width * scale,
            height: annotation.height * scale
        )
        .offset(
            x: annotation.x * scale,
            y: annotation.y * scale
        )
        .allowsHitTesting(false)
    }

    private func annotationEllipse(
        _ annotation: Annotation,
        scale: CGFloat,
        isSelected: Bool
    ) -> some View {
        let lineWidth = AnnotationRenderingGeometry.lineWidth(
            for: annotation.strokeWidth,
            imageSize: originalImageSize
        ) * scale

        return ZStack {
            Ellipse()
                .stroke(
                    annotation.color.swiftUIColor,
                    lineWidth: lineWidth
                )

            if isSelected {
                Ellipse()
                    .stroke(
                        .blue,
                        style: StrokeStyle(
                            lineWidth: 2,
                            dash: [6, 4]
                        )
                    )
            }
        }
        .frame(
            width: annotation.width * scale,
            height: annotation.height * scale
        )
        .offset(
            x: annotation.x * scale,
            y: annotation.y * scale
        )
        .allowsHitTesting(false)
    }

    private func annotationArrow(
        _ annotation: Annotation,
        scale: CGFloat,
        isSelected: Bool
    ) -> some View {
        let start = CGPoint(
            x: annotation.startX * scale,
            y: annotation.startY * scale
        )
        let end = CGPoint(
            x: annotation.endX * scale,
            y: annotation.endY * scale
        )
        let lineWidth = AnnotationRenderingGeometry.lineWidth(
            for: annotation.strokeWidth,
            imageSize: originalImageSize
        ) * scale
        let headLength = AnnotationRenderingGeometry.arrowHeadLength(
            for: annotation,
            imageSize: originalImageSize
        ) * scale

        return ZStack {
            ArrowShape(
                start: start,
                end: end,
                headLength: headLength
            )
            .stroke(
                annotation.color.swiftUIColor,
                style: StrokeStyle(
                    lineWidth: lineWidth,
                    lineCap: .round,
                    lineJoin: .round
                )
            )

            if isSelected {
                ArrowShape(
                    start: start,
                    end: end,
                    headLength: headLength
                )
                .stroke(
                    .blue,
                    style: StrokeStyle(
                        lineWidth: 2,
                        lineCap: .round,
                        lineJoin: .round,
                        dash: [6, 4]
                    )
                )
            }
        }
        .allowsHitTesting(false)
    }

    private func annotationLine(
        _ annotation: Annotation,
        scale: CGFloat,
        isSelected: Bool
    ) -> some View {
        let start = CGPoint(
            x: annotation.startX * scale,
            y: annotation.startY * scale
        )
        let end = CGPoint(
            x: annotation.endX * scale,
            y: annotation.endY * scale
        )
        let lineWidth = AnnotationRenderingGeometry.lineWidth(
            for: annotation.strokeWidth,
            imageSize: originalImageSize
        ) * scale

        return ZStack {
            LineShape(start: start, end: end)
                .stroke(
                    annotation.color.swiftUIColor,
                    style: StrokeStyle(
                        lineWidth: lineWidth,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )

            if isSelected {
                LineShape(start: start, end: end)
                    .stroke(
                        .blue,
                        style: StrokeStyle(
                            lineWidth: 2,
                            lineCap: .round,
                            lineJoin: .round,
                            dash: [6, 4]
                        )
                    )
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func annotationHitArea(
        _ annotation: Annotation,
        geometry: ImageCanvasGeometry
    ) -> some View {
        let scale = geometry.scale
        let lineWidth = AnnotationRenderingGeometry.lineWidth(
            for: annotation.strokeWidth,
            imageSize: originalImageSize
        ) * scale
        let hitWidth = max(lineWidth + shapeHitPadding, shapeHitPadding)

        switch annotation.type {
        case .rectangle:
            RectangleOutlineHitShape(hitWidth: hitWidth)
                .fill(Color.black.opacity(0.001))
                .frame(
                    width: annotation.width * scale + hitWidth,
                    height: annotation.height * scale + hitWidth
                )
                .contentShape(RectangleOutlineHitShape(hitWidth: hitWidth))
                .gesture(
                    annotationMoveGesture(
                        annotationID: annotation.id,
                        geometry: geometry
                    )
                )
                .position(
                    x: (annotation.x + annotation.width / 2) * scale,
                    y: (annotation.y + annotation.height / 2) * scale
                )

        case .line, .arrow:
            ArrowHitAreaShape(
                start: CGPoint(
                    x: annotation.startX * scale,
                    y: annotation.startY * scale
                ),
                end: CGPoint(
                    x: annotation.endX * scale,
                    y: annotation.endY * scale
                ),
                hitWidth: 44
            )
            .fill(Color.black.opacity(0.001))
            .contentShape(
                ArrowHitAreaShape(
                    start: CGPoint(
                        x: annotation.startX * scale,
                        y: annotation.startY * scale
                    ),
                    end: CGPoint(
                        x: annotation.endX * scale,
                        y: annotation.endY * scale
                    ),
                    hitWidth: 44
                )
            )
            .gesture(
                annotationMoveGesture(
                    annotationID: annotation.id,
                    geometry: geometry
                )
            )

        case .ellipse:
            EllipseOutlineHitShape(hitWidth: hitWidth)
                .fill(Color.black.opacity(0.001))
                .frame(
                    width: annotation.width * scale + hitWidth,
                    height: annotation.height * scale + hitWidth
                )
                .contentShape(EllipseOutlineHitShape(hitWidth: hitWidth))
                .gesture(
                    annotationMoveGesture(
                        annotationID: annotation.id,
                        geometry: geometry
                    )
                )
                .position(
                    x: (annotation.x + annotation.width / 2) * scale,
                    y: (annotation.y + annotation.height / 2) * scale
                )

        case .mosaic:
            EmptyView()
        }
    }

    private func resizeHandle(
        for annotation: Annotation,
        handle: AnnotationResizeHandle,
        scale: CGFloat
    ) -> some View {
        let position = resizeHandlePosition(
            for: annotation,
            handle: handle,
            scale: scale
        )

        return ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.001))

            Circle()
                .fill(.white)
                .overlay {
                    Circle()
                        .stroke(.blue, lineWidth: 2)
                }
                .frame(
                    width: resizeHandleDisplaySize,
                    height: resizeHandleDisplaySize
                )
        }
        .frame(
            width: resizeHandleTouchSize,
            height: resizeHandleTouchSize
        )
        .contentShape(Rectangle())
        .position(position)
    }

    private func resizeHandlePosition(
        for annotation: Annotation,
        handle: AnnotationResizeHandle,
        scale: CGFloat
    ) -> CGPoint {
        switch handle {
        case .topLeft:
            return CGPoint(
                x: annotation.x * scale,
                y: annotation.y * scale
            )
        case .bottomRight:
            return CGPoint(
                x: (annotation.x + annotation.width) * scale,
                y: (annotation.y + annotation.height) * scale
            )
        }
    }

    private func shouldShowBothResizeHandles(
        for annotation: Annotation,
        scale: CGFloat
    ) -> Bool {
        annotation.width * scale >= minimumDisplaySizeForTwoResizeHandles &&
            annotation.height * scale >= minimumDisplaySizeForTwoResizeHandles
    }

    private func annotationCreationGesture(geometry: ImageCanvasGeometry) -> some Gesture {
        DragGesture(
            minimumDistance: 0,
            coordinateSpace: .named("imageCanvas")
        )
            .onChanged { value in
                guard geometry.scale > 0, !isNavigatingCanvas else { return }

                selectedAnnotationID = nil
                selectedOverlayImageID = nil

                if selectedTool == .select {
                    draftAnnotation = nil
                    return
                }

                let start = originalImagePoint(
                    from: value.startLocation,
                    geometry: geometry
                )
                let current = originalImagePoint(
                    from: value.location,
                    geometry: geometry
                )
                let id = draftAnnotation?.id ?? UUID()
                let layerOrder = draftAnnotation?.layerOrder ?? nextLayerOrder

                switch selectedTool {
                case .select:
                    break
                case .rectangle:
                    draftAnnotation = Annotation(
                        id: id,
                        x: min(start.x, current.x),
                        y: min(start.y, current.y),
                        width: abs(current.x - start.x),
                        height: abs(current.y - start.y),
                        color: .red,
                        layerOrder: layerOrder
                    )
                case .ellipse:
                    draftAnnotation = Annotation(
                        id: id,
                        type: .ellipse,
                        x: min(start.x, current.x),
                        y: min(start.y, current.y),
                        width: abs(current.x - start.x),
                        height: abs(current.y - start.y),
                        color: .red,
                        layerOrder: layerOrder
                    )
                case .line:
                    draftAnnotation = Annotation(
                        id: id,
                        type: .line,
                        startX: start.x,
                        startY: start.y,
                        endX: current.x,
                        endY: current.y,
                        color: .red,
                        layerOrder: layerOrder
                    )
                case .arrow:
                    draftAnnotation = Annotation(
                        id: id,
                        startX: start.x,
                        startY: start.y,
                        endX: current.x,
                        endY: current.y,
                        color: .red,
                        layerOrder: layerOrder
                    )
                case .mosaic:
                    draftAnnotation = nil
                    updatePendingMosaicStroke(
                        at: value.location,
                        geometry: geometry
                    )
                }
            }
            .onEnded { _ in
                guard !isNavigatingCanvas else { return }
                if selectedTool == .mosaic {
                    if let activeMosaicStrokeID,
                       let index = pendingMosaicStrokes.firstIndex(
                           where: { $0.id == activeMosaicStrokeID }
                       ) {
                        let completedStroke = pendingMosaicStrokes.remove(at: index)
                        onCommitMosaicStroke(completedStroke)
                    }
                    activeMosaicStrokeID = nil
                    draftAnnotation = nil
                    return
                }

                guard let draftAnnotation, geometry.scale > 0 else {
                    self.draftAnnotation = nil
                    return
                }

                let minimumOriginalSize = minimumAnnotationDisplaySize / (geometry.scale * canvasZoomScale)
                let shouldSave: Bool

                switch draftAnnotation.type {
                case .rectangle, .ellipse:
                    shouldSave =
                        draftAnnotation.width >= minimumOriginalSize &&
                        draftAnnotation.height >= minimumOriginalSize
                case .line, .arrow:
                    shouldSave = hypot(
                        draftAnnotation.endX - draftAnnotation.startX,
                        draftAnnotation.endY - draftAnnotation.startY
                    ) >= minimumOriginalSize
                case .mosaic:
                    shouldSave = false
                }

                if shouldSave {
                    onWillChange()
                    annotations.append(draftAnnotation)
                    nextLayerOrder = max(
                        nextLayerOrder,
                        draftAnnotation.layerOrder + 1
                    )
                }

                self.draftAnnotation = nil
            }
    }

    private func annotationMoveGesture(
        annotationID: UUID,
        geometry: ImageCanvasGeometry
    ) -> some Gesture {
        DragGesture(
            minimumDistance: 0,
            coordinateSpace: .named("imageCanvas")
        )
            .onChanged { value in
                guard geometry.scale > 0, !isNavigatingCanvas,
                      let index = annotations.firstIndex(where: { $0.id == annotationID }) else {
                    return
                }

                selectedAnnotationID = annotationID
                selectedOverlayImageID = nil

                let movement = hypot(
                    value.location.x - value.startLocation.x,
                    value.location.y - value.startLocation.y
                )
                let isActiveMove = moveState?.annotationID == annotationID
                guard movement >= annotationMoveActivationDistance ||
                        isActiveMove else {
                    return
                }

                if moveState?.annotationID != annotationID {
                    onWillChange()
                    moveState = AnnotationMoveState(
                        annotationID: annotationID,
                        originalAnnotation: annotations[index]
                    )
                }

                guard let moveState, moveState.annotationID == annotationID else { return }

                let deltaX = (value.location.x - value.startLocation.x) / geometry.scale
                let deltaY = (value.location.y - value.startLocation.y) / geometry.scale

                switch moveState.originalAnnotation.type {
                case .rectangle, .ellipse:
                    let maximumX = max(
                        geometry.originalImageSize.width -
                            moveState.originalAnnotation.width,
                        0
                    )
                    let maximumY = max(
                        geometry.originalImageSize.height -
                            moveState.originalAnnotation.height,
                        0
                    )

                    annotations[index].x = min(
                        max(moveState.originalAnnotation.x + deltaX, 0),
                        maximumX
                    )
                    annotations[index].y = min(
                        max(moveState.originalAnnotation.y + deltaY, 0),
                        maximumY
                    )

                case .line, .arrow:
                    let minimumX = min(
                        moveState.originalAnnotation.startX,
                        moveState.originalAnnotation.endX
                    )
                    let maximumX = max(
                        moveState.originalAnnotation.startX,
                        moveState.originalAnnotation.endX
                    )
                    let minimumY = min(
                        moveState.originalAnnotation.startY,
                        moveState.originalAnnotation.endY
                    )
                    let maximumY = max(
                        moveState.originalAnnotation.startY,
                        moveState.originalAnnotation.endY
                    )
                    let constrainedDeltaX = min(
                        max(deltaX, -minimumX),
                        geometry.originalImageSize.width - maximumX
                    )
                    let constrainedDeltaY = min(
                        max(deltaY, -minimumY),
                        geometry.originalImageSize.height - maximumY
                    )

                    annotations[index].startX =
                        moveState.originalAnnotation.startX + constrainedDeltaX
                    annotations[index].startY =
                        moveState.originalAnnotation.startY + constrainedDeltaY
                    annotations[index].endX =
                        moveState.originalAnnotation.endX + constrainedDeltaX
                    annotations[index].endY =
                        moveState.originalAnnotation.endY + constrainedDeltaY

                case .mosaic:
                    break
                }
            }
            .onEnded { _ in
                let didMove = moveState?.annotationID == annotationID
                moveState = nil

                if !didMove {
                    onEditAnnotation(annotationID)
                }
            }
    }

    private func annotationResizeGesture(
        annotationID: UUID,
        handle: AnnotationResizeHandle,
        geometry: ImageCanvasGeometry
    ) -> some Gesture {
        DragGesture(
            minimumDistance: 0,
            coordinateSpace: .named("imageCanvas")
        )
            .onChanged { value in
                guard geometry.scale > 0, !isNavigatingCanvas,
                      let index = annotations.firstIndex(where: { $0.id == annotationID }),
                      annotations[index].type == .rectangle ||
                        annotations[index].type == .ellipse else {
                    return
                }

                selectedAnnotationID = annotationID
                selectedOverlayImageID = nil

                if resizeState?.annotationID != annotationID ||
                    resizeState?.handle != handle {
                    onWillChange()
                    resizeState = AnnotationResizeState(
                        annotationID: annotationID,
                        handle: handle,
                        originalX: annotations[index].x,
                        originalY: annotations[index].y,
                        originalWidth: annotations[index].width,
                        originalHeight: annotations[index].height
                    )
                }

                guard let resizeState,
                      resizeState.annotationID == annotationID,
                      resizeState.handle == handle else {
                    return
                }

                let current = originalImagePoint(
                    from: value.location,
                    geometry: geometry
                )
                let minimumOriginalSize = minimumAnnotationDisplaySize / (geometry.scale * canvasZoomScale)

                switch handle {
                case .topLeft:
                    let fixedRight = resizeState.originalX + resizeState.originalWidth
                    let fixedBottom = resizeState.originalY + resizeState.originalHeight
                    let maximumX = max(fixedRight - minimumOriginalSize, 0)
                    let maximumY = max(fixedBottom - minimumOriginalSize, 0)
                    let newX = min(max(current.x, 0), maximumX)
                    let newY = min(max(current.y, 0), maximumY)

                    annotations[index].x = newX
                    annotations[index].y = newY
                    annotations[index].width = fixedRight - newX
                    annotations[index].height = fixedBottom - newY

                case .bottomRight:
                    let minimumRight = min(
                        resizeState.originalX + minimumOriginalSize,
                        geometry.originalImageSize.width
                    )
                    let minimumBottom = min(
                        resizeState.originalY + minimumOriginalSize,
                        geometry.originalImageSize.height
                    )
                    let newRight = min(
                        max(current.x, minimumRight),
                        geometry.originalImageSize.width
                    )
                    let newBottom = min(
                        max(current.y, minimumBottom),
                        geometry.originalImageSize.height
                    )

                    annotations[index].width = newRight - resizeState.originalX
                    annotations[index].height = newBottom - resizeState.originalY
                }
            }
            .onEnded { _ in
                resizeState = nil
            }
    }

    private func originalImagePoint(
        from displayPoint: CGPoint,
        geometry: ImageCanvasGeometry
    ) -> CGPoint {
        CGPoint(
            x: min(
                max(displayPoint.x / geometry.scale, 0),
                geometry.originalImageSize.width
            ),
            y: min(
                max(displayPoint.y / geometry.scale, 0),
                geometry.originalImageSize.height
            )
        )
    }

    private func updatePendingMosaicStroke(
        at displayPoint: CGPoint,
        geometry: ImageCanvasGeometry
    ) {
        guard selectedTool == .mosaic, geometry.scale > 0 else { return }

        if let activeMosaicStrokeID,
           let index = pendingMosaicStrokes.firstIndex(
               where: { $0.id == activeMosaicStrokeID }
           ) {
            guard let point = mosaicLocalPoint(
                from: displayPoint,
                target: pendingMosaicStrokes[index].target,
                geometry: geometry
            ) else {
                return
            }

            if let lastPoint = pendingMosaicStrokes[index].points.last {
                let targetScale = mosaicDisplayScale(
                    for: pendingMosaicStrokes[index].target,
                    geometry: geometry
                )
                let minimumSpacing = max(1 / max(targetScale, 0.001), 0.5)
                guard hypot(point.x - lastPoint.x, point.y - lastPoint.y) >=
                        minimumSpacing else {
                    return
                }
            }

            pendingMosaicStrokes[index].points.append(point)
            return
        }

        let target = MosaicTarget.compositedCanvas
        guard let point = mosaicLocalPoint(
            from: displayPoint,
            target: target,
            geometry: geometry
        ) else {
            return
        }
        let targetScale = mosaicDisplayScale(
            for: target,
            geometry: geometry
        )
        guard targetScale > 0 else { return }

        let stroke = MosaicStroke(
            points: [point],
            brushSize: mosaicBrushSize / targetScale,
            pixelSize: mosaicPixelSize,
            target: target
        )
        pendingMosaicStrokes.append(stroke)
        activeMosaicStrokeID = stroke.id
    }

    private func mosaicTarget(at canvasPoint: CGPoint) -> MosaicTarget {
        for overlayImage in overlayImages.reversed() {
            guard let localPoint = overlayImage.localImagePoint(
                from: canvasPoint
            ), overlayImage.contains(localImagePoint: localPoint),
            isVisiblePixel(
                in: overlayImage.imageAsset.previewImage,
                localPoint: localPoint,
                originalImageSize: overlayImage.imageAsset.originalImageSize
            ) else {
                continue
            }

            return .overlayImage(overlayImage.id)
        }

        return .baseImage
    }

    private func mosaicLocalPoint(
        from displayPoint: CGPoint,
        target: MosaicTarget,
        geometry: ImageCanvasGeometry
    ) -> CGPoint? {
        let canvasPoint = CGPoint(
            x: displayPoint.x / geometry.scale,
            y: displayPoint.y / geometry.scale
        )

        switch target {
        case .baseImage, .compositedCanvas:
            return canvasPoint

        case let .overlayImage(id):
            guard let overlayImage = overlayImages.first(
                where: { $0.id == id }
            ) else {
                return nil
            }
            return overlayImage.localImagePoint(from: canvasPoint)
        }
    }

    private func mosaicDisplayScale(
        for target: MosaicTarget,
        geometry: ImageCanvasGeometry
    ) -> CGFloat {
        switch target {
        case .baseImage, .compositedCanvas:
            return geometry.scale * canvasZoomScale

        case let .overlayImage(id):
            return overlayImages.first(where: { $0.id == id })?
                .displayScale(in: geometry.scale * canvasZoomScale) ?? 0
        }
    }

    private func isVisiblePixel(
        in image: UIImage,
        localPoint: CGPoint,
        originalImageSize: CGSize
    ) -> Bool {
        guard let cgImage = image.cgImage,
              originalImageSize.width > 0,
              originalImageSize.height > 0 else {
            return true
        }

        let pixelX = min(
            max(Int(localPoint.x / originalImageSize.width * CGFloat(cgImage.width)), 0),
            cgImage.width - 1
        )
        let pixelY = min(
            max(Int(localPoint.y / originalImageSize.height * CGFloat(cgImage.height)), 0),
            cgImage.height - 1
        )
        guard let pixelImage = cgImage.cropping(
            to: CGRect(x: pixelX, y: pixelY, width: 1, height: 1)
        ) else {
            return true
        }

        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return true
        }

        context.draw(pixelImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return pixel[3] > 8
    }
}

private struct MosaicStrokeMask: View {
    let stroke: MosaicStroke
    let horizontalScale: CGFloat
    let verticalScale: CGFloat

    var body: some View {
        Canvas { context, _ in
            guard let firstPoint = stroke.points.first else { return }
            let brushScale = (abs(horizontalScale) + abs(verticalScale)) / 2

            if stroke.points.count == 1 {
                let diameter = stroke.brushSize * brushScale
                context.fill(
                    Path(
                        ellipseIn: CGRect(
                            x: firstPoint.x * horizontalScale - diameter / 2,
                            y: firstPoint.y * verticalScale - diameter / 2,
                            width: diameter,
                            height: diameter
                        )
                    ),
                    with: .color(.white)
                )
                return
            }

            var path = Path()
            path.move(
                to: CGPoint(
                    x: firstPoint.x * horizontalScale,
                    y: firstPoint.y * verticalScale
                )
            )

            for point in stroke.points.dropFirst() {
                path.addLine(
                    to: CGPoint(
                        x: point.x * horizontalScale,
                        y: point.y * verticalScale
                    )
                )
            }

            context.stroke(
                path,
                with: .color(.white),
                style: StrokeStyle(
                    lineWidth: stroke.brushSize * brushScale,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
        }
    }
}

enum MosaicPixelation {
    static func lowResolutionImage(
        from sourceImage: UIImage,
        originalImageSize: CGSize,
        pixelSize: MosaicPixelSize
    ) -> UIImage? {
        let blockSize = pixelSize.blockSize(for: originalImageSize)
        guard blockSize > 0 else { return nil }

        let sampleSize = CGSize(
            width: max(1, ceil(originalImageSize.width / blockSize)),
            height: max(1, ceil(originalImageSize.height / blockSize))
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false

        return UIGraphicsImageRenderer(size: sampleSize, format: format).image {
            context in
            context.cgContext.interpolationQuality = .medium
            sourceImage.draw(in: CGRect(origin: .zero, size: sampleSize))
        }
    }
}
