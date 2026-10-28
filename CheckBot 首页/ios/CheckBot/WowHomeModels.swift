import Foundation

enum WowSection: String, CaseIterable, Hashable, Identifiable {
    case plans
    case shopping
    case ideas

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plans: return "Today’s Plan"
        case .shopping: return "Shopping"
        case .ideas: return "Reminder"
        }
    }

    var addTitle: String {
        switch self {
        case .plans: return "Add a plan"
        case .shopping: return "Add an item"
        case .ideas: return "Add an idea"
        }
    }
}

enum WowPlanOrigin: String, Codable, Sendable {
    case manual
    case localParser
}

enum WowCompletionBehavior: String, Codable, Sendable {
    case local
    case obsidianCheckbox
    case obsidianBehavior
}

struct WowPlanSource: Codable, Hashable, Sendable {
    var filename: String
    var sourceFileName: String
    var sourceNotePath: String
    var sourceRelativePath: String
    var lineIndex: Int
    var line: String
    var identity: String
    var sourceLineIndex: Int
    var sourceRawLine: String
    var sourceHeading: String
    var scheduleLineIndex: Int
    var scheduleLine: String
    var hasBehaviorCheckbox: Bool
    var behaviorLineIndex: Int?
    var behaviorLine: String?
    var sourceBlockId: String?
    var sourceFormat: String? = nil
    var completionColumn: Int? = nil

    var dictionary: [String: Any] {
        var value: [String: Any] = [
            "filename": filename,
            "sourceFileName": sourceFileName,
            "sourceNotePath": sourceNotePath,
            "sourceRelativePath": sourceRelativePath,
            "lineIndex": lineIndex,
            "line": line,
            "identity": identity,
            "sourceLineIndex": sourceLineIndex,
            "sourceRawLine": sourceRawLine,
            "sourceHeading": sourceHeading,
            "scheduleLineIndex": scheduleLineIndex,
            "scheduleLine": scheduleLine,
            "hasBehaviorCheckbox": hasBehaviorCheckbox
        ]
        if let behaviorLineIndex { value["behaviorLineIndex"] = behaviorLineIndex }
        if let behaviorLine { value["behaviorLine"] = behaviorLine }
        if let sourceBlockId { value["sourceBlockId"] = sourceBlockId }
        if let sourceFormat { value["sourceFormat"] = sourceFormat }
        if let completionColumn { value["completionColumn"] = completionColumn }
        return value
    }
}

struct WowItem: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var note: String
    var location: String
    var startTime: String?
    var endTime: String?
    var completed: Bool
    var purchased: Bool
    var explored: Bool
    var completedAt: String?
    var source: WowPlanSource?
    var origin: WowPlanOrigin
    var completionBehavior: WowCompletionBehavior

    private enum CodingKeys: String, CodingKey {
        case id, title, note, location, startTime, endTime, completed, purchased, explored, completedAt, source, origin, completionBehavior
    }

    init(
        id: String,
        title: String,
        note: String = "",
        location: String = "",
        startTime: String? = nil,
        endTime: String? = nil,
        completed: Bool = false,
        purchased: Bool = false,
        explored: Bool = false,
        completedAt: String? = nil,
        source: WowPlanSource? = nil,
        origin: WowPlanOrigin? = nil,
        completionBehavior: WowCompletionBehavior? = nil
    ) {
        self.id = id
        self.title = title
        self.note = note
        self.location = location
        self.startTime = startTime
        self.endTime = endTime
        self.completed = completed
        self.purchased = purchased
        self.explored = explored
        self.completedAt = completedAt
        self.source = source
        self.origin = origin ?? (source == nil ? .manual : .localParser)
        self.completionBehavior = completionBehavior ?? {
            guard let source else { return .local }
            return source.hasBehaviorCheckbox ? .obsidianBehavior : .obsidianCheckbox
        }()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        location = try container.decodeIfPresent(String.self, forKey: .location) ?? ""
        startTime = try container.decodeIfPresent(String.self, forKey: .startTime)
        endTime = try container.decodeIfPresent(String.self, forKey: .endTime)
        completed = try container.decodeIfPresent(Bool.self, forKey: .completed) ?? false
        purchased = try container.decodeIfPresent(Bool.self, forKey: .purchased) ?? false
        explored = try container.decodeIfPresent(Bool.self, forKey: .explored) ?? false
        completedAt = try container.decodeIfPresent(String.self, forKey: .completedAt)
        source = try container.decodeIfPresent(WowPlanSource.self, forKey: .source)
        origin = try container.decodeIfPresent(WowPlanOrigin.self, forKey: .origin) ?? (source == nil ? .manual : .localParser)
        if let decodedBehavior = try container.decodeIfPresent(WowCompletionBehavior.self, forKey: .completionBehavior) {
            completionBehavior = decodedBehavior
        } else if let source {
            completionBehavior = source.hasBehaviorCheckbox ? .obsidianBehavior : .obsidianCheckbox
        } else {
            completionBehavior = .local
        }
    }

    var timeRange: String? {
        if let startTime, let endTime {
            return "\(WowTime.display(startTime)) — \(WowTime.display(endTime))"
        }
        if let startTime { return WowTime.display(startTime) }
        return nil
    }

    var isObsidianPlan: Bool { source != nil }

    func isDone(in section: WowSection) -> Bool {
        switch section {
        case .plans: return completed
        case .shopping: return purchased
        case .ideas: return explored
        }
    }

    func settingDone(in section: WowSection, to value: Bool) -> WowItem {
        var copy = self
        switch section {
        case .plans: copy.completed = value
        case .shopping: copy.purchased = value
        case .ideas: copy.explored = value
        }
        copy.completedAt = value ? WowTime.iso8601Now() : nil
        return copy
    }
}

