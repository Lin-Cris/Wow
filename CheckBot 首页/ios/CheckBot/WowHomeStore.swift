import Foundation
import SwiftUI
import CounterTool
import UserNotifications

@MainActor
final class WowHomeStore: ObservableObject {
    @Published private(set) var state: WowLocalState
    @Published private(set) var archived: [WowArchivedItem]
    @Published private(set) var synced: WowPlanSnapshot?
    @Published private(set) var syncError = ""
    @Published private(set) var errorMessage = ""
    @Published private(set) var isRefreshing = false
    @Published private(set) var isConnecting = false
    @Published private(set) var togglingPlanID: String?
    @Published private(set) var pendingCompleted = Set<String>()

    @Published private(set) var planReminders: [String: Date]
    let notifications: ReminderNotifications

    let persistence: WowPersistence
    let planService: WowPlanService

    private var started = false

    init(
        state: WowLocalState,
        archived: [WowArchivedItem],
        persistence: WowPersistence,
        planService: WowPlanService,
        notifications: ReminderNotifications? = nil
    ) {
        self.state = state
        self.archived = archived
        self.persistence = persistence
        self.planService = planService
        self.notifications = notifications ?? .shared
        self.planReminders = persistence.loadPlanReminders()
        if let cache = persistence.loadPlanCache(), cache.day == PlanFolderStore.day(Date()) {
            self.synced = WowPlanSnapshot(plans: cache.plans, source: "", date: cache.day, today: cache.day, isToday: true, warnings: [], summary: "", connected: true, status: "cached")
        }
    }

    var planItems: [WowItem] {
        let obsidianPlans = synced?.isToday == true ? synced?.plans ?? [] : []
        return wowOrderedItems(.plans, obsidianPlans + state.plans)
    }

    var archivedItems: [WowArchivedItem] {
        archived.sorted { WowTime.date($0.archivedAt) ?? .distantPast > WowTime.date($1.archivedAt) ?? .distantPast }
    }

    func items(for section: WowSection) -> (active: [WowItem], completed: [WowItem]) {
        let items: [WowItem]
        switch section {
        case .plans: items = planItems
        case .shopping, .ideas: items = wowOrderedItems(section, state[section])
        }
        let active = items.filter { !$0.isDone(in: section) || pendingCompleted.contains(key(section, $0)) }
        let completed = items.filter { $0.isDone(in: section) && !pendingCompleted.contains(key(section, $0)) }
        return (active, completed)
    }

    func previewPlans(at date: Date) -> [WowItem] {
        wowRelevantPlans(planItems, now: date).items
    }

    func planMessage() -> String {
        if !planItems.isEmpty && planItems.allSatisfy({ $0.completed }) {
            return "Today’s plans are complete"
        }
        if !planItems.isEmpty { return "No upcoming plans" }
        if !syncError.isEmpty { return syncError }
        guard let synced else { return "Reading Obsidian…" }
        switch synced.status {
        case "downloading": return "iCloud 正在下载笔记…"
        case "no_today_note", "missing": return "No today note"
        default:
            if !synced.isToday, let date = synced.date { return "今天还没有计划 · 笔记日期 \(date)" }
            if let warning = synced.warnings.first { return warning }
            if !synced.summary.isEmpty { return synced.summary }
            return "今天还没有计划"
        }
    }

    func syncSummary() -> String? {
        if !syncError.isEmpty { return syncError }
        guard let synced else { return "Reading Obsidian…" }
        if !synced.connected { return "Connect your Plan folder to read today’s note." }
        let source = synced.source.isEmpty ? "Undated" : synced.source
        let date = synced.date ?? "Undated"
        var summary = "\(source) · \(date) · Synced with Obsidian\(synced.isToday ? "" : " · Not today’s schedule")"
        if !synced.summary.isEmpty { summary += " · \(synced.summary)" }
        if let warning = synced.warnings.first { summary += " · \(warning)" }
        return summary
    }

