import Combine
import SwiftUI

struct TeleprompterView: View {
    let script: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @StateObject private var cameraService = CameraService()
    @State private var isScrolling = false
    @State private var scrollSpeed = 18.0
    @State private var preferences = TeleprompterPreferences.load()
    @State private var readingPosition = 0.0
    @State private var startPointPosition = 0.0
    @State private var hasStartPoint = false
    @State private var recordingStartedAt: Date?
    @State private var recordingElapsed = 0.0
    @State private var areAdjustmentsVisible = false
    @State private var appIsActive = true
    @State private var viewportSize = CGSize.zero
    @State private var deviceOrientation = UIDevice.current.orientation
    @State private var isVisible = false
    @State private var screenAwake = TeleprompterScreenAwake()
    @State private var controlsHeight: CGFloat = 0

    private let recordingTimer = Timer.publish(
        every: 0.25,
        on: .main,
        in: .common
    ).autoconnect()

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                cameraBackground
                    .ignoresSafeArea()

                floatingPrompt(in: geometry)

                if isCompactLayout {
                    landscapeLayout(in: geometry)
                } else {
                    portraitLayout(in: geometry)
                }
            }
            .onAppear { viewportSize = geometry.size }
            .onChange(of: geometry.size) { _, size in viewportSize = size }
            .onPreferenceChange(TeleprompterControlsHeightKey.self) { controlsHeight = $0 }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden()
        .onAppear {
            isVisible = true
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            deviceOrientation = UIDevice.current.orientation
            appIsActive = UIApplication.shared.applicationState == .active
            cameraService.start()
#if DEBUG
            scheduleDebugOrientationTestIfNeeded()
#endif
        }
        .onDisappear {
            isVisible = false
            screenAwake.setEnabled(false)
            preferences.save()
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            isScrolling = false
            cameraService.stop()
        }
        // Wow's UIKit hosting controller does not supply a SwiftUI Scene.
        // UIApplication notifications also work for the standalone SwiftUI app.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            appIsActive = true
            cameraService.start()
            isScrolling = cameraService.isRecording
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            appIsActive = false
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            appIsActive = false
            isScrolling = false
            cameraService.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            let orientation = UIDevice.current.orientation
            if orientation.isPortrait || orientation.isLandscape {
                deviceOrientation = orientation
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                cameraService.start()
                isScrolling = cameraService.isRecording
            case .background:
                isScrolling = false
                cameraService.stop()
            case .inactive:
                isScrolling = false
            @unknown default:
                break
            }
        }
        .onChange(of: cameraService.isRecording) { _, isRecording in
            if isRecording {
                recordingElapsed = 0
                recordingStartedAt = Date()
            } else if let recordingStartedAt {
                recordingElapsed = Date().timeIntervalSince(recordingStartedAt)
                self.recordingStartedAt = nil
            }
            isScrolling = isRecording
        }
        .onChange(of: shouldKeepScreenAwake) { _, enabled in
            screenAwake.setEnabled(enabled)
        }
        .onChange(of: preferences.fontSize) { _, _ in preferences.save() }
        .onReceive(recordingTimer) { now in
            guard cameraService.isRecording, let recordingStartedAt else { return }
            recordingElapsed = now.timeIntervalSince(recordingStartedAt)
        }
        .alert(item: $cameraService.notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("好"))
            )
        }
    }

    private var isCompactLayout: Bool {
        verticalSizeClass == .compact || (viewportSize.width > viewportSize.height && UIDevice.current.userInterfaceIdiom == .phone)
    }

    private var shouldKeepScreenAwake: Bool {
        isVisible && appIsActive && (
            cameraService.isPreparingRecording
                || cameraService.isRecording
                || cameraService.isStoppingRecording
        )
    }

    private func portraitLayout(in geometry: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 16)

            cameraStatus
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            controls
        }
    }

    private func landscapeLayout(in geometry: GeometryProxy) -> some View {
        HStack(spacing: 12) {
            if cameraOnLeadingSide(in: geometry) {
                landscapeReadingLane(in: geometry, alignment: .leading)
                landscapeControls(in: geometry)
            } else {
                landscapeControls(in: geometry)
                landscapeReadingLane(in: geometry, alignment: .trailing)
            }
        }
    }

    private func cameraOnLeadingSide(in geometry: GeometryProxy) -> Bool {
        if deviceOrientation.isLandscape {
            return currentVideoRotationAngle == 180
        }
        if geometry.safeAreaInsets.leading != geometry.safeAreaInsets.trailing {
            return geometry.safeAreaInsets.leading > geometry.safeAreaInsets.trailing
        }
        return currentVideoRotationAngle == 180
    }

    private func landscapeReadingLane(in geometry: GeometryProxy, alignment: Alignment) -> some View {
        Color.clear
            .allowsHitTesting(false)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .overlay(alignment: .bottom) {
                cameraStatus.padding(12)
            }
    }

    private func landscapeControls(in geometry: GeometryProxy) -> some View {
        ScrollView(.vertical) {
            controls
                .padding(.top, 8)
                .padding(.bottom, 8)
        }
        .scrollIndicators(.hidden)
        .frame(width: min(290, max(230, geometry.size.width * 0.35)))
        .padding(.horizontal, 8)
    }

    private func floatingPrompt(in geometry: GeometryProxy) -> some View {
        let canvas = readingCanvas(in: geometry)
        let key = isCompactLayout ? (cameraOnLeadingSide(in: geometry) ? "landscapeLeading" : "landscapeTrailing") : "portrait"
        let defaultFrame = TeleprompterFloatingLayout.defaultFrame(
            in: canvas,
            shortEdge: min(geometry.size.width, geometry.size.height),
            landscape: isCompactLayout,
            cameraLeading: cameraOnLeadingSide(in: geometry)
        )
        let frame = preferences.layouts[key]?.frame(in: canvas) ?? defaultFrame
        return TeleprompterTextView(
            script: script,
            fontSize: preferences.fontSize,
            focusAtCenter: isCompactLayout,
            scrollSpeed: scrollSpeed,
            isScrolling: isScrolling && appIsActive,
            windowFrame: frame,
            canvas: canvas,
            showsLayoutControls: areAdjustmentsVisible,
            position: $readingPosition,
            onManualScrollChanged: handleManualScrollChanged,
            onReachedEnd: { isScrolling = false },
            onFrameChanged: { preferences.layouts[key] = TeleprompterFloatingLayout(frame: $0, in: canvas) },
            onLayoutInteractionChanged: { active in
                handleManualScrollChanged(active)
                if !active { preferences.save() }
            }
        )
        .frame(width: frame.width, height: frame.height)
        .position(x: frame.midX, y: frame.midY)
    }

    private func readingCanvas(in geometry: GeometryProxy) -> CGRect {
        let size = geometry.size
        if isCompactLayout {
            let panelWidth = min(290, max(230, size.width * 0.35)) + 28
            return CGRect(
                x: cameraOnLeadingSide(in: geometry) ? 8 : panelWidth,
                y: 8,
                width: max(1, size.width - panelWidth - 8),
                height: max(1, size.height - 16)
            )
        }
        // Reserve recording controls even before REC appears, so starting a
        // take does not move the reading focus. Expanded adjustments may use more.
        return CGRect(x: 8, y: 8, width: max(1, size.width - 16), height: max(1, size.height - max(280, controlsHeight) - 24))
    }

    private func handleManualScrollChanged(_ isDragging: Bool) {
        if isDragging {
            isScrolling = false
        } else {
            isScrolling = cameraService.isRecording
        }
    }

    @ViewBuilder
    private var cameraBackground: some View {
        if cameraService.state == .simulatorPlaceholder {
            SimulatorCameraPlaceholder()
        } else {
            Color.black
            CameraPreview(session: cameraService.session)
        }
    }

    private var backButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "chevron.left")
                .font(.headline)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.bordered)
        .tint(.white)
        .accessibilityLabel("返回")
        .disabled(
            cameraService.isRecording
                || cameraService.isPreparingRecording
                || cameraService.isStoppingRecording
        )
    }

    private var recordingStatus: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(.red)
                .frame(width: 9, height: 9)

            Text("REC \(formattedRecordingTime)")
                .font(.subheadline.monospacedDigit().bold())
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(.black.opacity(0.7), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("正在录像，已录制 \(formattedRecordingTime)")
        .accessibilityIdentifier("recordingStatus")
    }

    private var formattedRecordingTime: String {
        let totalSeconds = max(0, Int(recordingElapsed))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    @ViewBuilder
    private var cameraStatus: some View {
        switch cameraService.state {
        case .requestingPermission:
            statusCard("正在请求相机权限…")
        case .denied:
            VStack(spacing: 8) {
                Text("请在系统设置中允许访问相机。")
                Button("打开设置") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    openURL(url)
                }
                .font(.footnote.bold())
            }
            .frame(maxWidth: .infinity)
            .padding(12)
            .foregroundStyle(.white)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 14))
        case .failed(let message):
            statusCard(message)
        case .idle, .running, .simulatorPlaceholder:
            EmptyView()
        }
    }

    private func statusCard(_ message: String) -> some View {
        Text(message)
            .font(.footnote.weight(.medium))
            .frame(maxWidth: .infinity)
            .padding(12)
            .foregroundStyle(.white)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 14))
    }

    private var controls: some View {
        VStack(spacing: isCompactLayout ? 7 : 10) {
            if areAdjustmentsVisible {
                adjustmentPanel
            }

            HStack(spacing: 9) {
                backButton
                adjustmentToggleButton
                resetButton
            }

            startPointButton
            speedStepControl
            if cameraService.isRecording { recordingStatus }
            startPauseButton
        }
        .padding(isCompactLayout ? 10 : 12)
        .foregroundStyle(.white)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        }
        .padding(.horizontal, isCompactLayout ? 0 : 16)
        .padding(.bottom, isCompactLayout ? 0 : 10)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: TeleprompterControlsHeightKey.self, value: proxy.size.height)
            }
        }
    }

    private var adjustmentPanel: some View {
        VStack(spacing: 9) {
            Text("拖顶部柄移动 · 拖右下角调整大小")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.65))
            resetLayoutButton
            speedSlider
            fontSizeSlider
        }
        .padding(.bottom, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("adjustmentPanel")
    }

    private var adjustmentToggleButton: some View {
        Button {
            areAdjustmentsVisible.toggle()
        } label: {
            compactControlLabel(
                areAdjustmentsVisible ? "收起调整" : "字号 / 速度",
                systemImage: "slider.horizontal.3"
            )
        }
        .buttonStyle(.bordered)
        .tint(.white)
        .accessibilityLabel(areAdjustmentsVisible ? "收起调整" : "打开字号和速度调整")
        .accessibilityIdentifier("adjustmentToggleButton")
    }

    private var resetLayoutButton: some View {
        Button {
            preferences.layouts.removeAll()
            preferences.save()
        } label: {
            Label("恢复默认布局", systemImage: "rectangle.arrowtriangle.2.outward")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("resetLayoutButton")
    }

    private var startPauseButton: some View {
        Button {
            if cameraService.isRecording {
                isScrolling = false
                cameraService.stopRecording()
            } else {
                readingPosition = startPointPosition
                cameraService.startRecording(videoRotationAngle: currentVideoRotationAngle)
            }
        } label: {
            Label(
                cameraService.isRecording ? "停止录像" : "开始录像",
                systemImage: cameraService.isRecording ? "stop.fill" : "record.circle"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(cameraService.isRecording ? .red : .white)
        .foregroundStyle(cameraService.isRecording ? .white : .black)
        .disabled(
            cameraService.isPreparingRecording
                || cameraService.isStoppingRecording
                || cameraService.isSavingRecording
                || (cameraService.state != .running && cameraService.state != .simulatorPlaceholder)
        )
        .accessibilityIdentifier("startPauseButton")
    }

    private var startPointButton: some View {
        Button {
            startPointPosition = readingPosition
            hasStartPoint = startPointPosition > 0
            isScrolling = false
        } label: {
            Label(
                hasStartPoint ? "起点已设" : "设为起点",
                systemImage: hasStartPoint ? "bookmark.fill" : "bookmark"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.white)
        .disabled(
            cameraService.isRecording
                || cameraService.isPreparingRecording
                || cameraService.isStoppingRecording
                || cameraService.isSavingRecording
        )
        .accessibilityIdentifier("startPointButton")
    }

    private var resetButton: some View {
        Button {
            readingPosition = 0
            startPointPosition = 0
            hasStartPoint = false
            isScrolling = false
        } label: {
            compactControlLabel("重置", systemImage: "backward.end.fill")
        }
        .buttonStyle(.bordered)
        .tint(.white)
        .disabled(
            cameraService.isRecording
                || cameraService.isPreparingRecording
                || cameraService.isStoppingRecording
                || cameraService.isSavingRecording
        )
        .accessibilityLabel("重置阅读位置和起点")
        .accessibilityIdentifier("resetButton")
    }

    @ViewBuilder
    private func compactControlLabel(_ title: String, systemImage: String) -> some View {
        if isCompactLayout {
            Image(systemName: systemImage)
                .frame(maxWidth: .infinity)
        } else {
            Label(title, systemImage: systemImage)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
        }
    }

    private var currentVideoRotationAngle: CGFloat {
        let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        return TeleprompterCameraOrientation.rotationAngle(
            interfaceOrientation: windowScene?.interfaceOrientation,
            deviceOrientation: deviceOrientation
        )
    }

#if DEBUG
    private func scheduleDebugOrientationTestIfNeeded() {
        guard let orientationName = ProcessInfo.processInfo.environment["TELEPROMPTER_TEST_ORIENTATION"] else {
            return
        }

        let delay = Double(
            ProcessInfo.processInfo.environment["TELEPROMPTER_TEST_ORIENTATION_DELAY"] ?? "1"
        ) ?? 1

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))

            guard let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) else {
                return
            }

            let orientations: UIInterfaceOrientationMask = orientationName == "portrait"
                ? .portrait
                : .landscapeRight
            windowScene.requestGeometryUpdate(
                .iOS(interfaceOrientations: orientations)
            ) { error in
                assertionFailure("Debug orientation test failed: \(error.localizedDescription)")
            }
        }
    }
