import SwiftUI

struct WowEditorSelection: Identifiable {
    let section: WowSection
    let item: WowItem?

    var id: String { "\(section.rawValue):\(item?.id ?? "new")" }
}

struct WowEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: WowHomeStore
    let selection: WowEditorSelection

    @State private var title: String
    @State private var note: String
    @State private var startTime: String
    @State private var endTime: String

    init(store: WowHomeStore, selection: WowEditorSelection) {
        self.store = store
        self.selection = selection
        _title = State(initialValue: selection.item?.title ?? "")
        _note = State(initialValue: selection.item?.note ?? "")
        _startTime = State(initialValue: selection.item?.startTime ?? "09:00")
        _endTime = State(initialValue: selection.item?.endTime ?? "09:30")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                        .textInputAutocapitalization(.sentences)
                    if selection.section == .plans {
                        HStack {
                            DatePicker("Start", selection: timeBinding($startTime), displayedComponents: .hourAndMinute)
                            DatePicker("End", selection: timeBinding($endTime), displayedComponents: .hourAndMinute)
                        }
                    } else {
                        TextField("Note (optional)", text: $note)
                    }
                }

                if !store.errorMessage.isEmpty {
                    Section {
                        Text(store.errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button(selection.item == nil ? selection.section.addTitle : "Save changes") {
                        save()
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("wow.editor.save")
                    .foregroundStyle(.tint)
                    if let item = selection.item {
                        Button("Delete", role: .destructive) {
                            store.remove(section: selection.section, item: item)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(selection.item == nil ? "New \(selection.section == .plans ? "plan" : selection.section == .shopping ? "item" : "idea")" : "Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        if store.saveItem(
            section: selection.section,
            existing: selection.item,
            title: title,
            note: note,
            startTime: selection.section == .plans ? startTime : nil,
            endTime: selection.section == .plans ? endTime : nil
        ) {
            dismiss()
        }
    }

    private func timeBinding(_ value: Binding<String>) -> Binding<Date> {
        Binding(
            get: {
                let parts = value.wrappedValue.split(separator: ":").compactMap { Int($0) }
                var components = DateComponents()
                components.year = 2000
                components.month = 1
                components.day = 1
                components.hour = parts.first ?? 9
                components.minute = parts.dropFirst().first ?? 0
                return Calendar.current.date(from: components) ?? Date()
            },
            set: { newValue in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                value.wrappedValue = String(format: "%02d:%02d", components.hour ?? 9, components.minute ?? 0)
            }
        )
    }
}

