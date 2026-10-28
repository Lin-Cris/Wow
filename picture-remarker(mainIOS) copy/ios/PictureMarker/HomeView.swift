import AVFoundation
import PhotosUI
import SwiftUI
import UIKit

private struct CameraNotice: Identifiable {
    let id = UUID()
    let message: String
}

private struct BotanicalBranch: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX * 0.84, y: rect.maxY))
        path.addCurve(
            to: CGPoint(x: rect.minX + rect.width * 0.24, y: rect.minY),
            control1: CGPoint(x: rect.maxX * 0.48, y: rect.maxY * 0.72),
            control2: CGPoint(x: rect.minX + rect.width * 0.18, y: rect.maxY * 0.35)
        )

        let leaves: [(CGFloat, CGFloat, CGFloat)] = [
            (0.64, 0.72, -22),
            (0.49, 0.53, 24),
            (0.35, 0.34, -18),
            (0.25, 0.18, 20)
        ]

        for (x, y, angle) in leaves {
            let center = CGPoint(x: rect.width * x, y: rect.height * y)
            let leafRect = CGRect(
                x: center.x - rect.width * 0.11,
                y: center.y - rect.height * 0.045,
                width: rect.width * 0.22,
                height: rect.height * 0.09
            )
            path.addEllipse(
                in: leafRect,
                transform: CGAffineTransform(
                    translationX: center.x,
                    y: center.y
                )
                .rotated(by: angle * .pi / 180)
                .translatedBy(x: -center.x, y: -center.y)
            )
        }

        return path
    }
}

private struct HomeBrandHero: View {
    let compact: Bool

    private var iconSize: CGFloat {
        compact ? 118 : 136
    }

    var body: some View {
        ZStack {
            BotanicalBranch()
                .stroke(
                    AppTheme.decoration.opacity(0.30),
                    style: StrokeStyle(lineWidth: 1.15, lineCap: .round)
                )
                .frame(width: 63, height: 105)
                .offset(x: -100, y: 37)

            BotanicalBranch()
                .stroke(
                    AppTheme.decoration.opacity(0.25),
                    style: StrokeStyle(lineWidth: 1.05, lineCap: .round)
                )
                .frame(width: 58, height: 98)
                .scaleEffect(x: -1, y: 1)
                .offset(x: 101, y: 39)

            sparkle(size: 9)
                .offset(x: -91, y: -54)

            sparkle(size: 6)
                .offset(x: 88, y: -70)

            sparkle(size: 5)
                .offset(x: 113, y: -30)

            Image("BrandIcon")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: iconSize * 0.23,
                        style: .continuous
                    )
                )
                .shadow(color: AppTheme.accent.opacity(0.10), radius: 17, y: 9)
        }
        .frame(width: 280, height: compact ? 160 : 185)
        .accessibilityHidden(true)
    }

    private func sparkle(size: CGFloat) -> some View {
        Image(systemName: "sparkle")
            .font(.system(size: size, weight: .light))
            .foregroundStyle(AppTheme.decoration.opacity(0.42))
    }
}

struct HomeView: View {
    @AppStorage(AppLanguage.storageKey)
    private var languageRawValue = AppLanguage.defaultValue.rawValue
    @State private var isSettingsPresented = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var capturedImageFileURL: URL?
    @State private var isCameraPresented = false
    @State private var isEditorPresented = false
    @State private var cameraNotice: CameraNotice?

    private var strings: AppStrings {
        AppStrings(rawValue: languageRawValue)
    }

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.height < 700

