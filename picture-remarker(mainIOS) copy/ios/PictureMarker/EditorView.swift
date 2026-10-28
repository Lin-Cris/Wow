import SwiftUI
import PhotosUI

private struct AnnotationEditorSelection: Identifiable {
    let annotation: Annotation

    var id: UUID {
        annotation.id
    }
}

private struct EditorNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct EditorView: View {
    @Environment(\.dismiss) private var dismiss
    private let initialPhoto: PhotosPickerItem?
    private let initialImageFileURL: URL?
    @AppStorage(AppLanguage.storageKey)
    private var languageRawValue = AppLanguage.defaultValue.rawValue
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selectedImageAsset: EditableImageAsset?
    @State private var isLoadingImage = false
    @State private var imageLoadFailed = false
    @State private var imageLoadTask: Task<Void, Never>?
    @State private var activeImageLoadID: UUID?
    @State private var isImagePickerPresented = false
    @State private var selectedOverlayPhoto: PhotosPickerItem?
    @State private var isOverlayImagePickerPresented = false
    @State private var overlayImageLoadTask: Task<Void, Never>?
    @State private var isLoadingOverlayImage = false
    @State private var annotations: [Annotation] = []
    @State private var overlayImages: [OverlayImageLayer] = []
    @State private var selectedAnnotationID: UUID?
    @State private var selectedOverlayImageID: UUID?
    @State private var selectedTool: EditorTool = .select
    @State private var lastShapeTool: EditorTool = .rectangle
    @State private var isShapePickerPresented = false
    @State private var pendingMosaicStrokes: [MosaicStroke] = []
    @State private var mosaicBrushSize: CGFloat = 34
    @State private var mosaicPixelSize: MosaicPixelSize = .medium
    @State private var nextLayerOrder = 1
    @State private var propertyEditorSelection: AnnotationEditorSelection?
    @State private var isClearConfirmationPresented = false
    @State private var isSettingsPresented = false
    @State private var notice: EditorNotice?
    @State private var history = EditorHistory()

    init(
        initialPhoto: PhotosPickerItem? = nil,
        initialImageFileURL: URL? = nil
    ) {
        self.initialPhoto = initialPhoto
        self.initialImageFileURL = initialImageFileURL
    }

    private var strings: AppStrings {
        AppStrings(rawValue: languageRawValue)
    }

    var body: some View {
        VStack(spacing: 10) {
            RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous)
                .fill(AppTheme.surface)
                .overlay {
                    ZStack(alignment: .top) {
                        if let selectedImageAsset {
                            ImageCanvasView(
                                image: selectedImageAsset.previewImage,
                                originalImageSize: selectedImageAsset.originalImageSize,
                                annotations: $annotations,
                                overlayImages: $overlayImages,
                                pendingMosaicStrokes: $pendingMosaicStrokes,
                                nextLayerOrder: $nextLayerOrder,
                                selectedAnnotationID: $selectedAnnotationID,
                                selectedOverlayImageID: $selectedOverlayImageID,
                                selectedTool: selectedTool,
                                mosaicBrushSize: mosaicBrushSize,
                                mosaicPixelSize: mosaicPixelSize,
                                onEditAnnotation: openPropertyEditor,
                                onCommitMosaicStroke: commitMosaicStroke,
                                onWillChange: recordHistoryCheckpoint,
                                overlayAccessibilityLabel: strings.overlayAccessibilityLabel,
                                overlayAccessibilityHint: strings.overlayAccessibilityHint
                            )
                            .padding(6)
                        } else if isLoadingImage {
                            ProgressView(strings.loadingImage)
                                .tint(AppTheme.accent)
                        } else {
                            ProgressView(
                                imageLoadFailed
                                    ? strings.imageLoadFailed
                                    : strings.loadingImage
                            )
                            .tint(AppTheme.accent)
                        }

                    }
                }
                .warmCard()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if selectedImageAsset != nil {
                Text(editorHint)
                    .font(.caption)
                    .foregroundStyle(AppTheme.tertiaryText)
                    .lineLimit(1)
            }

            bottomToolbar
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 7)
        .background(WarmPageBackground())
        .navigationBarBackButtonHidden(true)
        .toolbarBackground(AppTheme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    WarmNavigationIcon(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(strings.back)
            }

            ToolbarItem(placement: .principal) {
                Text(strings.annotationCount(annotations.count))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText)
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    undo()
                } label: {
                    WarmNavigationIcon(
                        systemName: "arrow.uturn.backward",
                        isEnabled: history.canUndo
                    )
                }
                .buttonStyle(.plain)
                .disabled(!history.canUndo)
                .accessibilityLabel(strings.undo)

