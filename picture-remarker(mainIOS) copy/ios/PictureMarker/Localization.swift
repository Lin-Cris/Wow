import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case simplifiedChinese
    case english

    static let storageKey = "pictureMarker.language"

    static var defaultValue: AppLanguage {
        Locale.preferredLanguages.first?.hasPrefix("zh") == true
            ? .simplifiedChinese
            : .english
    }

    var id: Self { self }

    var locale: Locale {
        switch self {
        case .simplifiedChinese:
            Locale(identifier: "zh-Hans")
        case .english:
            Locale(identifier: "en")
        }
    }

    var displayName: String {
        switch self {
        case .simplifiedChinese:
            "中文"
        case .english:
            "English"
        }
    }
}

struct AppStrings {
    let language: AppLanguage

    init(rawValue: String) {
        language = AppLanguage(rawValue: rawValue) ?? .defaultValue
    }

    private var isChinese: Bool {
        language == .simplifiedChinese
    }

    var appSubtitle: String {
        isChinese ? "专业图片标注工具" : "Premium Photo Markup App"
    }
    var homeDescription: String {
        isChinese ? "在图片上添加清晰、简单的标记" : "Add clear, elegant markup to every photo"
    }
    var settings: String { isChinese ? "设置" : "Settings" }
    var languageTitle: String { isChinese ? "语言" : "Language" }
    var languageFooter: String {
        isChinese ? "界面语言会立即更新。" : "The interface updates immediately."
    }
    var done: String { isChinese ? "完成" : "Done" }
    var back: String { isChinese ? "返回" : "Back" }
    var undo: String { isChinese ? "撤销" : "Undo" }
    var redo: String { isChinese ? "重做" : "Redo" }
    var resetCanvasZoom: String { isChinese ? "恢复全图" : "Reset zoom" }
    var canvasZoomHint: String { isChinese ? "双指缩放或移动画布" : "Pinch to zoom; use two fingers to pan" }
    var select: String { isChinese ? "选择" : "Select" }
    var shape: String { isChinese ? "形状" : "Shape" }
    var line: String { isChinese ? "直线" : "Line" }
    var rectangle: String { isChinese ? "矩形" : "Rectangle" }
    var arrow: String { isChinese ? "箭头" : "Arrow" }
    var ellipse: String { isChinese ? "椭圆" : "Ellipse" }
    var mosaic: String { isChinese ? "马赛克" : "Mosaic" }
    var size: String { isChinese ? "大小" : "Size" }
    var pixelSize: String { isChinese ? "像素尺寸" : "Pixel Size" }
    var addImage: String { isChinese ? "添加图片" : "Add Image" }
    var loading: String { isChinese ? "载入中" : "Loading" }
    var more: String { isChinese ? "更多" : "More" }
    var chooseImage: String { isChinese ? "选择图片" : "Choose Photo" }
    var photo: String { isChinese ? "相册" : "Photo" }
    var camera: String { isChinese ? "相机" : "Camera" }
    var cameraUnavailable: String { isChinese ? "相机不可用" : "Camera Unavailable" }
    var cameraNotAvailableMessage: String {
        isChinese ? "此设备没有可用的相机。" : "A camera is not available on this device."
    }
    var cameraPermissionMessage: String {
        isChinese ? "拍照需要相机访问权限。" : "Camera access is required to take a photo."
    }
    var cameraCurrentlyUnavailableMessage: String {
        isChinese ? "相机当前不可用。" : "The camera is currently unavailable."
    }
    var capturedPhotoLoadFailedMessage: String {
        isChinese ? "无法载入拍摄的照片。" : "The captured photo could not be loaded."
    }
    var replaceImage: String { isChinese ? "更换图片" : "Replace Photo" }
    var imageLoadFailed: String { isChinese ? "图片载入失败" : "Unable to Load Photo" }
    var loadingImage: String { isChinese ? "正在载入图片…" : "Loading photo…" }
    var duplicateSelectedImage: String {
        isChinese ? "复制选中图片" : "Duplicate Selected Image"
    }
    var deleteSelectedImage: String {
        isChinese ? "删除选中图片" : "Delete Selected Image"
    }
    var clearAll: String { isChinese ? "全部清空" : "Clear All" }
    var clearConfirmation: String {
        isChinese
            ? "确定清空所有标注和图片图层吗？"
            : "Clear all annotations and image layers?"
    }
    var cancel: String { isChinese ? "取消" : "Cancel" }
    var okay: String { isChinese ? "好" : "OK" }
    var overlayLoadFailureMessage: String {
        isChinese ? "无法添加这张图片，请重新选择。" : "This image could not be added. Please try another."
    }
    var selectedToolAccessibility: String {
        isChinese ? "当前工具" : "Current tool"
    }
    var overlayAccessibilityLabel: String {
        isChinese ? "图片图层" : "Image layer"
    }
    var overlayAccessibilityHint: String {
        isChinese ? "单指拖动，双指缩放或旋转" : "Drag with one finger; pinch or rotate with two fingers"
    }
    var overlayGestureHint: String {
        isChinese ? "单指拖动图片；双指可同时缩放和旋转" : "Drag the image; use two fingers to scale and rotate"
    }
    var selectHint: String {
        isChinese ? "轻点标注编辑，拖动标注移动" : "Tap to edit; drag to move an annotation"
    }
    var rectangleHint: String {
        isChinese ? "在图片上拖动以创建矩形" : "Drag on the photo to create a rectangle"
    }
    var lineHint: String {
        isChinese ? "从起点拖向终点以创建直线" : "Drag from start to end to create a straight line"
    }
    var arrowHint: String {
        isChinese ? "从起点拖向终点以创建箭头" : "Drag from start to end to create an arrow"
    }
    var ellipseHint: String {
        isChinese ? "在图片上拖动以创建椭圆" : "Drag on the photo to create an ellipse"
    }
    var mosaicHint: String {
        isChinese ? "在图片上拖动以涂抹马赛克" : "Drag on the photo to paint mosaic"
    }
    var annotationProperties: String {
        isChinese ? "标注属性" : "Annotation Properties"
    }
    var type: String { isChinese ? "类型" : "Type" }
    var color: String { isChinese ? "颜色" : "Color" }
    var strokeWidth: String { isChinese ? "线宽" : "Line Width" }
    var note: String { isChinese ? "说明" : "Note" }
    var duplicateAnnotation: String {
        isChinese ? "复制标注" : "Duplicate Annotation"
    }
    var deleteAnnotation: String {
        isChinese ? "删除标注" : "Delete Annotation"
    }
    var export: String { isChinese ? "导出" : "Export" }
    var preparingExport: String {
        isChinese ? "正在生成高清图片…" : "Preparing full-resolution image…"
    }
    var exportFailed: String { isChinese ? "生成失败" : "Export Failed" }
    var exportRetryMessage: String {
        isChinese ? "请返回编辑页面后重试" : "Return to the editor and try again"
    }
    var saving: String { isChinese ? "正在保存…" : "Saving…" }
    var saveToPhotos: String { isChinese ? "保存到照片" : "Save to Photos" }
    var shareImage: String { isChinese ? "分享图片" : "Share Image" }
    var unableToSave: String { isChinese ? "无法保存" : "Unable to Save" }
    var photoPermissionMessage: String {
        isChinese
            ? "请在系统设置中允许 Picture Marker 添加照片。"
            : "Allow Picture Marker to add photos in System Settings."
    }
    var saveSucceeded: String { isChinese ? "保存成功" : "Saved" }
    var saveSucceededMessage: String {
        isChinese ? "带标注的图片已经保存到系统照片。" : "The marked-up image was saved to Photos."
    }
    var saveFailed: String { isChinese ? "保存失败" : "Save Failed" }
    var saveFailedMessage: String {
        isChinese ? "无法写入系统照片，请稍后重试。" : "Photos could not be updated. Please try again."
    }

