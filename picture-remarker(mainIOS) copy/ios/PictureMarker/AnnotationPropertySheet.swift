import SwiftUI

struct AnnotationPropertySheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppLanguage.storageKey)
    private var languageRawValue = AppLanguage.defaultValue.rawValue
    @State private var annotation: Annotation

    let onUpdate: (Annotation) -> Void
    let onDuplicate: (Annotation) -> Void
    let onDelete: (UUID) -> Void

    private var strings: AppStrings {
        AppStrings(rawValue: languageRawValue)
    }

    init(
        annotation: Annotation,
        onUpdate: @escaping (Annotation) -> Void,
        onDuplicate: @escaping (Annotation) -> Void,
        onDelete: @escaping (UUID) -> Void
    ) {
        _annotation = State(initialValue: annotation)
        self.onUpdate = onUpdate
        self.onDuplicate = onDuplicate
        self.onDelete = onDelete
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(
                        strings.type,
                        value: strings.annotationType(annotation.type)
                    )
                }
                .listRowBackground(AppTheme.surface)

                Section(strings.color) {
                    HStack {
                        ForEach(AnnotationColor.allCases) { color in
                            Spacer()

                            Button {
                                annotation.color = color
                                onUpdate(annotation)
                            } label: {
                                VStack(spacing: 6) {
                                    ZStack {
                                        Circle()
                                            .fill(color.swiftUIColor)
                                            .overlay {
                                                Circle()
                                                    .stroke(.secondary, lineWidth: color == .white ? 1 : 0)
                                            }
                                            .frame(width: 34, height: 34)

                                        if annotation.color == color {
                                            Image(systemName: "checkmark")
                                                .font(.caption.bold())
                                                .foregroundStyle(color == .white ? .black : .white)
                                        }
                                    }

                                    Text(strings.colorName(color))
                                        .font(.caption)
                                    .foregroundStyle(AppTheme.primaryText)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(strings.colorName(color))

                            Spacer()
                        }
                    }
                }
                .listRowBackground(AppTheme.surface)

                Section(strings.strokeWidth) {
                    Picker(strings.strokeWidth, selection: $annotation.strokeWidth) {
                        ForEach(AnnotationStrokeWidth.allCases) { strokeWidth in
                            Text(strings.strokeWidthName(strokeWidth))
                                .tag(strokeWidth)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: annotation.strokeWidth) { _, _ in
                        onUpdate(annotation)
                    }
                }
                .listRowBackground(AppTheme.surface)

                Section(strings.note) {
                    TextEditor(text: $annotation.note)
                        .frame(minHeight: 100)
                        .onChange(of: annotation.note) { _, _ in
                            onUpdate(annotation)
                        }
                }
                .listRowBackground(AppTheme.surface)

                Section {
                    Button {
                        onDuplicate(annotation)
                        dismiss()
                    } label: {
                        Label(
                            strings.duplicateAnnotation,
                            systemImage: "plus.square.on.square"
                        )
                    }
                }
                .listRowBackground(AppTheme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(WarmPageBackground())
            .navigationTitle(strings.annotationProperties)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .destructive) {
                        onDelete(annotation.id)
                        dismiss()
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(AppTheme.accentDeep)
                    }
                    .accessibilityLabel(strings.deleteAnnotation)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(strings.done) {
                        dismiss()
                    }
                    .foregroundStyle(AppTheme.accent)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