    func start() async {
        guard !started else { return }
        started = true
        await synchronizePlanReminders()
        await refresh()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        let maintained = persistence.maintainCurrentDay()
        state = maintained.state
        archived = maintained.archived
        if let synced, synced.today != PlanFolderStore.day(Date()) { self.synced = nil }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let snapshot = try await readPlanWithRetry()
            guard !Task.isCancelled else { return }

            // A downloading note is not an authoritative deletion of its cached plans.
            if snapshot.status != "downloading" { synced = snapshot }
            syncError = ""
            if snapshot.isToday { persistence.savePlanCache(day: snapshot.today, plans: snapshot.plans) }
            if snapshot.status != "downloading" { await synchronizePlanReminders(prune: true) }
        } catch is CancellationError {
            // View-driven refresh cancellation is expected.
        } catch {
            syncError = error.localizedDescription
        }
    }

    func connect(to url: URL) async {
        isConnecting = true
        do {
            try await planService.connect(url)
            syncError = ""
            await refresh()
        } catch {
            syncError = error.localizedDescription
        }
        isConnecting = false
    }

    private func readPlanWithRetry() async throws -> WowPlanSnapshot {
        var snapshot = try await planService.read()
        for _ in 0..<2 where snapshot.status == "downloading" {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            snapshot = try await planService.read()
        }
        return snapshot
    }

    func toggleLocal(section: WowSection, item: WowItem) {
        guard item.source == nil else { return }
        var items = state[section]
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let next = !items[index].isDone(in: section)
        items[index] = items[index].settingDone(in: section, to: next)
        state[section] = items
        save()
        if section == .plans { enqueuePlanReminders() }
        if next { holdCompleted(section: section, itemID: item.id) } else { pendingCompleted.remove(key(section, item)) }
    }

    func togglePlan(_ item: WowItem) async {
        guard item.source != nil, togglingPlanID == nil else { return }
        togglingPlanID = item.id
        do {
            let snapshot = try await planService.toggle(item)
            synced = snapshot
            syncError = ""
            await synchronizePlanReminders(prune: true)
            if snapshot.isToday { persistence.savePlanCache(day: snapshot.today, plans: snapshot.plans) }
            if let updated = snapshot.plans.first(where: { $0.id == item.id }) {
                if updated.completed { holdCompleted(section: .plans, itemID: updated.id) }
                else { pendingCompleted.remove(key(.plans, updated)) }
            }
        } catch is CancellationError {
        } catch {
            syncError = error.localizedDescription
        }
        togglingPlanID = nil
    }

    @discardableResult
    func saveItem(
        section: WowSection,
        existing: WowItem?,
        title: String,
        note: String,
        startTime: String?,
        endTime: String?
    ) -> Bool {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            errorMessage = "Enter a title."
            return false
        }
        if section == .plans, WowTime.minutes(endTime) <= WowTime.minutes(startTime) {
            errorMessage = "End time must be later than start time."
            return false
        }
        var items = state[section]
        let item: WowItem
        if let existing, let index = items.firstIndex(where: { $0.id == existing.id }) {
            item = WowItem(
                id: existing.id,
                title: trimmedTitle,
                note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                startTime: section == .plans ? startTime : nil,
                endTime: section == .plans ? endTime : nil,
                completed: existing.completed,
                purchased: existing.purchased,
                explored: existing.explored,
                completedAt: existing.completedAt
            )
            items[index] = item
        } else {
            item = WowItem(
                id: UUID().uuidString,
                title: trimmedTitle,
                note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                startTime: section == .plans ? startTime : nil,
                endTime: section == .plans ? endTime : nil
            )
            items.append(item)
        }
        state[section] = items
        errorMessage = ""
        save()
        if section == .plans { enqueuePlanReminders() }
        return true
    }

    /// Persists a plan created by a typed action. The action may omit a time,
    /// but it may not provide an end without a start or an inverted range.
    @discardableResult
    func saveLocalPlan(
        title: String,
        note: String,
        startTime: String?,
        endTime: String?
    ) -> Bool {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            errorMessage = "Enter a title."
            return false
        }
        if endTime != nil && startTime == nil {
            errorMessage = "An end time needs a start time."
            return false
        }
        if let startTime, let endTime,
           WowTime.minutes(endTime) <= WowTime.minutes(startTime) {
            errorMessage = "End time must be later than start time."
            return false
        }
        let item = WowItem(
            id: UUID().uuidString,
            title: trimmedTitle,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            startTime: startTime,
            endTime: endTime
        )
        state.plans.append(item)
        errorMessage = ""
        save()
        return true
    }

    func remove(section: WowSection, item: WowItem) {
        guard item.source == nil else { return }
        state[section].removeAll { $0.id == item.id }
        pendingCompleted.remove(key(section, item))
        save()
        if section == .plans { enqueuePlanReminders() }
    }

    func move(section: WowSection, from offsets: IndexSet, to destination: Int) {
        guard section == .shopping || section == .ideas else { return }
        let open = wowOrderedItems(section, state[section]).filter { !$0.isDone(in: section) }
        guard let sourceIndex = offsets.first, sourceIndex < open.count else { return }
        let targetIndex = destination > sourceIndex ? destination - 1 : destination
        let reordered = wowReorderedOpenItems(section, state[section], from: sourceIndex, to: targetIndex)
        state[section] = reordered
        save()
    }

    @discardableResult
    func setPlanReminder(_ item: WowItem, date: Date?) async -> Bool {
        if let date {
            guard date > Date(), planItems.contains(where: { $0.id == item.id && !$0.completed }) else {
                errorMessage = "请选择将来的提醒时间，并确认计划尚未完成。"
                return false
            }
            guard await notifications.checkPermission(requestIfNeeded: true) else {
                planReminders[item.id] = nil
                persistence.savePlanReminders(planReminders)
                _ = await synchronizePlanReminders(prune: true)
                errorMessage = notifications.message
                return false
            }
        }
        // Recheck after permission UI; the user may have completed or deleted the plan meanwhile.
        guard date == nil || planItems.contains(where: { $0.id == item.id && !$0.completed }) else { return false }
        planReminders[item.id] = date
        persistence.savePlanReminders(planReminders)
        let succeeded = await synchronizePlanReminders(prune: true)
        if !succeeded, date != nil {
            planReminders[item.id] = nil
            persistence.savePlanReminders(planReminders)
            errorMessage = notifications.message
            _ = await synchronizePlanReminders(prune: true)
            return false
        }
        errorMessage = ""
        return true
    }

    private func enqueuePlanReminders() {
        // Snapshot synchronously, before another UI edit can interleave.
        prunePlanReminders()
        let requests = planReminderRequests()
        Task { _ = await notifications.replace(prefix: "plan-reminder-", requests: requests) }
    }

    private func prunePlanReminders() {
        let activeIDs = Set(planItems.filter { !$0.completed }.map(\.id))
        planReminders = planReminders.filter { activeIDs.contains($0.key) }
        persistence.savePlanReminders(planReminders)
    }

    private func planReminderRequests() -> [UNNotificationRequest] {
        planItems.filter { !$0.completed }.compactMap { item in
            guard let date = planReminders[item.id] else { return nil }
            return ReminderNotifications.planRequest(id: item.id, title: item.title, date: date)
        }
    }

    @discardableResult
    func synchronizePlanReminders(prune: Bool = false) async -> Bool {
        if prune { prunePlanReminders() }
        return await notifications.replace(prefix: "plan-reminder-", requests: planReminderRequests())
    }

    private func save() {
        persistence.save(state: state, archived: archived)
        if let synced, synced.isToday { persistence.savePlanCache(day: synced.today, plans: synced.plans) }
    }

    private func key(_ section: WowSection, _ item: WowItem) -> String {
        "\(section.rawValue):\(item.id)"
    }

    private func holdCompleted(section: WowSection, itemID: String) {
        pendingCompleted.insert("\(section.rawValue):\(itemID)")
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.pendingCompleted.remove("\(section.rawValue):\(itemID)")
        }
    }
}
