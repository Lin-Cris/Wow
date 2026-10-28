import Photos
import SwiftUI

private struct ExportNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct NativeShareSheet: UIViewControllerRepresentable {
    let artifact: ExportedImageArtifact
    let onCompletion: () -> Void

    func makeUIViewController(
        context: Context
    ) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: [artifact.fileURL],
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = { _, _, _, _ in
            DispatchQueue.main.async {
                onCompletion()
            }
        }
        return controller
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}

struct ExportView: View {
    let imageAsset: EditableImageAsset
    let annotations: [Annotation]
    let overlayImages: [OverlayImageLayer]

    @AppStorage(AppLanguage.storageKey)
    private var languageRawValue = AppLanguage.defaultValue.rawValue
    @State private var artifact: ExportedImageArtifact?
    @State private var hasStartedExport = false
    @State private var isPreparing = true
    @State private var isSaving = false
    @State private var isSharePresented = false
    @State private var saveTask: Task<Void, Never>?
    @State private var notice: ExportNotice?

    private var strings: AppStrings {
        AppStrings(rawValue: languageRawValue)
    }

    var body: some View {
        VStack(spacing: 20) {
            RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous)
                .fill(AppTheme.surface)
                .overlay {
                    if let artifact {
                        Image(uiImage: artifact.previewImage)
                            .resizable()
                            .scaledToFit()
                            .padding(8)
                    } else if isPreparing {
                        ProgressView(strings.preparingExport)
                            .tint(AppTheme.accent)
                    } else {
                        ContentUnavailableView(
                            strings.exportFailed,
                            systemImage: "exclamationmark.triangle",
                            description: Text(strings.exportRetryMessage)
                        )
                    }
                }
                .warmCard()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let artifact {
                Text(exportResolutionText(for: artifact.pixelSize))
                    .font(.caption)
                    .foregroundStyle(AppTheme.tertiaryText)
            }

            Button {
                saveToPhotos()
            } label: {
                WarmPrimaryButtonLabel(
                    title: isSaving ? strings.saving : strings.saveToPhotos,
                    systemImage: "square.and.arrow.down"
                )
            }
            .buttonStyle(.plain)
            .disabled(artifact == nil || isSaving)

            Button {
                isSharePresented = true
            } label: {
                Label(strings.shareImage, systemImage: "square.and.arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppTheme.primaryText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(AppTheme.surface)
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: AppTheme.controlCornerRadius,
                            style: .continuous
                        )
                    )
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: AppTheme.controlCornerRadius,
                            style: .continuous
                        )
                        .stroke(AppTheme.border.opacity(0.7), lineWidth: 0.8)
                    }
            }
            .buttonStyle(.plain)
            .disabled(artifact == nil || isSharePresented)
        }
        .padding()
        .background(WarmPageBackground())
        .navigationTitle(strings.export)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(AppTheme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task {
            await prepareExport()
        }
        .sheet(isPresented: $isSharePresented) {
            if let artifact {
                NativeShareSheet(artifact: artifact) {
                    isSharePresented = false
                }
            }
        }
        .alert(item: $notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text(strings.okay))
            )
        }
    }

    @MainActor
    private func prepareExport() async {
        guard !hasStartedExport else { return }

        hasStartedExport = true
        isPreparing = true
        let imageAsset = imageAsset
        let annotations = annotations
        let overlayImages = overlayImages
        let worker = Task.detached(priority: .userInitiated) {
            AnnotatedImageRenderer.render(
                imageAsset: imageAsset,
                annotations: annotations,
                overlayImages: overlayImages
            )
        }

        let result = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }

        guard !Task.isCancelled else { return }

        artifact = result
        isPreparing = false
    }

    @MainActor
    private func saveToPhotos() {
        guard saveTask == nil, let artifact else { return }

        saveTask = Task {
            isSaving = true
            defer {
                isSaving = false
                saveTask = nil
            }

            let authorization = await PHPhotoLibrary.requestAuthorization(
                for: .addOnly
            )

            guard authorization == .authorized || authorization == .limited else {
                notice = ExportNotice(
                    title: strings.unableToSave,
                    message: strings.photoPermissionMessage
                )
                return
            }

            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(
                        atFileURL: artifact.fileURL
                    )
                }

                notice = ExportNotice(
                    title: strings.saveSucceeded,
                    message: strings.saveSucceededMessage
                )
            } catch {
                notice = ExportNotice(
                    title: strings.saveFailed,
                    message: strings.saveFailedMessage
                )
            }
        }
    }

    private func exportResolutionText(for pixelSize: CGSize) -> String {
        strings.exportResolution(
            width: Int(pixelSize.width),
            height: Int(pixelSize.height)
        )
    }
}