#endif

    private var speedSlider: some View {
        ControlSlider(
            title: "速度",
            systemImage: "speedometer",
            value: $scrollSpeed,
            range: 10...100,
            accessibilityIdentifier: "speedSlider"
        )
    }

    private var speedStepControl: some View {
        HStack(spacing: 14) {
            Button {
                scrollSpeed = max(10, scrollSpeed - 5)
            } label: {
                Image(systemName: "minus")
                    .frame(width: 40, height: 32)
            }
            .buttonStyle(.bordered)
            .disabled(scrollSpeed <= 10)
            .accessibilityLabel("降低滚动速度")
            .accessibilityIdentifier("decreaseSpeedButton")

            Text("\(scrollSpeed.formatted(.number.precision(.fractionLength(0)))) pt/s")
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .frame(minWidth: 76)
                .accessibilityLabel("当前滚动速度")
                .accessibilityValue(scrollSpeed.formatted(.number.precision(.fractionLength(0))))
                .accessibilityIdentifier("currentSpeedLabel")

            Button {
                scrollSpeed = min(100, scrollSpeed + 5)
            } label: {
                Image(systemName: "plus")
                    .frame(width: 40, height: 32)
            }
            .buttonStyle(.bordered)
            .disabled(scrollSpeed >= 100)
            .accessibilityLabel("提高滚动速度")
            .accessibilityIdentifier("increaseSpeedButton")
        }
    }

    private var fontSizeSlider: some View {
        ControlSlider(
            title: "字号",
            systemImage: "textformat.size",
            value: $preferences.fontSize,
            range: TeleprompterPreferences.fontSizeRange,
            accessibilityIdentifier: "fontSizeSlider"
        )
    }
}

