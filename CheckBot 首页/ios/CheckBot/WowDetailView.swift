import SwiftUI
import UIKit
import CounterTool

struct WowDetailView: View {
    @ObservedObject var store: WowHomeStore
    let section: WowSection
    let edit: (WowItem?) -> Void

    var body: some View {
        let groups = store.items(for: section)
        List {
            if section == .plans, let summary = store.syncSummary() {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 8, trailing: 4))
                    .listRowSeparator(.hidden)
            }

            ForEach(groups.active) { item in
                WowItemRow(store: store, section: section, item: item, edit: edit)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            .onMove { offsets, destination in
                store.move(section: section, from: offsets, to: destination)
            }

            if !groups.completed.isEmpty {
                Section {
                    ForEach(groups.completed) { item in
                        WowItemRow(store: store, section: section, item: item, edit: edit)
                            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                } header: {
                    Text("Completed")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
            }

            if groups.active.isEmpty && groups.completed.isEmpty {
                Text(section == .plans ? store.planMessage() : section == .shopping ? "Your shopping list is empty." : "No ideas yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .listRowInsets(EdgeInsets(top: 16, leading: 4, bottom: 16, trailing: 4))
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 1)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemBackground))
        .navigationTitle(section.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if section == .shopping || section == .ideas {
                EditButton()
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button { edit(nil) } label: {
                Label(section.addTitle, systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.body)
            .foregroundStyle(.tint)
            .padding(.horizontal, 20)
            .padding(.vertical, 11)
            .background(.bar)
        }
    }
}

private struct WowItemRow: View {
    @ObservedObject var store: WowHomeStore
    let section: WowSection
    let item: WowItem
    let edit: (WowItem?) -> Void

    @State private var showingReminder = false

    private var done: Bool { item.isDone(in: section) }
    private var isToggling: Bool { store.togglingPlanID == item.id }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                ZStack {
                    Circle()
                        .stroke(done ? Color.accentColor : Color.secondary.opacity(0.55), lineWidth: 1.5)
                        .frame(width: 22, height: 22)
                    if done {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 22, height: 22)
                        Image(systemName: "checkmark")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 32, alignment: .leading)
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .disabled(isToggling)
            .accessibilityLabel(section == .shopping ? "Purchased: \(item.title)" : section == .ideas ? "Explored: \(item.title)" : "Complete: \(item.title)")
            .accessibilityValue(done ? "On" : "Off")

            Button { if item.source == nil { edit(item) } } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title)
                        .font(.body)
                        .foregroundStyle(done ? .secondary : .primary)
                        .strikethrough(done)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let subtitle = subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(item.source != nil)
            .accessibilityLabel(item.source == nil ? "Edit \(item.title)" : item.title)

            if section == .plans, !done {
                Button { showingReminder = true } label: {
                    Image(systemName: store.planReminders[item.id] == nil ? "bell" : "bell.fill")
                        .font(.subheadline).foregroundStyle(.secondary).frame(width: 36, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("提醒：\(item.title)")
                .accessibilityIdentifier("plan.reminder.\(item.id)")
            }
        }
        .sheet(isPresented: $showingReminder) { WowPlanReminderSheet(store: store, item: item) }
        .contextMenu {
            if section == .plans, !done {
                Button("设置提醒", systemImage: "bell") { showingReminder = true }
                if store.planReminders[item.id] != nil {
                    Button("移除提醒", systemImage: "bell.slash", role: .destructive) {
                        Task { _ = await store.setPlanReminder(item, date: nil) }
                    }
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if item.source != nil {
                Button(action: revealInObsidian) {
                    Label("Reveal in Obsidian", systemImage: "arrow.up.forward.app")
                }
                .tint(.indigo)
            }
        }
    }

    private var subtitle: String? {
        if section == .plans {
            let reminder = store.planReminders[item.id].map { "提醒 · " + $0.formatted(date: .abbreviated, time: .shortened) }
            let values = [item.timeRange, item.location.isEmpty ? nil : item.location, reminder].compactMap { $0 }
            return values.isEmpty ? nil : values.joined(separator: " · ")
        }
        return item.note.isEmpty ? nil : item.note
    }

    private func toggle() {
        if item.source != nil {
            Task { await store.togglePlan(item) }
        } else {
            store.toggleLocal(section: section, item: item)
        }
    }

    private func revealInObsidian() {
        guard let source = item.source,
              let url = ObsidianURI.url(notePath: source.sourceNotePath, sourceHeading: source.sourceHeading, sourceBlockId: source.sourceBlockId) else { return }
        UIApplication.shared.open(url)
    }
}

private struct WowPlanReminderSheet: View {
    @ObservedObject var store: WowHomeStore
    @ObservedObject private var notifications: ReminderNotifications
    let item: WowItem
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date
    @State private var saving = false
    @State private var error = ""

    init(store: WowHomeStore, item: WowItem) {
        self.store = store
        self.item = item
        _notifications = ObservedObject(wrappedValue: store.notifications)
        _date = State(initialValue: store.planReminders[item.id] ?? Date().addingTimeInterval(300))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(item.title)
                    DatePicker("提醒时间", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                        .accessibilityIdentifier("plan.reminder.date")
                }
                if !notifications.notificationsAllowed {
                    Section { Text(notifications.message).font(.caption).foregroundStyle(.secondary) }
                }
                if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
                Section {
                    Button("保存提醒") { save(date) }.disabled(saving)
                        .accessibilityIdentifier("plan.reminder.save")
                    if store.planReminders[item.id] != nil {
                        Button("移除提醒", role: .destructive) { save(nil) }.disabled(saving)
                    }
                }
            }
            .navigationTitle("计划提醒").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .task { _ = await notifications.checkPermission() }
    }

    private func save(_ value: Date?) {
        saving = true
        Task {
            if await store.setPlanReminder(item, date: value) { dismiss() }
            else { error = store.errorMessage }
            saving = false
        }
    }
}

struct WowArchiveView: View {
    @ObservedObject var store: WowHomeStore

    var body: some View {
        List {
            if store.archivedItems.isEmpty {
                Text("Nothing has been archived yet.")
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(store.archivedItems) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.title)
                            .font(.body.weight(.medium))
                        Text(archiveSubtitle(item))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let note = item.note {
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 7)
                    .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Recently Deleted")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top) {
            Text("Completed items are kept locally for 30 days.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
        }
    }

    private func archiveSubtitle(_ item: WowArchivedItem) -> String {
        let type = item.sourceType == "plan" ? "Plan" : item.sourceType == "idea" ? "Idea" : "Shopping"
        let time = item.timeRange.map { " · \($0)" } ?? ""
        let completed = WowTime.date(item.completedAt)?.formatted(date: .abbreviated, time: .omitted) ?? item.completedAt
        let archived = WowTime.date(item.archivedAt)?.formatted(date: .abbreviated, time: .omitted) ?? item.archivedAt
        return "\(type)\(time) · Completed \(completed) · Archived \(archived)"
    }
}
