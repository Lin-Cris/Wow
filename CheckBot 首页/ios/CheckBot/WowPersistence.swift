import Foundation

final class WowPersistence {
    private let defaults: UserDefaults

    private let stateKey = "wow-native-state-v1"
    private let archivedKey = "wow-native-archived-v1"
    private let planCacheKey = "wow-native-plan-cache-v1"
    private let activeDayKey = "wow-native-active-day-v1"
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadPlanReminders() -> [String: Date] {
        guard let data = defaults.data(forKey: "wow-native-plan-reminders-v1") else { return [:] }
        return (try? JSONDecoder().decode([String: Date].self, from: data)) ?? [:]
    }

    func savePlanReminders(_ reminders: [String: Date]) {
        if let data = try? JSONEncoder().encode(reminders) { defaults.set(data, forKey: "wow-native-plan-reminders-v1") }
    }

    func loadState() -> WowLocalState {
        guard let data = defaults.data(forKey: stateKey),
              let state = try? JSONDecoder().decode(WowLocalState.self, from: data) else {
            return .seed
        }
        return state
    }

    func loadArchived() -> [WowArchivedItem] {
        guard let data = defaults.data(forKey: archivedKey),
              let archived = try? JSONDecoder().decode([WowArchivedItem].self, from: data) else {
            return []
        }
        return archived
    }

    func save(state: WowLocalState, archived: [WowArchivedItem]) {
        let encoder = JSONEncoder()
        if let stateData = try? encoder.encode(state) { defaults.set(stateData, forKey: stateKey) }
        if let archivedData = try? encoder.encode(archived) { defaults.set(archivedData, forKey: archivedKey) }
    }

    func savePlanCache(day: String, plans: [WowItem]) {
        let cache = WowPlanCache(day: day, plans: plans)
        if let data = try? JSONEncoder().encode(cache) { defaults.set(data, forKey: planCacheKey) }
        defaults.set(day, forKey: activeDayKey)
    }

    func loadPlanCache() -> WowPlanCache? {
        guard let data = defaults.data(forKey: planCacheKey) else { return nil }
        return try? JSONDecoder().decode(WowPlanCache.self, from: data)
    }

    func maintainCurrentDay(now: Date = Date()) -> (state: WowLocalState, archived: [WowArchivedItem]) {
        var state = loadState()
        var archived = wowCleanArchived(loadArchived(), now: now)
        let today = PlanFolderStore.day(now)
        guard let previousDay = defaults.string(forKey: activeDayKey), previousDay != today else {
            return (state, archived)
        }
        let cachedPlans = loadPlanCache()?.day == previousDay ? loadPlanCache()?.plans ?? [] : []
        archiveCompleted(state: &state, archived: &archived, cachedPlans: cachedPlans, fallbackDay: previousDay)
        save(state: state, archived: archived)
        savePlanCache(day: today, plans: [])
        return (state, archived)
    }

    @discardableResult
    func bootstrap(now: Date = Date()) -> (state: WowLocalState, archived: [WowArchivedItem]) {
        if defaults.string(forKey: activeDayKey) == nil {
            let state = loadState()
            let archived = wowCleanArchived(loadArchived(), now: now)
            save(state: state, archived: archived)
            savePlanCache(day: PlanFolderStore.day(now), plans: [])
            return (state, archived)
        }
        return maintainCurrentDay(now: now)
    }

    private func archiveCompleted(
        state: inout WowLocalState,
        archived: inout [WowArchivedItem],
        cachedPlans: [WowItem],
        fallbackDay: String
    ) {
        var completed: [(WowItem, String)] = []
        completed.append(contentsOf: state.plans.filter { $0.completed }.map { ($0, "plan") })
        completed.append(contentsOf: state.shopping.filter { $0.purchased }.map { ($0, "shopping") })
        completed.append(contentsOf: state.ideas.filter { $0.explored }.map { ($0, "idea") })
        completed.append(contentsOf: cachedPlans.filter { $0.completed }.map { ($0, "plan") })
        let archivedAt = WowTime.iso8601Now()
        for (item, sourceType) in completed {
            let value = wowArchiveItem(item, sourceType: sourceType, archivedAt: archivedAt, fallbackDay: fallbackDay)
            if !archived.contains(where: { $0.id == value.id }) { archived.append(value) }
        }
        state.plans.removeAll { $0.completed }
        state.shopping.removeAll { $0.purchased }
        state.ideas.removeAll { $0.explored }
    }

}
