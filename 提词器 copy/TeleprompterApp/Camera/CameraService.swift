import AVFoundation
import Combine
import Foundation
import Photos

final class CameraService: NSObject, ObservableObject, @unchecked Sendable {
    enum State: Equatable {
        case idle
        case requestingPermission
        case running
        case simulatorPlaceholder
        case denied
        case failed(String)
    }

    struct Notice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var isRecording = false
    @Published private(set) var isPreparingRecording = false
    @Published private(set) var isStoppingRecording = false
    @Published private(set) var isSavingRecording = false
    @Published var notice: Notice?

    // Video-only capture must never configure or activate the application's
    // audio session; background calls and audio belong to the other app.
    let session: AVCaptureSession = {
        let session = AVCaptureSession()
        session.automaticallyConfiguresApplicationAudioSession = false
        return session
    }()

    private let sessionQueue = DispatchQueue(label: "com.chris.teleprompter.camera")
    private let movieOutput = AVCaptureMovieFileOutput()
    private var isConfigured = false
    private var shouldBeRunning = false
    private var stopSessionAfterRecording = false
    private var recordingRequestID: UUID?

    @MainActor
    func start() {
#if targetEnvironment(simulator)
        state = .simulatorPlaceholder
#else
        sessionQueue.async { [weak self] in
            self?.shouldBeRunning = true
        }

        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)

        if cameraStatus == .denied || cameraStatus == .restricted {
            state = .denied
            return
        }

        if cameraStatus == .authorized {
            configureAndStart()
            return
        }

        state = .requestingPermission
        Task { @MainActor [weak self] in
            guard let self else { return }

            let cameraAllowed = await Self.requestAccess(for: .video)
            guard cameraAllowed else {
                self.state = .denied
                return
            }

            self.configureAndStart()
        }
#endif
    }

    @MainActor
    func stop() {
        recordingRequestID = nil
        isPreparingRecording = false

#if targetEnvironment(simulator)
        isRecording = false
        isStoppingRecording = false
#else
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.shouldBeRunning = false

            if self.movieOutput.isRecording {
                self.stopSessionAfterRecording = true
                DispatchQueue.main.async { [weak self] in
                    self?.isStoppingRecording = true
                }
                self.movieOutput.stopRecording()
            } else if self.session.isRunning {
                self.session.stopRunning()
            }
        }
#endif
    }

    @MainActor
    func startRecording(videoRotationAngle: CGFloat) {
        guard !isRecording, !isPreparingRecording, !isSavingRecording else { return }

        let requestID = UUID()
        recordingRequestID = requestID
        isPreparingRecording = true

#if targetEnvironment(simulator)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, self.recordingRequestID == requestID else { return }
            self.recordingRequestID = nil
            self.isPreparingRecording = false
            self.isRecording = true
        }
#else
        guard state == .running else {
            recordingRequestID = nil
            isPreparingRecording = false
            notice = Notice(title: "无法开始录像", message: "前置摄像头尚未准备完成。")
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let photoAccessAllowed = await Self.requestPhotoLibraryAddAccess()

            guard self.recordingRequestID == requestID else { return }
            guard photoAccessAllowed else {
                self.recordingRequestID = nil
                self.isPreparingRecording = false
                self.notice = Notice(
                    title: "无法保存录像",
                    message: "请在系统设置中允许提词器添加视频到相册。"
                )
                return
            }

            self.sessionQueue.async { [weak self] in
                guard let self else { return }
                guard self.session.isRunning, !self.movieOutput.isRecording else {
                    DispatchQueue.main.async { [weak self] in
                        self?.recordingRequestID = nil
                        self?.isPreparingRecording = false
                    }
                    return
                }

                if let connection = self.movieOutput.connection(with: .video) {
                    if connection.isVideoRotationAngleSupported(videoRotationAngle) {
                        connection.videoRotationAngle = videoRotationAngle
                    }
                    if connection.isVideoMirroringSupported {
                        connection.automaticallyAdjustsVideoMirroring = false
                        connection.isVideoMirrored = true
                    }
                }

                let outputURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("teleprompter-\(UUID().uuidString)")
                    .appendingPathExtension("mov")
                self.stopSessionAfterRecording = false
                self.movieOutput.startRecording(to: outputURL, recordingDelegate: self)
            }
        }