// Size fractions and position within the remaining travel range survive reflow.
struct TeleprompterFloatingLayout: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var positionVersion: Int?

    static func moveHandleFrame(for frame: CGRect) -> CGRect {
        let width = min(76, frame.width)
        return CGRect(x: frame.midX - width / 2, y: frame.minY, width: width, height: min(28, frame.height))
    }

    init(frame: CGRect, in canvas: CGRect) {
        let frame = Self.clamp(frame, to: canvas)
        let handle = Self.moveHandleFrame(for: frame)
        width = Double(frame.width / max(1, canvas.width))
        height = Double(frame.height / max(1, canvas.height))
        x = Double((frame.midX - canvas.minX - handle.width / 2) / max(1, canvas.width - handle.width))
        y = Double((frame.minY - canvas.minY) / max(1, canvas.height - handle.height))
        positionVersion = 2
    }

    func frame(in canvas: CGRect) -> CGRect {
        let size = Self.clamp(CGRect(x: canvas.minX, y: canvas.minY, width: canvas.width * unit(width), height: canvas.height * unit(height)), to: canvas).size
        let origin: CGPoint
        if positionVersion == 2 {
            let handle = Self.moveHandleFrame(for: CGRect(origin: .zero, size: size))
            origin = CGPoint(
                x: canvas.minX + handle.width / 2 + (canvas.width - handle.width) * unit(x) - size.width / 2,
                y: canvas.minY + (canvas.height - handle.height) * unit(y)
            )
        } else {
            // Old saved layouts used the full-window travel range. Preserve
            // those positions until the user next adjusts and saves a v2 layout.
            origin = CGPoint(x: canvas.minX + (canvas.width - size.width) * unit(x), y: canvas.minY + (canvas.height - size.height) * unit(y))
        }
        return Self.clamp(CGRect(origin: origin, size: size), to: canvas)
    }

    static func clamp(_ frame: CGRect, to canvas: CGRect) -> CGRect {
        let width = min(canvas.width, max(min(120, canvas.width), frame.width.isFinite ? frame.width : 120))
        let height = min(canvas.height, max(min(80, canvas.height), frame.height.isFinite ? frame.height : 80))
        let handleWidth = min(76, width)
        let handleHeight = min(28, height)
        // Allow the body to cross an edge; keep the entire drag handle reachable.
        let minimumX = canvas.minX + (handleWidth - width) / 2
        let maximumX = canvas.maxX - (handleWidth + width) / 2
        let x = min(maximumX, max(minimumX, frame.minX.isFinite ? frame.minX : canvas.minX))
        let y = min(canvas.maxY - handleHeight, max(canvas.minY, frame.minY.isFinite ? frame.minY : canvas.minY))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func defaultFrame(in canvas: CGRect, shortEdge: CGFloat, landscape: Bool, cameraLeading: Bool) -> CGRect {
        // Container defaults are independent of the user's font size.
        let width = min(canvas.width, TeleprompterReadingLayout.columnWidth(shortEdge: shortEdge, fontSize: 34, available: canvas.width - 16) + 16)
        let height = min(canvas.height, landscape ? 220 : 280)
        let x = landscape ? (cameraLeading ? canvas.minX : canvas.maxX - width) : canvas.midX - width / 2
        let y = landscape ? canvas.midY - height / 2 : canvas.minY
        return clamp(CGRect(x: x, y: y, width: width, height: height), to: canvas)
    }

    private func unit(_ value: Double) -> CGFloat {
        value.isFinite ? CGFloat(min(1, max(0, value))) : 0.5
    }
}