            ZStack {
                WarmPageBackground()

                VStack(spacing: 0) {
                    Spacer(minLength: compact ? 8 : 24)

                    HomeBrandHero(compact: compact)

                    VStack(spacing: compact ? 8 : 10) {
                        Text("Picture Marker")
                            .font(
                                .system(
                                    size: compact ? 34 : 39,
                                    weight: .medium,
                                    design: .serif
                                )
                            )
                            .tracking(0.25)
                            .foregroundStyle(AppTheme.primaryText)
                            .minimumScaleFactor(0.82)

                        Text(strings.appSubtitle)
                            .font(.system(size: 16, weight: .regular, design: .rounded))
                            .foregroundStyle(AppTheme.secondaryText)

                        Text(strings.homeDescription)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(AppTheme.tertiaryText)
                            .multilineTextAlignment(.center)
                            .padding(.top, compact ? 1 : 4)
                    }
                    .padding(.top, compact ? 4 : 8)

                    HStack(spacing: 12) {
                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            WarmPrimaryButtonLabel(
                                title: strings.photo,
                                systemImage: "photo.on.rectangle"
                            )
                        }
                        .buttonStyle(.plain)

                        Button {
                            openCamera()
                        } label: {
                            WarmPrimaryButtonLabel(
                                title: strings.camera,
                                systemImage: "camera"
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(width: 330)
                    .padding(.horizontal, 22)
                    .padding(.top, compact ? 26 : 38)

                    Spacer(minLength: compact ? 24 : 54)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(AppTheme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isSettingsPresented = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14, weight: .light))
                        .foregroundStyle(AppTheme.secondaryText)
                        .frame(width: 30, height: 30)
                        .background(AppTheme.surface.opacity(0.78))
                        .clipShape(Circle())
                }
                .accessibilityLabel(strings.settings)
            }
        }
        .sheet(isPresented: $isSettingsPresented) {
            LanguageSettingsView()
        }
        .fullScreenCover(isPresented: $isCameraPresented) {
            NativeCameraPicker(
                isPresented: $isCameraPresented,
                onCapture: { capturedImageFileURL = $0 },
                onFailure: {
                    cameraNotice = CameraNotice(
                        message: strings.capturedPhotoLoadFailedMessage
                    )
                }
            )
            .ignoresSafeArea()
        }
        .navigationDestination(isPresented: $isEditorPresented) {
            if let selectedPhoto {
                EditorView(initialPhoto: selectedPhoto)
            } else if let capturedImageFileURL {
                EditorView(initialImageFileURL: capturedImageFileURL)
            }
        }
        .onChange(of: selectedPhoto) { _, newPhoto in
            isEditorPresented = newPhoto != nil
        }
        .onChange(of: isCameraPresented) { _, isPresented in
            if !isPresented, capturedImageFileURL != nil {
                isEditorPresented = true
            }
        }
        .onChange(of: isEditorPresented) { _, isPresented in
            if !isPresented {
                selectedPhoto = nil
                capturedImageFileURL = nil
            }
        }
        .alert(item: $cameraNotice) { notice in
            Alert(
                title: Text(strings.cameraUnavailable),
                message: Text(notice.message),
                dismissButton: .default(Text(strings.okay))
            )
        }
    }

    private func openCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            cameraNotice = CameraNotice(
                message: strings.cameraNotAvailableMessage
            )
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            isCameraPresented = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        isCameraPresented = true
                    } else {
                        cameraNotice = CameraNotice(
                            message: strings.cameraPermissionMessage
                        )
                    }
                }
            }
        case .denied, .restricted:
            cameraNotice = CameraNotice(
                message: strings.cameraPermissionMessage
            )
        @unknown default:
            cameraNotice = CameraNotice(
                message: strings.cameraCurrentlyUnavailableMessage
            )
        }
    }
}

#Preview {
    NavigationStack {
        HomeView()
    }
}

private struct NativeCameraPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onCapture: (URL) -> Void
    let onFailure: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(
        _ uiViewController: UIImagePickerController,
        context: Context
    ) {}

    final class Coordinator: NSObject,
        UIImagePickerControllerDelegate,
        UINavigationControllerDelegate {
        private let parent: NativeCameraPicker

        init(parent: NativeCameraPicker) {
            self.parent = parent
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.isPresented = false
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            defer { parent.isPresented = false }

            guard let image = info[.originalImage] as? UIImage,
                  let imageData = image.jpegData(compressionQuality: 1) else {
                parent.onFailure()
                return
            }

            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("Picture-Marker-Camera-\(UUID().uuidString)")
                .appendingPathExtension("jpg")

            do {
                try imageData.write(to: fileURL, options: .atomic)
                parent.onCapture(fileURL)
            } catch {
                parent.onFailure()
            }
        }
    }
}