#endif
    }

    @MainActor
    func stopRecording() {
        recordingRequestID = nil
        isPreparingRecording = false

#if targetEnvironment(simulator)
        isRecording = false
        isStoppingRecording = false
#else
        guard isRecording || isStoppingRecording else { return }
        isStoppingRecording = true

        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.isRecording = false
                    self?.isStoppingRecording = false
                }
            }
        }
#endif
    }

    private func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            if !self.isConfigured {
                do {
                    try self.configureSession()
                } catch {
                    DispatchQueue.main.async { [weak self] in
                        self?.state = .failed(error.localizedDescription)
                    }
                    return
                }
            }

            guard self.shouldBeRunning else { return }
            if !self.session.isRunning {
                self.session.startRunning()
            }

            DispatchQueue.main.async { [weak self] in
                self?.state = .running
            }
        }
    }

    private func configureSession() throws {
        guard let camera = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .front
        ) else {
            throw CameraError.frontCameraUnavailable
        }

        let cameraInput = try AVCaptureDeviceInput(device: camera)

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .high

        guard session.canAddInput(cameraInput) else {
            throw CameraError.cannotAddCameraInput
        }
        guard session.canAddOutput(movieOutput) else {
            throw CameraError.cannotAddMovieOutput
        }

        session.addInput(cameraInput)
        session.addOutput(movieOutput)
        isConfigured = true
    }

    private static func requestAccess(for mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: mediaType) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private static func requestPhotoLibraryAddAccess() async -> Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let status = await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                    continuation.resume(returning: status)
                }
            }
            return status == .authorized || status == .limited
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func saveRecording(at outputURL: URL) {
        DispatchQueue.main.async { [weak self] in
            self?.isSavingRecording = true
        }

        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: outputURL)
        } completionHandler: { [weak self] saved, error in
            try? FileManager.default.removeItem(at: outputURL)

            DispatchQueue.main.async {
                guard let self else { return }
                self.isSavingRecording = false
                if saved {
                    self.notice = Notice(title: "录像已保存", message: "视频已保存到系统相册。")
                } else {
                    self.notice = Notice(
                        title: "保存失败",
                        message: error?.localizedDescription ?? "无法将视频保存到系统相册。"
                    )
                }
            }
        }
    }

    private func finishSessionStopIfNeeded() {
        sessionQueue.async { [weak self] in
            guard let self, self.stopSessionAfterRecording else { return }
            self.stopSessionAfterRecording = false
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }
}

extension CameraService: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.recordingRequestID = nil
            self?.isPreparingRecording = false
            self?.isStoppingRecording = false
            self?.isRecording = true
        }
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        let recordingSucceeded: Bool
        if let error = error as NSError? {
            recordingSucceeded = error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true
        } else {
            recordingSucceeded = true
        }

        DispatchQueue.main.async { [weak self] in
            self?.recordingRequestID = nil
            self?.isPreparingRecording = false
            self?.isStoppingRecording = false
            self?.isRecording = false
        }

        if recordingSucceeded {
            saveRecording(at: outputFileURL)
        } else {
            try? FileManager.default.removeItem(at: outputFileURL)
            DispatchQueue.main.async { [weak self] in
                self?.notice = Notice(
                    title: "录像失败",
                    message: error?.localizedDescription ?? "视频录制未能完成。"
                )
            }
        }

        finishSessionStopIfNeeded()
    }
}

private enum CameraError: LocalizedError {
    case frontCameraUnavailable
    case cannotAddCameraInput
    case cannotAddMovieOutput

    var errorDescription: String? {
        switch self {
        case .frontCameraUnavailable:
            "找不到前置摄像头。"
        case .cannotAddCameraInput:
            "无法连接前置摄像头。"
        case .cannotAddMovieOutput:
            "无法配置视频录像。"
        }
    }
}