struct TeleprompterPreferences: Codable, Equatable {
    var fontSize = 34.0
    var layouts: [String: TeleprompterFloatingLayout] = [:]
    static let storageKey = "teleprompter.floating-layout.v1"
    static let fontSizeRange: ClosedRange<Double> = 12...56

    private static var defaults: UserDefaults {
#if DEBUG
        if let suite = ProcessInfo.processInfo.environment["TELEPROMPTER_SETTINGS_SUITE"], let defaults = UserDefaults(suiteName: suite) {
            return defaults
        }
#endif
        return .standard
    }

    static func load(from defaults: UserDefaults = Self.defaults) -> Self {
        guard let data = defaults.data(forKey: storageKey), var value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        value.fontSize = value.fontSize.isFinite ? min(fontSizeRange.upperBound, max(fontSizeRange.lowerBound, value.fontSize)) : 34
        return value
    }

    func save(to defaults: UserDefaults = Self.defaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

private struct TeleprompterControlsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// Own only this page's idle-timer override, restoring any pre-existing owner.
@MainActor
struct TeleprompterScreenAwake {
    private var previousValue: Bool?

    mutating func setEnabled(_ enabled: Bool) {
        let application = UIApplication.shared
        if enabled {
            if previousValue == nil { previousValue = application.isIdleTimerDisabled }
            application.isIdleTimerDisabled = true
        } else if let previousValue {
            application.isIdleTimerDisabled = previousValue
            self.previousValue = nil
        }
    }
}

private struct SimulatorCameraPlaceholder: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.gray.opacity(0.65), .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 10) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 44))
                Text("Simulator 相机占位画面")
                    .font(.subheadline.weight(.semibold))
                Text("提词功能可正常测试")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.white)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("simulatorCameraPlaceholder")
        }
    }
}

private struct ControlSlider: View {
    let title: String
    let systemImage: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let accessibilityIdentifier: String

    var body: some View {
        HStack(spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .frame(width: 64, alignment: .leading)

            Slider(value: $value, in: range)
                .tint(.white)
                .accessibilityLabel(title)
                .accessibilityIdentifier(accessibilityIdentifier)

            Text(value.formatted(.number.precision(.fractionLength(0))))
                .font(.caption.monospacedDigit())
                .frame(width: 28, alignment: .trailing)
        }
    }
}

#Preview {
    NavigationStack {
        TeleprompterView(
            script: "欢迎使用提词器。\n\n台词会覆盖显示在前置摄像头画面上，并按设定速度自动滚动。"
        )
    }
}