struct WowArchivedItem: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var sourceType: String
    var completedAt: String
    var archivedAt: String
    var startTime: String?
    var endTime: String?
    var note: String?

    var timeRange: String? {
        guard let startTime, let endTime else { return nil }
        return "\(WowTime.display(startTime)) — \(WowTime.display(endTime))"
    }
}

struct WowLocalState: Codable {
    var plans: [WowItem]
    var shopping: [WowItem]
    var ideas: [WowItem]

    subscript(section: WowSection) -> [WowItem] {
        get {
            switch section {
            case .plans: return plans
            case .shopping: return shopping
            case .ideas: return ideas
            }
        }
        set {
            switch section {
            case .plans: plans = newValue
            case .shopping: shopping = newValue
            case .ideas: ideas = newValue
            }
        }
    }

    static let seed = WowLocalState(
        plans: [],
        shopping: [
            WowItem(id: "s1", title: "AirPods"),
            WowItem(id: "s2", title: "Coffee beans", note: "Wait for a good offer"),
            WowItem(id: "s3", title: "USB-C cable")
        ],
        ideas: [
            WowItem(id: "i1", title: "Personal Obsidian dashboard"),
            WowItem(id: "i2", title: "Automate repetitive workflows with AI"),
            WowItem(id: "i3", title: "Build a lightweight personal tool")
        ]
    )
}

struct WowPlanSnapshot {
    var plans: [WowItem]
    var source: String
    var date: String?
    var today: String
    var isToday: Bool
    var warnings: [String]
    var summary: String
    var connected: Bool
    var status: String

    var hasTodayPlan: Bool { isToday && !plans.isEmpty }
}

struct WowPlanCache: Codable {
    var day: String
    var plans: [WowItem]
}

enum WowTime {
    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func minutes(_ value: String?) -> Int {
        guard let value else { return 0 }
        let parts = value.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return 0 }
        return parts[0] * 60 + parts[1]
    }

    static func display(_ value: String) -> String {
        let parts = value.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return value }
        var components = DateComponents()
        components.year = 2000
        components.month = 1
        components.day = 1
        components.hour = parts[0]
        components.minute = parts[1]
        guard let date = Calendar(identifier: .gregorian).date(from: components) else { return value }
        return displayFormatter.string(from: date)
    }

    static func iso8601Now() -> String { isoFormatter.string(from: Date()) }

    static func date(_ value: String) -> Date? {
        isoFormatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

func wowOrderedItems(_ section: WowSection, _ items: [WowItem]) -> [WowItem] {
    switch section {
    case .plans:
        return items.enumerated().sorted { lhs, rhs in
            switch (lhs.element.startTime, rhs.element.startTime) {
            case let (left?, right?):
                let leftMinutes = WowTime.minutes(left)
                let rightMinutes = WowTime.minutes(right)
                return leftMinutes == rightMinutes ? lhs.offset < rhs.offset : leftMinutes < rightMinutes
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.offset < rhs.offset
            }
        }.map(\.element)
    case .shopping:
        return items
    case .ideas:
        return Array(items.reversed())
    }
}

func wowRelevantPlans(_ items: [WowItem], now: Date) -> (active: WowItem?, items: [WowItem]) {
    let calendar = Calendar.current
    let currentMinutes = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
    let available = items
        .filter { !$0.completed }
        .sorted { WowTime.minutes($0.startTime) < WowTime.minutes($1.startTime) }
    let active = available.first {
        guard let start = $0.startTime, let end = $0.endTime else { return false }
        return WowTime.minutes(start) <= currentMinutes && currentMinutes < WowTime.minutes(end)
    }
    let upcoming = available.filter { WowTime.minutes($0.startTime) > currentMinutes }
    let untimed = available.filter { $0.startTime == nil }
    let preview = (active.map { [$0] } ?? []) + upcoming + untimed
    return (active, Array(preview.prefix(3)))
}

func wowReorderedOpenItems(_ section: WowSection, _ items: [WowItem], from sourceIndex: Int, to targetIndex: Int) -> [WowItem] {
    let ordered = wowOrderedItems(section, items)
    var open = ordered.filter { !$0.isDone(in: section) }
    let completed = ordered.filter { $0.isDone(in: section) }
    guard sourceIndex >= 0, sourceIndex < open.count else { return items }
    let moved = open.remove(at: sourceIndex)
    let insertionIndex = min(max(0, targetIndex), open.count)
    open.insert(moved, at: insertionIndex)
    let next = open + completed
    return section == .ideas ? Array(next.reversed()) : next
}

func wowArchiveItem(_ item: WowItem, sourceType: String, archivedAt: String, fallbackDay: String) -> WowArchivedItem {
    let completedAt = item.completedAt ?? "\(fallbackDay)T23:59:59.999Z"
    return WowArchivedItem(
        id: "\(sourceType):\(item.id):\(completedAt)",
        title: item.title,
        sourceType: sourceType,
        completedAt: completedAt,
        archivedAt: archivedAt,
        startTime: item.startTime,
        endTime: item.endTime,
        note: item.note.isEmpty ? nil : item.note
    )
}

func wowCleanArchived(_ items: [WowArchivedItem], now: Date) -> [WowArchivedItem] {
    let retention: TimeInterval = 30 * 24 * 60 * 60
    return items.filter { item in
        guard let archivedAt = WowTime.date(item.archivedAt) else { return true }
        return now.timeIntervalSince(archivedAt) < retention
    }
}