                Button {
                    redo()
                } label: {
                    WarmNavigationIcon(
                        systemName: "arrow.uturn.forward",
                        isEnabled: history.canRedo
                    )
                }
                .buttonStyle(.plain)
                .disabled(!history.canRedo)
                .accessibilityLabel(strings.redo)

                Group {
                    if let selectedImageAsset {
                        NavigationLink {
                            ExportView(
                                imageAsset: selectedImageAsset,
                                annotations: annotations,
                                overlayImages: overlayImages
                            )
                        } label: {
                            WarmNavigationIcon(
                                systemName: "checkmark",
                                isEmphasized: true
                            )
                        }
                    } else {
                        WarmNavigationIcon(
                            systemName: "checkmark",
                            isEnabled: false
                        )
                    }
                }
                .accessibilityLabel(strings.done)
            }
        }
        .sheet(item: $propertyEditorSelection) { selection in
            AnnotationPropertySheet(
                annotation: selection.annotation,
                onUpdate: updateAnnotation,
                onDuplicate: duplicateAnnotation,
                onDelete: deleteAnnotation
            )
        }
        .sheet(isPresented: $isSettingsPresented) {
            LanguageSettingsView()
        }
        .confirmationDialog(
            strings.clearConfirmation,
            isPresented: $isClearConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(strings.clearAll, role: .destructive) {
                clearAllContent()
            }

            Button(strings.cancel, role: .cancel) {}
        }
        .onAppear {
            guard selectedImageAsset == nil else {
                return
            }

            if let initialPhoto {
                imageLoadTask?.cancel()
                imageLoadTask = Task {
                    await loadImage(from: initialPhoto)
                }
            } else if let initialImageFileURL {
                imageLoadTask?.cancel()
                imageLoadTask = Task {
                    await loadImage(from: initialImageFileURL)
                }
            }
        }
        .onChange(of: selectedPhoto) { _, newPhoto in
            guard let newPhoto else { return }

            imageLoadTask?.cancel()
            overlayImageLoadTask?.cancel()
            imageLoadTask = Task {
                await loadImage(from: newPhoto)
            }
        }
        .onChange(of: selectedOverlayPhoto) { _, newPhoto in
            guard let newPhoto else { return }

            commitPendingMosaicStrokes()
            selectedTool = .select
            overlayImageLoadTask?.cancel()
            overlayImageLoadTask = Task {
                await loadOverlayImage(from: newPhoto)
            }
        }
        .alert(item: $notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text(strings.okay))
            )
        }
        .photosPicker(
            isPresented: $isImagePickerPresented,
            selection: $selectedPhoto,
            matching: .images
        )
        .photosPicker(
            isPresented: $isOverlayImagePickerPresented,
            selection: $selectedOverlayPhoto,
            matching: .images
        )
        .onDisappear {
            imageLoadTask?.cancel()
            overlayImageLoadTask?.cancel()
        }
    }

    private var bottomToolbar: some View {
        HStack(spacing: 4) {
            toolButton(.select)
            shapeToolButton
            toolButton(.line)
            toolButton(.arrow)
            toolButton(.mosaic)

            Menu {
                Button {
                    activateTool(.select)
                    DispatchQueue.main.async {
                        isOverlayImagePickerPresented = true
                    }
                } label: {
                    Label(
                        isLoadingOverlayImage ? strings.loading : strings.addImage,
                        systemImage: "photo.badge.plus"
                    )
                }
                .disabled(selectedImageAsset == nil || isLoadingOverlayImage)

                Button {
                    DispatchQueue.main.async {
                        isImagePickerPresented = true
                    }
                } label: {
                    Label(
                        selectedImageAsset == nil ? strings.chooseImage : strings.replaceImage,
                        systemImage: "photo.on.rectangle"
                    )
                }

                if selectedOverlayImageID != nil {
                    Button {
                        duplicateSelectedOverlayImage()
                    } label: {
                        Label(
                            strings.duplicateSelectedImage,
                            systemImage: "plus.square.on.square"
                        )
                    }

                    Button(role: .destructive) {
                        deleteSelectedOverlayImage()
                    } label: {
                        Label(strings.deleteSelectedImage, systemImage: "trash")
                    }
                }

                Divider()

                Button {
                    isSettingsPresented = true
                } label: {
                    Label(strings.settings, systemImage: "gearshape")
                }

                Button(role: .destructive) {
                    isClearConfirmationPresented = true
                } label: {
                    Label(strings.clearAll, systemImage: "trash")
                }
                .disabled(annotations.isEmpty && overlayImages.isEmpty)
            } label: {
                toolbarLabel(
                    title: strings.more,
                    systemImage: "ellipsis.circle",
                    isSelected: false
                )
                .foregroundStyle(AppTheme.primaryText)
            }
            .simultaneousGesture(
                TapGesture().onEnded {
                    activateTool(.select)
                }
            )
        }
        .padding(6)
        .background {
            ZStack {
                AppTheme.elevatedSurface.opacity(0.86)
                Rectangle().fill(.ultraThinMaterial)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppTheme.border.opacity(0.58), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(0.055), radius: 13, y: 6)
        .overlay(alignment: .topLeading) {
            if selectedImageAsset != nil, selectedTool == .mosaic {
                GeometryReader { proxy in
                    mosaicControlBar
                        .frame(width: min(proxy.size.width - 20, 270))
                        .position(
                            x: proxy.size.width * 7 / 12,
                            y: -38
                        )
                }
            }
        }
    }

    private func toolButton(_ tool: EditorTool) -> some View {
        let isSelected = selectedTool == tool

        return Button {
            activateTool(tool)
        } label: {
            toolbarLabel(
                title: strings.toolTitle(tool),
                systemImage: tool.systemImage,
                isSelected: isSelected
            )
        }
        .buttonStyle(.plain)
        .disabled(selectedImageAsset == nil)
        .accessibilityValue(isSelected ? strings.selectedToolAccessibility : "")
    }

    private var shapeToolButton: some View {
        let isSelected = selectedTool == .rectangle || selectedTool == .ellipse

        return Button {
            isShapePickerPresented.toggle()
        } label: {
            toolbarLabel(
                title: strings.shape,
                systemImage: lastShapeTool.systemImage,
                isSelected: isSelected
            )
        }
        .buttonStyle(.plain)
        .disabled(selectedImageAsset == nil)
        .accessibilityValue(isSelected ? strings.selectedToolAccessibility : "")
        .popover(
            isPresented: $isShapePickerPresented,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .bottom
        ) {
            shapePicker
                .presentationCompactAdaptation(.popover)
        }
    }

    private var shapePicker: some View {
        VStack(spacing: 0) {
            shapePickerButton(.rectangle, title: strings.rectangle)

            Divider()
                .padding(.leading, 42)

            shapePickerButton(.ellipse, title: strings.ellipse)
        }
        .padding(.vertical, 6)
        .frame(width: 190)
        .background(AppTheme.elevatedSurface)
    }

    private func shapePickerButton(_ tool: EditorTool, title: String) -> some View {
        Button {
            lastShapeTool = tool
            activateTool(tool)
            isShapePickerPresented = false
        } label: {
            HStack(spacing: 12) {
                Image(systemName: tool.systemImage)
                    .frame(width: 20)

                Text(title)

                Spacer()

                if lastShapeTool == tool {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(AppTheme.accent)
                }
            }
            .font(.subheadline)
            .foregroundStyle(AppTheme.primaryText)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var mosaicControlBar: some View {
        HStack(spacing: 8) {
            Text(strings.size)
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryText)

            Slider(value: $mosaicBrushSize, in: 14...72)
                .tint(AppTheme.accent)
                .frame(minWidth: 64)

            VStack(spacing: 3) {
                Text(strings.pixelSize)
                    .font(.system(size: 9))
                    .foregroundStyle(AppTheme.secondaryText)

                HStack(spacing: 4) {
                    ForEach(MosaicPixelSize.allCases) { size in
                        Button {
                            mosaicPixelSize = size
                        } label: {
                            Text(size.shortTitle)
                                .font(.caption.weight(
                                    mosaicPixelSize == size ? .semibold : .regular
                                ))
                                .foregroundStyle(
                                    mosaicPixelSize == size
                                        ? Color.white
                                        : AppTheme.primaryText
                                )
                                .frame(width: 30, height: 24)
                                .background(
                                    mosaicPixelSize == size
                                        ? AppTheme.accent
                                        : AppTheme.surface.opacity(0.72)
                                )
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background {
            ZStack {
                AppTheme.elevatedSurface.opacity(0.9)
                Rectangle().fill(.ultraThinMaterial)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppTheme.border.opacity(0.5), lineWidth: 0.7)
        }
        .shadow(color: .black.opacity(0.08), radius: 9, y: 4)
    }

    private func activateTool(_ tool: EditorTool) {
        if tool != .mosaic {
            commitPendingMosaicStrokes()
        }

        selectedTool = tool
        selectedAnnotationID = nil
        selectedOverlayImageID = nil
        isShapePickerPresented = false
    }

    private func commitMosaicStroke(_ stroke: MosaicStroke) {
        recordHistoryCheckpoint()
        annotations.append(
            Annotation(
                mosaicStrokes: [stroke],
                layerOrder: allocateLayerOrder()
            )
        )
    }

    private func commitPendingMosaicStrokes() {
        let strokes = pendingMosaicStrokes
        pendingMosaicStrokes.removeAll(keepingCapacity: true)

        for stroke in strokes {
            recordHistoryCheckpoint()
            annotations.append(
                Annotation(
                    mosaicStrokes: [stroke],
                    layerOrder: allocateLayerOrder()
                )
            )
        }
    }

    private func toolbarLabel(
        title: String,
        systemImage: String,
        isSelected: Bool,
        showsProgress: Bool = false
    ) -> some View {
        VStack(spacing: 4) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .tint(AppTheme.accent)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: isSelected ? .semibold : .regular))
            }

            Text(title)
                .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.88)
        }
        .frame(maxWidth: .infinity, minHeight: 54)
        .foregroundStyle(isSelected ? AppTheme.accent : AppTheme.primaryText)
        .background(isSelected ? AppTheme.accentSoft.opacity(0.82) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .contentShape(Rectangle())
    }

    @MainActor
    private func loadImage(from photo: PhotosPickerItem) async {
        let loadID = UUID()
        activeImageLoadID = loadID
        isLoadingImage = true
        imageLoadFailed = false

        defer {
            if activeImageLoadID == loadID {
                isLoadingImage = false
                activeImageLoadID = nil
            }
        }

        guard let pickedImageFile = try? await photo.loadTransferable(
            type: PickedImageFile.self
        ) else {
            handleImageLoadFailure(loadID: loadID)
            return
        }

        guard !Task.isCancelled, activeImageLoadID == loadID else {
            try? FileManager.default.removeItem(at: pickedImageFile.fileURL)
            return
        }

        let imageAsset = await Task.detached(
            priority: .userInitiated
        ) { () -> EditableImageAsset? in
            do {
                return try ImageAssetLoader.makeEditableAsset(
                    from: pickedImageFile.fileURL
                )
            } catch {
                try? FileManager.default.removeItem(
                    at: pickedImageFile.fileURL
                )
                return nil
            }
        }.value

        guard !Task.isCancelled,
              activeImageLoadID == loadID,
              let imageAsset else {
            handleImageLoadFailure(loadID: loadID)
            return
        }

        selectedImageAsset = imageAsset
        annotations = []
        overlayImages = []
        selectedAnnotationID = nil
        selectedOverlayImageID = nil
        propertyEditorSelection = nil
        selectedTool = .select
        isShapePickerPresented = false
        pendingMosaicStrokes = []
        nextLayerOrder = 1
        history.reset()
    }

    @MainActor
    private func loadImage(from fileURL: URL) async {
        let loadID = UUID()
        activeImageLoadID = loadID
        isLoadingImage = true
        imageLoadFailed = false

        defer {
            if activeImageLoadID == loadID {
                isLoadingImage = false
                activeImageLoadID = nil
            }
        }

        let imageAsset = await Task.detached(
            priority: .userInitiated
        ) { () -> EditableImageAsset? in
            do {
                return try ImageAssetLoader.makeEditableAsset(from: fileURL)
            } catch {
                try? FileManager.default.removeItem(at: fileURL)
                return nil
            }
        }.value

        guard !Task.isCancelled,
              activeImageLoadID == loadID,
              let imageAsset else {
            handleImageLoadFailure(loadID: loadID)
            return
        }

        selectedImageAsset = imageAsset
        annotations = []
        overlayImages = []
        selectedAnnotationID = nil
        selectedOverlayImageID = nil
        propertyEditorSelection = nil
        selectedTool = .select
        isShapePickerPresented = false
        pendingMosaicStrokes = []
        nextLayerOrder = 1
        history.reset()
    }

    private func handleImageLoadFailure(loadID: UUID) {
        guard activeImageLoadID == loadID else { return }

        selectedImageAsset = nil
        annotations = []
        overlayImages = []
        selectedAnnotationID = nil
        selectedOverlayImageID = nil
        propertyEditorSelection = nil
        selectedTool = .select
        isShapePickerPresented = false
        pendingMosaicStrokes = []
        nextLayerOrder = 1
        imageLoadFailed = true
        history.reset()
    }

    private func openPropertyEditor(annotationID: UUID) {
        guard let annotation = annotations.first(where: { $0.id == annotationID }) else {
            return
        }

        propertyEditorSelection = AnnotationEditorSelection(annotation: annotation)
        selectedOverlayImageID = nil
    }

    private func updateAnnotation(_ updatedAnnotation: Annotation) {
        guard let index = annotations.firstIndex(
            where: { $0.id == updatedAnnotation.id }
        ) else {
            return
        }

        recordHistoryCheckpoint()
        annotations[index] = updatedAnnotation
    }

    private func deleteAnnotation(annotationID: UUID) {
        guard annotations.contains(where: { $0.id == annotationID }) else { return }

        recordHistoryCheckpoint()
        annotations.removeAll(where: { $0.id == annotationID })

        if selectedAnnotationID == annotationID {
            selectedAnnotationID = nil
        }

        if propertyEditorSelection?.id == annotationID {
            propertyEditorSelection = nil
        }
    }

    private func clearAllContent() {
        guard !annotations.isEmpty || !overlayImages.isEmpty else { return }

        recordHistoryCheckpoint()
        annotations = []
        overlayImages = []
        selectedAnnotationID = nil
        selectedOverlayImageID = nil
        propertyEditorSelection = nil
        selectedTool = .select
        pendingMosaicStrokes = []
        nextLayerOrder = 1
    }

    private func duplicateAnnotation(_ source: Annotation) {
        guard let selectedImageAsset else { return }
        let originalImageSize = selectedImageAsset.originalImageSize

        let offset = max(
            min(originalImageSize.width, originalImageSize.height) * 0.03,
            12
        )
        let copy: Annotation
        let copyLayerOrder = source.type == .mosaic
            ? 0
            : allocateLayerOrder()

        switch source.type {
        case .rectangle, .ellipse:
            copy = Annotation(
                type: source.type,
                x: duplicatedCoordinate(
                    source.x,
                    length: source.width,
                    limit: originalImageSize.width,
                    offset: offset
                ),
                y: duplicatedCoordinate(
                    source.y,
                    length: source.height,
                    limit: originalImageSize.height,
                    offset: offset
                ),
                width: source.width,
                height: source.height,
                color: source.color,
                strokeWidth: source.strokeWidth,
                note: source.note,
                layerOrder: copyLayerOrder
            )

        case .line, .arrow:
            let deltaX = duplicatedArrowOffset(
                firstCoordinate: source.startX,
                secondCoordinate: source.endX,
                limit: originalImageSize.width,
                offset: offset
            )
            let deltaY = duplicatedArrowOffset(
                firstCoordinate: source.startY,
                secondCoordinate: source.endY,
                limit: originalImageSize.height,
                offset: offset
            )
            copy = Annotation(
                type: source.type,
                startX: source.startX + deltaX,
                startY: source.startY + deltaY,
                endX: source.endX + deltaX,
                endY: source.endY + deltaY,
                color: source.color,
                strokeWidth: source.strokeWidth,
                note: source.note,
                layerOrder: copyLayerOrder
            )

        case .mosaic:
            copy = Annotation(
                mosaicStrokes: source.mosaicStrokes.map { stroke in
                    MosaicStroke(
                        points: stroke.points,
                        brushSize: stroke.brushSize,
                        pixelSize: stroke.pixelSize,
                        target: stroke.target
                    )
                }
            )
        }

        recordHistoryCheckpoint()
        annotations.append(copy)
        selectedAnnotationID = copy.id
        selectedOverlayImageID = nil
    }

    private var editorHint: String {
        if selectedOverlayImageID != nil {
            return strings.overlayGestureHint
        }

        return strings.toolHint(selectedTool)
    }

    @MainActor
    private func loadOverlayImage(from photo: PhotosPickerItem) async {
        guard let selectedImageAsset else {
            selectedOverlayPhoto = nil
            return
        }

        isLoadingOverlayImage = true
        defer {
            isLoadingOverlayImage = false
            selectedOverlayPhoto = nil
            overlayImageLoadTask = nil
        }

        guard let pickedImageFile = try? await photo.loadTransferable(
            type: PickedImageFile.self
        ) else {
            showOverlayLoadFailure()
            return
        }

        guard !Task.isCancelled else {
            try? FileManager.default.removeItem(at: pickedImageFile.fileURL)
            return
        }

        let overlayAsset = await Task.detached(
            priority: .userInitiated
        ) { () -> EditableImageAsset? in
            do {
                return try ImageAssetLoader.makeEditableAsset(
                    from: pickedImageFile.fileURL
                )
            } catch {
                try? FileManager.default.removeItem(
                    at: pickedImageFile.fileURL
                )
                return nil
            }
        }.value

        guard !Task.isCancelled, let overlayAsset else {
            if !Task.isCancelled {
                showOverlayLoadFailure()
            }
            return
        }

        guard self.selectedImageAsset === selectedImageAsset else {
            return
        }

        let mainSize = selectedImageAsset.originalImageSize
        let sourceSize = overlayAsset.originalImageSize
        let initialScale = min(
            mainSize.width * 0.4 / sourceSize.width,
            mainSize.height * 0.4 / sourceSize.height
        )
        let layer = OverlayImageLayer(
            imageAsset: overlayAsset,
            centerX: mainSize.width / 2,
            centerY: mainSize.height / 2,
            width: sourceSize.width * initialScale,
            height: sourceSize.height * initialScale,
            layerOrder: allocateLayerOrder()
        )

        recordHistoryCheckpoint()
        overlayImages.append(layer)
        selectedTool = .select
        selectedAnnotationID = nil
        selectedOverlayImageID = layer.id
    }

    private func showOverlayLoadFailure() {
        notice = EditorNotice(
            title: strings.imageLoadFailed,
            message: strings.overlayLoadFailureMessage
        )
    }

    private func deleteSelectedOverlayImage() {
        guard let selectedOverlayImageID else { return }

        recordHistoryCheckpoint()
        overlayImages.removeAll(where: { $0.id == selectedOverlayImageID })
        annotations = annotations.compactMap { annotation in
            guard annotation.type == .mosaic else { return annotation }

            var updatedAnnotation = annotation
            updatedAnnotation.mosaicStrokes.removeAll {
                $0.target == .overlayImage(selectedOverlayImageID)
            }
            return updatedAnnotation.mosaicStrokes.isEmpty
                ? nil
                : updatedAnnotation
        }
        pendingMosaicStrokes.removeAll {
            $0.target == .overlayImage(selectedOverlayImageID)
        }
        self.selectedOverlayImageID = nil
    }

    private func duplicateSelectedOverlayImage() {
        guard let selectedOverlayImageID,
              let selectedImageAsset,
              let source = overlayImages.first(
                where: { $0.id == selectedOverlayImageID }
              ) else {
            return
        }

        let imageSize = selectedImageAsset.originalImageSize
        let offset = max(min(imageSize.width, imageSize.height) * 0.03, 12)
        let copy = OverlayImageLayer(
            imageAsset: source.imageAsset,
            centerX: min(source.centerX + offset, imageSize.width),
            centerY: min(source.centerY + offset, imageSize.height),
            width: source.width,
            height: source.height,
            rotation: source.rotation,
            layerOrder: allocateLayerOrder()
        )

        recordHistoryCheckpoint()
        overlayImages.append(copy)
        self.selectedOverlayImageID = copy.id
        selectedAnnotationID = nil
        selectedTool = .select
    }

    private var currentSnapshot: EditorSnapshot {
        EditorSnapshot(
            annotations: annotations,
            overlayImages: overlayImages
        )
    }

    private func allocateLayerOrder() -> Int {
        let layerOrder = nextLayerOrder
        nextLayerOrder += 1
        return layerOrder
    }

    private func recordHistoryCheckpoint() {
        history.record(currentSnapshot)
    }

    private func undo() {
        commitPendingMosaicStrokes()
        guard let snapshot = history.undo(current: currentSnapshot) else { return }
        restore(snapshot)
    }

    private func redo() {
        commitPendingMosaicStrokes()
        guard let snapshot = history.redo(current: currentSnapshot) else { return }
        restore(snapshot)
    }

    private func restore(_ snapshot: EditorSnapshot) {
        annotations = snapshot.annotations
        overlayImages = snapshot.overlayImages
        selectedAnnotationID = nil
        selectedOverlayImageID = nil
        propertyEditorSelection = nil
        selectedTool = .select
        pendingMosaicStrokes = []
        let highestLayerOrder = max(
            annotations.map(\.layerOrder).max() ?? 0,
            overlayImages.map(\.layerOrder).max() ?? 0
        )
        nextLayerOrder = max(nextLayerOrder, highestLayerOrder + 1)
    }

    private func duplicatedCoordinate(
        _ coordinate: CGFloat,
        length: CGFloat,
        limit: CGFloat,
        offset: CGFloat
    ) -> CGFloat {
        if coordinate + length + offset <= limit {
            return coordinate + offset
        }

        return max(coordinate - offset, 0)
    }

    private func duplicatedArrowOffset(
        firstCoordinate: CGFloat,
        secondCoordinate: CGFloat,
        limit: CGFloat,
        offset: CGFloat
    ) -> CGFloat {
        let minimumCoordinate = min(firstCoordinate, secondCoordinate)
        let maximumCoordinate = max(firstCoordinate, secondCoordinate)

        if maximumCoordinate + offset <= limit {
            return offset
        }

        if minimumCoordinate - offset >= 0 {
            return -offset
        }

        return 0
    }
}

#Preview {
    NavigationStack {
        EditorView()
    }
}
