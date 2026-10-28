import ActivityKit
import Foundation

enum CounterURLScheme {
    #if COUNTER_TOOL_MODULE
    static let value = "wow-counter"
    #else
    static let value = "counter"
    #endif
}

struct CounterLiveAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var draftID: String
        var amount: String
        var category: String
        var categoryAsset: String
        var status: String
    }
    var appTitle: String
}

@MainActor
enum CounterActivityController {
    static func show(_ draft: ReviewDraft, category: BookCategory?) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let active = Activity<CounterLiveAttributes>.activities
        let showDetails = UserDefaults(suiteName: "group.com.counter.app")?.bool(forKey: "counter.showPrivateActivity") ?? false
        let state = contentState(for: draft, category: category, revealDetails: showDetails)
        if let current = active.first(where: { $0.attributes.appTitle == "Counter" }) {
            await current.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(60 * 60)))
            for extra in active where extra.id != current.id {
                await extra.end(nil, dismissalPolicy: .immediate)
            }
            return
        }
        let attributes = CounterLiveAttributes(appTitle: "Counter")
        do {
            _ = try Activity.request(attributes: attributes,
                                     content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(60 * 60)),
                                     pushType: nil)
        } catch {
            // The in-app review inbox remains the source of truth if iOS refuses the activity.
        }
    }

    static func stop(draftID: String? = nil) async {
        for activity in Activity<CounterLiveAttributes>.activities {
            if let draftID, activity.content.state.draftID != draftID { continue }
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    static func contentState(for draft: ReviewDraft, category: BookCategory?, revealDetails: Bool) -> CounterLiveAttributes.ContentState {
        let status: String = switch draft.state {
        case .queued: "等待识别"
        case .recognizing: "正在识别"
        case .failed: "识别失败，可重试"
        default: "等待确认"
        }
        return CounterLiveAttributes.ContentState(
            draftID: draft.id,
            amount: revealDetails ? (draft.cents.map { CounterFormat.amount($0) } ?? "待确认金额") : "有一笔待记账",
            category: revealDetails ? (category?.name ?? "待确认分类") : "打开 Counter 核对",
            categoryAsset: revealDetails ? (category?.symbol ?? "custom_category") : "custom_category",
            status: status
        )
    }

    static func draftURL(_ id: String) -> URL? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let escapedID = id.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "\(CounterURLScheme.value)://drafts/\(escapedID)")
    }
}