    func annotationCount(_ count: Int) -> String {
        isChinese ? "\(count)个标注" : "\(count) \(count == 1 ? "Annotation" : "Annotations")"
    }

    func toolTitle(_ tool: EditorTool) -> String {
        switch tool {
        case .select: select
        case .rectangle: rectangle
        case .line: line
        case .arrow: arrow
        case .ellipse: ellipse
        case .mosaic: mosaic
        }
    }

    func toolHint(_ tool: EditorTool) -> String {
        switch tool {
        case .select: selectHint
        case .rectangle: rectangleHint
        case .line: lineHint
        case .arrow: arrowHint
        case .ellipse: ellipseHint
        case .mosaic: mosaicHint
        }
    }

    func annotationType(_ type: AnnotationType) -> String {
        switch type {
        case .rectangle: rectangle
        case .line: line
        case .arrow: arrow
        case .ellipse: ellipse
        case .mosaic: mosaic
        }
    }

    func colorName(_ color: AnnotationColor) -> String {
        switch (language, color) {
        case (.simplifiedChinese, .red): "红"
        case (.simplifiedChinese, .yellow): "黄"
        case (.simplifiedChinese, .blue): "蓝"
        case (.simplifiedChinese, .green): "绿"
        case (.simplifiedChinese, .white): "白"
        case (.english, .red): "Red"
        case (.english, .yellow): "Yellow"
        case (.english, .blue): "Blue"
        case (.english, .green): "Green"
        case (.english, .white): "White"
        }
    }

    func strokeWidthName(_ width: AnnotationStrokeWidth) -> String {
        switch (language, width) {
        case (.simplifiedChinese, .thin): "细"
        case (.simplifiedChinese, .medium): "中"
        case (.simplifiedChinese, .thick): "粗"
        case (.english, .thin): "Thin"
        case (.english, .medium): "Medium"
        case (.english, .thick): "Thick"
        }
    }

    func exportResolution(width: Int, height: Int) -> String {
        isChinese
            ? "导出尺寸：\(width) × \(height) 像素"
            : "Export size: \(width) × \(height) pixels"
    }
}

struct LanguageSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppLanguage.storageKey)
    private var languageRawValue = AppLanguage.defaultValue.rawValue

    private var strings: AppStrings {
        AppStrings(rawValue: languageRawValue)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Image("BrandIcon")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 48, height: 48)
                            .clipShape(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Picture Marker")
                                .font(.headline)
                                .foregroundStyle(AppTheme.primaryText)

                            Text(strings.appSubtitle)
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                    }
                    .padding(.vertical, 3)
                }
                .listRowBackground(AppTheme.surface)

                Section {
                    Picker(strings.languageTitle, selection: $languageRawValue) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.displayName)
                                .tag(language.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                } footer: {
                    Text(strings.languageFooter)
                        .foregroundStyle(AppTheme.tertiaryText)
                }
                .listRowBackground(AppTheme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(WarmPageBackground())
            .navigationTitle(strings.settings)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(strings.done) {
                        dismiss()
                    }
                    .foregroundStyle(AppTheme.accent)
                }
            }
        }
        .environment(\.locale, strings.language.locale)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
